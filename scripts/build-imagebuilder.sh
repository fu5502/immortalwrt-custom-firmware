#!/usr/bin/env bash
set -euo pipefail

RELEASE="${RELEASE:-latest}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"
HOMEPAGE_API_REPO="${HOMEPAGE_API_REPO:-fu5502/luci-app-homepage-api}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://downloads.immortalwrt.org/releases}"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
workdir="${RUNNER_TEMP:-/tmp}/immortalwrt-imagebuilder"
artifacts="${workspace}/artifacts"
target_dash="${TARGET_PATH//\//-}"
requested_release="${RELEASE}"

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

if [ "${RELEASE}" = "latest" ]; then
  RELEASE="$(resolve_latest_release)"
  echo "Resolved latest ImmortalWrt release: ${RELEASE}"
fi

if [ -z "${IMAGEBUILDER_URL}" ]; then
  IMAGEBUILDER_URL="${DOWNLOAD_BASE}/${RELEASE}/targets/${TARGET_PATH}/immortalwrt-imagebuilder-${RELEASE}-${target_dash}.Linux-x86_64.tar.zst"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "REQUESTED_RELEASE=${requested_release}"
    echo "RESOLVED_RELEASE=${RELEASE}"
    echo "IMAGEBUILDER_URL=${IMAGEBUILDER_URL}"
  } >> "${GITHUB_ENV}"
fi

rm -rf "${workdir}" "${artifacts}"
mkdir -p "${workdir}" "${artifacts}"

echo "Downloading ImageBuilder:"
echo "${IMAGEBUILDER_URL}"
curl -fL --retry 3 -o "${workdir}/imagebuilder.tar.zst" "${IMAGEBUILDER_URL}"
tar --zstd -xf "${workdir}/imagebuilder.tar.zst" -C "${workdir}" --strip-components=1

custom_files="${workdir}/custom-files"
mkdir -p "${custom_files}"

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
Homepage API source: https://github.com/${HOMEPAGE_API_REPO}
Homepage API commit: ${homepage_api_commit}
Commit: ${GITHUB_SHA:-local}
EOF
