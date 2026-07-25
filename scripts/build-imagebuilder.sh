#!/usr/bin/env bash
set -euo pipefail

RELEASE="${RELEASE:-latest}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"
HOMEPAGE_API_REPO="${HOMEPAGE_API_REPO:-fu5502/luci-app-homepage-api}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://downloads.immortalwrt.org/releases}"
BUILD_UPSTREAM_PACKAGES="${BUILD_UPSTREAM_PACKAGES:-${BUILD_UPSTREAM_PROXY_PACKAGES:-1}}"
UPSTREAM_APK_REPOSITORIES_FILE="${UPSTREAM_APK_REPOSITORIES_FILE:-config/upstream-apk-repositories.txt}"
UPSTREAM_RELEASE_APKS_FILE="${UPSTREAM_RELEASE_APKS_FILE:-config/upstream-release-apks.txt}"
UPSTREAM_SDK_PACKAGES_FILE="${UPSTREAM_SDK_PACKAGES_FILE:-config/upstream-sdk-packages.txt}"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
run_root="${RUNNER_TEMP:-/tmp}/immortalwrt-custom-firmware"
workdir="${run_root}/imagebuilder"
sdkdir="${run_root}/sdk"
artifacts="${workspace}/artifacts"
target_dash="${TARGET_PATH//\//-}"
requested_release="${RELEASE}"
upstream_summary="${run_root}/UPSTREAM-PACKAGES.txt"
firmware_contents_summary="${run_root}/FIRMWARE-CONTENTS.txt"
upstream_extra_packages=""

resolve_python() {
  local candidate

  if [ -n "${PYTHON:-}" ]; then
    if "${PYTHON}" -c 'import json' >/dev/null 2>&1; then
      printf '%s\n' "${PYTHON}"
      return
    fi
    echo "Configured PYTHON is not usable: ${PYTHON}" >&2
    exit 1
  fi

  for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import json' >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  echo "Could not find a usable Python interpreter" >&2
  exit 1
}

PYTHON_BIN="$(resolve_python)"

resolve_latest_release() {
  local release_index latest_release

  release_index="$(curl -fsSL --retry 3 "${DOWNLOAD_BASE}/")"
  latest_release="$(
    printf '%s\n' "${release_index}" |
      grep -Eo 'href="[0-9]+(\.[0-9]+){1,2}/"' |
      sed -E 's|href="([^"]+)/"|\1|' |
      sort -V |
      tail -n 1
  )"

  if [ -z "${latest_release}" ]; then
    echo "Could not resolve latest ImmortalWrt release from ${DOWNLOAD_BASE}/" >&2
    exit 1
  fi

  printf '%s\n' "${latest_release}"
}

resolve_sdk_url() {
  local target_index sdk_name

  target_index="$(curl -fsSL --retry 3 "${DOWNLOAD_BASE}/${RELEASE}/targets/${TARGET_PATH}/")"
  sdk_name="$(
    printf '%s\n' "${target_index}" |
      grep -Eo "immortalwrt-sdk-${RELEASE}-${target_dash}[^\"<]*\\.tar\\.zst" |
      sort -V |
      tail -n 1
  )"

  if [ -z "${sdk_name}" ]; then
    echo "Could not resolve ImmortalWrt SDK for ${RELEASE} ${TARGET_PATH}" >&2
    exit 1
  fi

  printf '%s/%s/targets/%s/%s\n' "${DOWNLOAD_BASE}" "${RELEASE}" "${TARGET_PATH}" "${sdk_name}"
}

if [ "${RELEASE}" = "latest" ]; then
  RELEASE="$(resolve_latest_release)"
  echo "Resolved latest ImmortalWrt release: ${RELEASE}"
fi

if [ -z "${IMAGEBUILDER_URL}" ]; then
  IMAGEBUILDER_URL="${DOWNLOAD_BASE}/${RELEASE}/targets/${TARGET_PATH}/immortalwrt-imagebuilder-${RELEASE}-${target_dash}.Linux-x86_64.tar.zst"
fi

SDK_URL="${SDK_URL:-$(resolve_sdk_url)}"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "REQUESTED_RELEASE=${requested_release}"
    echo "RESOLVED_RELEASE=${RELEASE}"
    echo "IMAGEBUILDER_URL=${IMAGEBUILDER_URL}"
    echo "SDK_URL=${SDK_URL}"
  } >> "${GITHUB_ENV}"
fi

