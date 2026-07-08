#!/usr/bin/env bash
set -euo pipefail

RELEASE="${RELEASE:-latest}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"
HOMEPAGE_API_REPO="${HOMEPAGE_API_REPO:-fu5502/luci-app-homepage-api}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://downloads.immortalwrt.org/releases}"
OPENCLASH_REPO="${OPENCLASH_REPO:-vernesong/OpenClash}"
PASSWALL_FEED_REPO="${PASSWALL_FEED_REPO:-Openwrt-Passwall/openwrt-passwall}"
BUILD_UPSTREAM_PROXY_PACKAGES="${BUILD_UPSTREAM_PROXY_PACKAGES:-1}"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
run_root="${RUNNER_TEMP:-/tmp}/immortalwrt-custom-firmware"
workdir="${run_root}/imagebuilder"
sdkdir="${run_root}/sdk"
artifacts="${workspace}/artifacts"
target_dash="${TARGET_PATH//\//-}"
requested_release="${RELEASE}"
openclash_version="release-feed"
openclash_asset="release-feed"
passwall_commit="release-feed"

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

echo "Downloading ImageBuilder:"
echo "${IMAGEBUILDER_URL}"
curl -fL --retry 3 -o "${workdir}/imagebuilder.tar.zst" "${IMAGEBUILDER_URL}"
tar --zstd -xf "${workdir}/imagebuilder.tar.zst" -C "${workdir}" --strip-components=1

custom_files="${workdir}/custom-files"
mkdir -p "${custom_files}"
upstream_package_dir="${workdir}/packages"
mkdir -p "${upstream_package_dir}"

download_latest_openclash_apk() {
  local api_url release_json asset_url asset_name

  api_url="https://api.github.com/repos/${OPENCLASH_REPO}/releases/latest"
  release_json="$(curl -fsSL --retry 3 "${api_url}")"
  openclash_version="$(
    printf '%s\n' "${release_json}" |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name", "unknown"))'
  )"
  asset_url="$(
    printf '%s\n' "${release_json}" |
      python3 -c 'import json,sys; data=json.load(sys.stdin); assets=data.get("assets", []); matches=[a for a in assets if a.get("name","").endswith(".apk") and a.get("name","").startswith("luci-app-openclash-")]; print(matches[0]["browser_download_url"] if matches else "")'
  )"

  if [ -z "${asset_url}" ]; then
    echo "Could not find latest OpenClash .apk asset in ${OPENCLASH_REPO}" >&2
    exit 1
  fi

  asset_name="$(basename "${asset_url}")"
  openclash_asset="${asset_name}"
  echo "Downloading latest OpenClash package: ${asset_name}"
  curl -fL --retry 3 -o "${upstream_package_dir}/${asset_name}" "${asset_url}"
}

build_latest_passwall_apks() {
  local sdk_packages_dir

  echo "Downloading ImmortalWrt SDK:"
  echo "${SDK_URL}"
  mkdir -p "${sdkdir}"
  curl -fL --retry 3 -o "${sdkdir}/sdk.tar.zst" "${SDK_URL}"
  tar --zstd -xf "${sdkdir}/sdk.tar.zst" -C "${sdkdir}" --strip-components=1

  echo "Adding upstream PassWall feeds"
  {
    echo "src-git passwall https://github.com/${PASSWALL_FEED_REPO}.git;main"
  } >> "${sdkdir}/feeds.conf.default"

  make -C "${sdkdir}" defconfig
  "${sdkdir}/scripts/feeds" update base packages routing luci passwall
  passwall_commit="$(git -C "${sdkdir}/feeds/passwall" rev-parse HEAD)"
  "${sdkdir}/scripts/feeds" install -p base -a
  "${sdkdir}/scripts/feeds" install -p packages -a
  "${sdkdir}/scripts/feeds" install -p routing -a
  "${sdkdir}/scripts/feeds" install -p luci -a
  "${sdkdir}/scripts/feeds" install -p passwall -a

  cat >> "${sdkdir}/.config" <<'EOF'
CONFIG_PACKAGE_luci-app-passwall=m
CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=n
EOF

  make -C "${sdkdir}" defconfig
  make -C "${sdkdir}" package/luci-app-passwall/compile -j"$(nproc)" V=s

  sdk_packages_dir="${sdkdir}/bin/packages"
  find "${sdk_packages_dir}" -type f \
    \( -name 'luci-app-passwall-*.apk' -o -name 'luci-i18n-passwall-zh-cn-*.apk' \) \
    -exec cp -v {} "${upstream_package_dir}/" \;

  if ! compgen -G "${upstream_package_dir}/luci-app-passwall-*.apk" >/dev/null; then
    echo "PassWall build finished but luci-app-passwall apk was not found" >&2
    exit 1
  fi
}

if [ "${BUILD_UPSTREAM_PROXY_PACKAGES}" = "1" ]; then
  download_latest_openclash_apk
  build_latest_passwall_apks
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

echo "Release: ${RELEASE}"
echo "Requested release: ${requested_release}"
echo "Target: ${TARGET_PATH}"
echo "Profile: ${PROFILE}"
echo "Rootfs partsize: ${ROOTFS_PARTSIZE} MB"
echo "Homepage API commit: ${homepage_api_commit}"
echo "OpenClash source: ${OPENCLASH_REPO} ${openclash_version} ${openclash_asset}"
echo "PassWall source: ${PASSWALL_FEED_REPO} ${passwall_commit}"
echo "Packages: ${packages}"

make -C "${workdir}" image \
  PROFILE="${PROFILE}" \
  ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}" \
  PACKAGES="${packages}" \
  FILES="${custom_files}" \
  V=s

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
OpenClash source: https://github.com/${OPENCLASH_REPO} ${openclash_version}
OpenClash asset: ${openclash_asset}
PassWall source: https://github.com/${PASSWALL_FEED_REPO} ${passwall_commit}
Commit: ${GITHUB_SHA:-local}
EOF
