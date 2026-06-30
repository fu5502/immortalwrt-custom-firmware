#!/usr/bin/env bash
set -euo pipefail

RELEASE="${RELEASE:-25.12.0}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"
HOMEPAGE_API_REPO="${HOMEPAGE_API_REPO:-fu5502/luci-app-homepage-api}"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
workdir="${RUNNER_TEMP:-/tmp}/immortalwrt-imagebuilder"
artifacts="${workspace}/artifacts"
target_dash="${TARGET_PATH//\//-}"

if [ -z "${IMAGEBUILDER_URL}" ]; then
  IMAGEBUILDER_URL="https://downloads.immortalwrt.org/releases/${RELEASE}/targets/${TARGET_PATH}/immortalwrt-imagebuilder-${RELEASE}-${target_dash}.Linux-x86_64.tar.zst"
fi

rm -rf "${workdir}" "${artifacts}"
mkdir -p "${workdir}" "${artifacts}"

echo "Downloading ImageBuilder:"
echo "${IMAGEBUILDER_URL}"
curl -fL --retry 3 -o "${workdir}/imagebuilder.tar.zst" "${IMAGEBUILDER_URL}"
tar --zstd -xf "${workdir}/imagebuilder.tar.zst" -C "${workdir}" --strip-components=1

custom_files="${workdir}/custom-files"
mkdir -p "${custom_files}"

if [ -d "${workspace}/files" ]; then
  rsync -a "${workspace}/files/" "${custom_files}/"
fi

echo "Embedding Homepage API plugin files from ${HOMEPAGE_API_REPO}"
git clone --depth 1 "https://github.com/${HOMEPAGE_API_REPO}.git" "${workdir}/homepage-api"
rsync -a "${workdir}/homepage-api/root/" "${custom_files}/"
mkdir -p "${custom_files}/www"
rsync -a "${workdir}/homepage-api/htdocs/" "${custom_files}/www/"
chmod +x \
  "${custom_files}/etc/init.d/homepage-api" \
  "${custom_files}/etc/uci-defaults/90_luci-app-homepage-api" \
  "${custom_files}/usr/libexec/homepage-api/apply" \
  "${custom_files}/etc/uci-defaults/99-fu550-custom-firmware"

packages="$(
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${workspace}/config/packages.txt" |
    tr '\n' ' ' |
    sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'
)"

echo "Release: ${RELEASE}"
echo "Target: ${TARGET_PATH}"
echo "Profile: ${PROFILE}"
echo "Rootfs partsize: ${ROOTFS_PARTSIZE} MB"
echo "Packages: ${packages}"

make -C "${workdir}" image \
  PROFILE="${PROFILE}" \
  ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}" \
  PACKAGES="${packages}" \
  FILES="${custom_files}" \
  V=s

find "${workdir}/bin/targets" -type f \
  \( -name '*ext4-combined*.img.gz' \
     -o -name '*ext4-combined*.qcow2' \
     -o -name '*ext4-combined*.vmdk' \
     -o -name '*profiles.json' \
     -o -name '*sha256sums' \) \
  -print -exec cp -v {} "${artifacts}/" \;

test "$(find "${artifacts}" -type f | wc -l)" -gt 0
(
  cd "${artifacts}"
  sha256sum * > SHA256SUMS.txt
)

cat > "${artifacts}/BUILD-INFO.txt" <<EOF
ImmortalWrt custom firmware
Release: ${RELEASE}
Target: ${TARGET_PATH}
Profile: ${PROFILE}
Rootfs partsize: ${ROOTFS_PARTSIZE} MB
ImageBuilder: ${IMAGEBUILDER_URL}
Homepage API source: https://github.com/${HOMEPAGE_API_REPO}
Commit: ${GITHUB_SHA:-local}
EOF