rm -rf "${run_root}" "${artifacts}"
mkdir -p "${workdir}" "${artifacts}"
mkdir -p "$(dirname "${upstream_summary}")"
: > "${upstream_summary}"

echo "Downloading ImageBuilder:"
echo "${IMAGEBUILDER_URL}"
curl -fL --retry 3 -o "${workdir}/imagebuilder.tar.zst" "${IMAGEBUILDER_URL}"
tar --zstd -xf "${workdir}/imagebuilder.tar.zst" -C "${workdir}" --strip-components=1

custom_files="${workdir}/custom-files"
mkdir -p "${custom_files}"
upstream_package_dir="${workdir}/packages"
mkdir -p "${upstream_package_dir}"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

add_unique_word() {
  local word="$1"
  local current="$2"

  case " ${current} " in
    *" ${word} "*) printf '%s' "${current}" ;;
    *) printf '%s' "$(trim "${current} ${word}")" ;;
  esac
}

configure_upstream_apk_repositories() {
  local config_file="${workspace}/${UPSTREAM_APK_REPOSITORIES_FILE}"
  local repositories_file="${workdir}/repositories"
  local line name key_url repository_urls package_names repository_url key_path

  if [ ! -s "${config_file}" ]; then
    echo "No upstream apk repository config found at ${config_file}; skipping"
    return
  fi

  if [ ! -f "${repositories_file}" ]; then
    echo "ImageBuilder apk repositories file not found: ${repositories_file}" >&2
    exit 1
  fi

  mkdir -p "${workdir}/keys"

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    line="$(trim "${line}")"
    [ -z "${line}" ] && continue

    IFS='|' read -r name key_url repository_urls package_names _ <<< "${line}"
    name="$(trim "${name}")"
    key_url="$(trim "${key_url}")"
    repository_urls="$(trim "${repository_urls}")"
    package_names="$(trim "${package_names}")"

    if [ -z "${name}" ] || [ -z "${key_url}" ] || [ -z "${repository_urls}" ] || [ -z "${package_names}" ]; then
      echo "Invalid upstream apk repository entry: ${line}" >&2
      exit 1
    fi

    echo "Adding upstream apk repository group: ${name}"
    key_path="${workdir}/keys/${name}.pem"
    curl -fL --retry 3 -o "${key_path}" "${key_url}"

    for repository_url in ${repository_urls}; do
      if ! grep -qxF "${repository_url}" "${repositories_file}"; then
        echo "${repository_url}" >> "${repositories_file}"
      fi
    done

    for package_name in ${package_names}; do
      upstream_extra_packages="$(add_unique_word "${package_name}" "${upstream_extra_packages}")"
    done

    printf 'apk-repo|%s|%s|%s|%s\n' "${name}" "${key_url}" "${repository_urls}" "${package_names}" >> "${upstream_summary}"
  done < "${config_file}"
}

download_upstream_release_apks() {
  local config_file="${workspace}/${UPSTREAM_RELEASE_APKS_FILE}"
  local line name repo asset_regex api_url release_json tag asset_info asset_url asset_name

  if [ ! -s "${config_file}" ]; then
    echo "No upstream release apk config found at ${config_file}; skipping"
    return
  fi

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    line="$(trim "${line}")"
    [ -z "${line}" ] && continue

    IFS='|' read -r name repo asset_regex _ <<< "${line}"
    name="$(trim "${name}")"
    repo="$(trim "${repo}")"
    asset_regex="$(trim "${asset_regex}")"

    if [ -z "${name}" ] || [ -z "${repo}" ] || [ -z "${asset_regex}" ]; then
      echo "Invalid upstream release apk entry: ${line}" >&2
      exit 1
    fi

    api_url="https://api.github.com/repos/${repo}/releases/latest"
    release_json="$(curl -fsSL --retry 3 "${api_url}")"
    tag="$(
      printf '%s\n' "${release_json}" |
        "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin).get("tag_name", "unknown"))'
    )"
    asset_info="$(
      printf '%s\n' "${release_json}" |
        "${PYTHON_BIN}" -c 'import json,re,sys; data=json.load(sys.stdin); pat=re.compile(sys.argv[1]); matches=[a for a in data.get("assets", []) if pat.search(a.get("name", ""))]; print(matches[0]["browser_download_url"] + "|" + matches[0]["name"] if matches else "")' "${asset_regex}"
    )"

    if [ -z "${asset_info}" ]; then
      echo "Could not find latest ${name} asset matching ${asset_regex} in ${repo}" >&2
      exit 1
    fi

    asset_url="${asset_info%%|*}"
    asset_name="${asset_info#*|}"
    echo "Downloading latest ${name} package: ${asset_name}"
    curl -fL --retry 3 -o "${upstream_package_dir}/${asset_name}" "${asset_url}"
    printf 'release-apk|%s|https://github.com/%s|%s|%s\n' "${name}" "${repo}" "${tag}" "${asset_name}" >> "${upstream_summary}"
  done < "${config_file}"
}

