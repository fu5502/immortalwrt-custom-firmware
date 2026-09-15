#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="${GITHUB_WORKSPACE:-$(cd "${script_dir}/.." && pwd)}"
repo="${GITHUB_REPOSITORY:-fu5502/immortalwrt-custom-firmware}"
event_name="${EVENT_NAME:-${GITHUB_EVENT_NAME:-schedule}}"
force_build="${FORCE_BUILD:-false}"
runner_temp="${RUNNER_TEMP:-/tmp}"
output_file="${GITHUB_OUTPUT:-/dev/null}"

echo "=== Upstream Change Detector ==="
echo "Workspace   : ${workspace}"
echo "Repository  : ${repo}"
echo "Event       : ${event_name}"
echo "Force build : ${force_build}"

# 1. Push 事件或手动强制构建时，直接触发构建
if [ "${event_name}" = "push" ]; then
  local_sha="$(git -C "${workspace}" rev-parse HEAD 2>/dev/null || echo "unknown")"
  echo "need_build=true" >> "${output_file}"
  echo "build_reason=Code pushed to main (${local_sha:0:7})" >> "${output_file}"
  echo "Triggering build: Code pushed to main (${local_sha:0:7})"
  exit 0
fi

if [ "${event_name}" = "workflow_dispatch" ] && [ "${force_build}" = "true" ]; then
  echo "need_build=true" >> "${output_file}"
  echo "build_reason=Manual workflow dispatch (force_build=true)" >> "${output_file}"
  echo "Triggering build: Manual workflow dispatch"
  exit 0
fi

# 2. 采集当前上游和本地最新版本指纹
echo "Collecting current upstream and local versions..."