build_upstream_sdk_packages() {
  local config_file="${workspace}/${UPSTREAM_SDK_PACKAGES_FILE}"
  local line name feed repo branch make_target artifact_globs kconfig_snippet
  local feed_names="base packages routing luci"
  local sdk_packages_dir built_count feed_commit artifact_glob snippet_path
  local -a sdk_entries=()

  if [ ! -s "${config_file}" ]; then
    echo "No upstream SDK package config found at ${config_file}; skipping"
    return
  fi

  echo "Downloading ImmortalWrt SDK:"
  echo "${SDK_URL}"
  mkdir -p "${sdkdir}"
  curl -fL --retry 3 -o "${sdkdir}/sdk.tar.zst" "${SDK_URL}"
  tar --zstd -xf "${sdkdir}/sdk.tar.zst" -C "${sdkdir}" --strip-components=1

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    line="$(trim "${line}")"
    [ -z "${line}" ] && continue

    IFS='|' read -r name feed repo branch make_target artifact_globs kconfig_snippet _ <<< "${line}"
    name="$(trim "${name}")"
    feed="$(trim "${feed}")"
    repo="$(trim "${repo}")"
    branch="$(trim "${branch}")"
    make_target="$(trim "${make_target}")"
    artifact_globs="$(trim "${artifact_globs}")"
    kconfig_snippet="$(trim "${kconfig_snippet:-}")"

    if [ -z "${name}" ] || [ -z "${feed}" ] || [ -z "${repo}" ] || [ -z "${branch}" ] || [ -z "${make_target}" ] || [ -z "${artifact_globs}" ]; then
      echo "Invalid upstream SDK package entry: ${line}" >&2
      exit 1
    fi

    echo "src-git ${feed} ${repo};${branch}" >> "${sdkdir}/feeds.conf.default"
    feed_names="$(add_unique_word "${feed}" "${feed_names}")"
    sdk_entries+=("${name}|${feed}|${repo}|${branch}|${make_target}|${artifact_globs}|${kconfig_snippet:-}")
  done < "${config_file}"

  make -C "${sdkdir}" defconfig
  "${sdkdir}/scripts/feeds" update ${feed_names}

  for feed in ${feed_names}; do
    "${sdkdir}/scripts/feeds" install -p "${feed}" -a
  done

  for line in "${sdk_entries[@]}"; do
    IFS='|' read -r name feed repo branch make_target artifact_globs kconfig_snippet <<< "${line}"
    if [ -n "${kconfig_snippet}" ] && [ "${kconfig_snippet}" != "-" ]; then
      snippet_path="${workspace}/${kconfig_snippet}"
      if [ ! -f "${snippet_path}" ]; then
        echo "Kconfig snippet for ${name} not found: ${snippet_path}" >&2
        exit 1
      fi
      cat "${snippet_path}" >> "${sdkdir}/.config"
    fi
  done

  make -C "${sdkdir}" defconfig
  sdk_packages_dir="${sdkdir}/bin/packages"

  for line in "${sdk_entries[@]}"; do
    IFS='|' read -r name feed repo branch make_target artifact_globs kconfig_snippet <<< "${line}"
    echo "Building latest ${name} from ${repo};${branch}"
    make -C "${sdkdir}" "${make_target}" -j"$(nproc)" V=s

    feed_commit="$(git -C "${sdkdir}/feeds/${feed}" rev-parse HEAD)"
    built_count=0
    for artifact_glob in ${artifact_globs}; do
      while IFS= read -r artifact; do
        cp -v "${artifact}" "${upstream_package_dir}/"
        built_count=$((built_count + 1))
      done < <(find "${sdk_packages_dir}" -type f -name "${artifact_glob}" | sort)
    done

    if [ "${built_count}" -eq 0 ]; then
      echo "${name} build finished but no artifact matched: ${artifact_globs}" >&2
      exit 1
    fi

    printf 'sdk-feed|%s|%s|%s|%s|%s artifacts\n' "${name}" "${repo}" "${branch}" "${feed_commit}" "${built_count}" >> "${upstream_summary}"
  done
}

verify_firmware_contents() {
  local installed_db rootfs_dir package version file
  local distfeeds_file firstboot_file
  local -a required_packages=(
    luci-app-store
    luci-app-quickstart
    quickstart
    taskd
    luci-lib-taskd
  )
  local -a required_files=(
    etc/init.d/istore
    etc/init.d/quickstart
    usr/lib/lua/luci/controller/store.lua
    usr/lib/lua/luci/controller/quickstart.lua
  )

  installed_db="$(
    find "${workdir}/build_dir" -type f \
      -path '*/lib/apk/db/installed' \
      -print \
      -quit
  )"

  if [ -z "${installed_db}" ]; then
    echo "Could not find the firmware APK installed database" >&2
    exit 1
  fi

  rootfs_dir="${installed_db%/lib/apk/db/installed}"
  distfeeds_file="${rootfs_dir}/etc/apk/repositories.d/distfeeds.list"
  firstboot_file="${rootfs_dir}/etc/uci-defaults/99-fu550-custom-firmware"
  : > "${firmware_contents_summary}"

  if [ ! -f "${distfeeds_file}" ]; then
    echo "Firmware distfeeds file is missing: ${distfeeds_file}" >&2
    exit 1
  fi
  if grep -Eq 'downloads\.openwrt\.org|mirrors\.vsean\.net/openwrt' "${distfeeds_file}"; then
    echo "Firmware distfeeds contains an incompatible OpenWrt repository:" >&2
    cat "${distfeeds_file}" >&2
    exit 1
  fi
  if ! grep -qF "${DOWNLOAD_BASE}/${RELEASE}/" "${distfeeds_file}"; then
    echo "Firmware distfeeds does not contain the expected ImmortalWrt release repository:" >&2
    cat "${distfeeds_file}" >&2
    exit 1
  fi
  printf 'repository|distfeeds|%s/%s/\n' "${DOWNLOAD_BASE}" "${RELEASE}" |
    tee -a "${firmware_contents_summary}"

  if [ ! -f "${firstboot_file}" ] ||
    ! grep -qF "apk_mirror='https://downloads.immortalwrt.org'" "${firstboot_file}"; then
    echo "Firmware first-boot source repair is missing or invalid: ${firstboot_file}" >&2
    exit 1
  fi
  printf 'firstboot|apk-mirror|https://downloads.immortalwrt.org\n' |
    tee -a "${firmware_contents_summary}"

  echo "Verifying required iStore and QuickStart packages in ${rootfs_dir}"
  for package in "${required_packages[@]}"; do
    if ! grep -qxF "P:${package}" "${installed_db}"; then
      echo "Required firmware package is missing: ${package}" >&2
      exit 1
    fi

    version="$(
      awk -v wanted="P:${package}" '
        $0 == wanted { found = 1; next }
        found && /^V:/ { print substr($0, 3); exit }
        found && $0 == "" { exit }
      ' "${installed_db}"
    )"
    printf 'package|%s|%s\n' "${package}" "${version:-unknown}" |
      tee -a "${firmware_contents_summary}"
  done

  for file in "${required_files[@]}"; do
    if [ ! -e "${rootfs_dir}/${file}" ]; then
      echo "Required firmware file is missing: /${file}" >&2
      exit 1
    fi
    printf 'file|/%s\n' "${file}" | tee -a "${firmware_contents_summary}"
  done
}

if [ "${BUILD_UPSTREAM_PACKAGES}" = "1" ]; then
  configure_upstream_apk_repositories
  download_upstream_release_apks
  build_upstream_sdk_packages
else
  echo "Upstream package refresh disabled; using ImmortalWrt release feeds only" | tee -a "${upstream_summary}"
fi

set_config() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "${workdir}/.config"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${workdir}/.config"
  elif grep -q "^# ${key} is not set" "${workdir}/.config"; then
    sed -i "s|^# ${key} is not set|${key}=${value}|" "${workdir}/.config"
  else
    echo "${key}=${value}" >> "${workdir}/.config"
  fi
}

unset_config() {
  local key="$1"

  if grep -q "^${key}=" "${workdir}/.config"; then
    sed -i "s|^${key}=.*|# ${key} is not set|" "${workdir}/.config"
  elif ! grep -q "^# ${key} is not set" "${workdir}/.config"; then
    echo "# ${key} is not set" >> "${workdir}/.config"
  fi
}