# ImmortalWrt
imm_release="$(curl -fsSL --retry 3 https://downloads.immortalwrt.org/releases/ 2>/dev/null | grep -Eo 'href="[0-9]+(\.[0-9]+){1,2}/"' | sed -E 's|href="([^"]+)/"|\1|' | sort -V | tail -n 1 || echo "")"
if [ -z "${imm_release}" ]; then
  echo "Warning: Could not resolve ImmortalWrt release, defaulting to 25.12.2"
  imm_release="25.12.2"
fi

# Open-Box
openbox_tag="$(gh api "repos/liandu2024/Open-Box/releases/latest" --jq .tag_name 2>/dev/null || echo "")"

# OpenClash
openclash_tag="$(gh api "repos/vernesong/OpenClash/releases/latest" --jq .tag_name 2>/dev/null || echo "")"

# PassWall main commit
passwall_commit="$(git ls-remote https://github.com/Openwrt-Passwall/openwrt-passwall.git refs/heads/main 2>/dev/null | awk '{print $1}' || echo "")"

# Homepage API commit
homepage_commit="$(git ls-remote https://github.com/fu5502/luci-app-homepage-api.git HEAD 2>/dev/null | awk '{print $1}' || echo "")"

# Local commit
local_sha="$(git -C "${workspace}" rev-parse HEAD 2>/dev/null || echo "")"

echo "Current state:"
echo "  ImmortalWrt Release : ${imm_release}"
echo "  Open-Box Tag        : ${openbox_tag}"
echo "  OpenClash Tag       : ${openclash_tag}"
echo "  PassWall Commit     : ${passwall_commit}"
echo "  Homepage API Commit : ${homepage_commit}"
echo "  Local Commit        : ${local_sha}"

# 3. 从 GitHub 获取上一版本的元数据
prev_dir="${runner_temp}/immortalwrt-prev-release"
rm -rf "${prev_dir}"
mkdir -p "${prev_dir}"

echo "Fetching latest release from ${repo}..."
latest_tag="$(gh release view --repo "${repo}" --json tagName --jq .tagName 2>/dev/null || echo "")"
if [ -z "${latest_tag}" ]; then
  echo "No existing release found. Triggering initial build."
  echo "need_build=true" >> "${output_file}"
  echo "build_reason=No existing release found in ${repo}" >> "${output_file}"
  exit 0
fi

echo "Latest release tag is: ${latest_tag}"
gh release download "${latest_tag}" --repo "${repo}" --pattern "upstream-fingerprint.json" --dir "${prev_dir}" 2>/dev/null || true
gh release download "${latest_tag}" --repo "${repo}" --pattern "BUILD-INFO.txt" --dir "${prev_dir}" 2>/dev/null || true
gh release download "${latest_tag}" --repo "${repo}" --pattern "UPSTREAM-PACKAGES.txt" --dir "${prev_dir}" 2>/dev/null || true

# 4. 比对当前状态与上一版本的差异
export PREV_DIR="${prev_dir}"
export CURR_IMM_RELEASE="${imm_release}"
export CURR_OPENBOX_TAG="${openbox_tag}"
export CURR_OPENCLASH_TAG="${openclash_tag}"
export CURR_PASSWALL_COMMIT="${passwall_commit}"
export CURR_HOMEPAGE_COMMIT="${homepage_commit}"
export CURR_LOCAL_SHA="${local_sha}"

diff_result="$(python3 - << 'PYEOF'
import json, os, sys

prev_dir = os.environ.get("PREV_DIR", "")
current = {
    "immortalwrt_release": os.environ.get("CURR_IMM_RELEASE", ""),
    "openbox_tag": os.environ.get("CURR_OPENBOX_TAG", ""),
    "openclash_tag": os.environ.get("CURR_OPENCLASH_TAG", ""),
    "passwall_commit": os.environ.get("CURR_PASSWALL_COMMIT", ""),
    "homepage_api_commit": os.environ.get("CURR_HOMEPAGE_COMMIT", ""),
    "local_sha": os.environ.get("CURR_LOCAL_SHA", ""),
}

prev = {}
prev_fp_file = os.path.join(prev_dir, "upstream-fingerprint.json")
if os.path.isfile(prev_fp_file):
    try:
        with open(prev_fp_file, "r", encoding="utf-8") as f:
            prev = json.load(f)
    except Exception:
        pass

if not prev:
    build_info_file = os.path.join(prev_dir, "BUILD-INFO.txt")
    upstream_pkg_file = os.path.join(prev_dir, "UPSTREAM-PACKAGES.txt")
    if os.path.isfile(build_info_file):
        with open(build_info_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("Resolved release:"):
                    prev["immortalwrt_release"] = line.split(":", 1)[1].strip()
                elif line.startswith("Homepage API commit:"):
                    prev["homepage_api_commit"] = line.split(":", 1)[1].strip()
                elif line.startswith("Commit:"):
                    prev["local_sha"] = line.split(":", 1)[1].strip()
    if os.path.isfile(upstream_pkg_file):
        with open(upstream_pkg_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 4:
                    if parts[1] == "open-box":
                        prev["openbox_tag"] = parts[3].strip()
                    elif parts[1] == "openclash":
                        prev["openclash_tag"] = parts[3].strip()
                    elif parts[1] == "passwall":
                        prev["passwall_commit"] = parts[4].strip() if len(parts) > 4 else parts[3].strip()

diffs = []
keys = [
    ("immortalwrt_release", "ImmortalWrt"),
    ("openbox_tag", "Open-Box"),
    ("openclash_tag", "OpenClash"),
    ("passwall_commit", "PassWall"),
    ("homepage_api_commit", "Homepage API"),
    ("local_sha", "Local SHA"),
]

if not prev:
    diffs.append("No previous release metadata parsed")
else:
    for key, label in keys:
        c = current.get(key, "").strip()
        p = prev.get(key, "").strip()
        if c and p and c != p:
            diffs.append(f"{label}: {p[:10]} -> {c[:10]}")
        elif c and not p:
            diffs.append(f"{label}: new {c[:10]}")

print("; ".join(diffs))
PYEOF
)"

if [ -n "${diff_result}" ]; then
  echo "Changes detected: ${diff_result}"
  echo "need_build=true" >> "${output_file}"
  echo "build_reason=${diff_result}" >> "${output_file}"
else
  echo "No upstream or local changes detected. Firmware is up to date."
  echo "need_build=false" >> "${output_file}"
  echo "build_reason=No changes" >> "${output_file}"
fi