echo "Restricting ImageBuilder output to one PVE-friendly image"
unset_config CONFIG_TARGET_ROOTFS_TARGZ
unset_config CONFIG_TARGET_ROOTFS_SQUASHFS
set_config CONFIG_TARGET_ROOTFS_EXT4FS y
set_config CONFIG_TARGET_IMAGES_GZIP y
set_config CONFIG_GRUB_IMAGES y
unset_config CONFIG_GRUB_EFI_IMAGES
unset_config CONFIG_ISO_IMAGES
unset_config CONFIG_QCOW2_IMAGES
unset_config CONFIG_VDI_IMAGES
unset_config CONFIG_VMDK_IMAGES
unset_config CONFIG_VHDX_IMAGES
set_config CONFIG_TARGET_ROOTFS_PARTSIZE "${ROOTFS_PARTSIZE}"

if [ -d "${workspace}/files" ]; then
  rsync -a "${workspace}/files/" "${custom_files}/"
fi

echo "Embedding Homepage API plugin files from ${HOMEPAGE_API_REPO}"
git clone --depth 1 "https://github.com/${HOMEPAGE_API_REPO}.git" "${workdir}/homepage-api"
homepage_api_commit="$(git -C "${workdir}/homepage-api" rev-parse HEAD)"
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
packages="$(trim "${packages} ${upstream_extra_packages}")"

echo "Release: ${RELEASE}"
echo "Requested release: ${requested_release}"
echo "Target: ${TARGET_PATH}"
echo "Profile: ${PROFILE}"
echo "Rootfs partsize: ${ROOTFS_PARTSIZE} MB"
echo "Homepage API commit: ${homepage_api_commit}"
echo "Upstream package refresh: ${BUILD_UPSTREAM_PACKAGES}"
echo "Upstream package sources:"
sed 's/^/  /' "${upstream_summary}"
echo "Packages: ${packages}"

make -C "${workdir}" image \
  PROFILE="${PROFILE}" \
  ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}" \
  PACKAGES="${packages}" \
  FILES="${custom_files}" \
  V=s

if [ "${BUILD_UPSTREAM_PACKAGES}" = "1" ]; then
  verify_firmware_contents
else
  echo "verification|skipped|upstream package refresh disabled" > "${firmware_contents_summary}"
fi

mapfile -t firmware_images < <(
  find "${workdir}/bin/targets" -type f \
    -name '*ext4-combined.img.gz' \
    ! -name '*efi*' \
    | sort
)

if [ "${#firmware_images[@]}" -ne 1 ]; then
  printf 'Expected exactly one ext4-combined.img.gz image, found %s:\n' "${#firmware_images[@]}" >&2
  printf '%s\n' "${firmware_images[@]}" >&2
  exit 1
fi

cp -v "${firmware_images[0]}" "${artifacts}/"
cp -v "${upstream_summary}" "${artifacts}/UPSTREAM-PACKAGES.txt"
cp -v "${firmware_contents_summary}" "${artifacts}/FIRMWARE-CONTENTS.txt"
(
  cd "${artifacts}"
  sha256sum * > SHA256SUMS.txt
)

cat > "${artifacts}/BUILD-INFO.txt" <<EOF
ImmortalWrt custom firmware
Requested release: ${requested_release}
Resolved release: ${RELEASE}
Target: ${TARGET_PATH}
Profile: ${PROFILE}
Rootfs partsize: ${ROOTFS_PARTSIZE} MB
ImageBuilder: ${IMAGEBUILDER_URL}
SDK: ${SDK_URL}
Homepage API source: https://github.com/${HOMEPAGE_API_REPO}
Homepage API commit: ${homepage_api_commit}
Upstream package refresh: ${BUILD_UPSTREAM_PACKAGES}
Upstream apk repository config: ${UPSTREAM_APK_REPOSITORIES_FILE}
Upstream release apk config: ${UPSTREAM_RELEASE_APKS_FILE}
Upstream SDK package config: ${UPSTREAM_SDK_PACKAGES_FILE}
Firmware content verification: FIRMWARE-CONTENTS.txt
Commit: ${GITHUB_SHA:-local}
EOF

{
  echo
  echo "Upstream package sources:"
  cat "${upstream_summary}"
} >> "${artifacts}/BUILD-INFO.txt"
