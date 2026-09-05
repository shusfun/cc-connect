#!/bin/sh
# 将固定版本、目标架构的 Node 与当前 Bridge 复制进 App，不依赖全局 npm/CLI。
set -eu

NODE_VERSION="26.6.0"
case "${REMODEX_NODE_ARCH:?Set REMODEX_NODE_ARCH to x64 or arm64}" in
  x64) NODE_SHA256="de075ffc09f33cc4b44ed38e1e4b2ef71f699b986f6d5952329da4973220726d" ;;
  arm64) NODE_SHA256="75480cd43b6fcb35d8e772dd18983fbd9f691b2f03b1c94393206098e9944b5e" ;;
  *) echo "Unsupported Node architecture" >&2; exit 1 ;;
esac
NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-${REMODEX_NODE_ARCH}.tar.gz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
RUNTIME_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/RemodexRuntime"
CACHE_ROOT="${PROJECT_TEMP_DIR}/remodex-node-${NODE_VERSION}-${REMODEX_NODE_ARCH}"
ARCHIVE_PATH="${CACHE_ROOT}/${NODE_ARCHIVE}"
EXTRACT_ROOT="${CACHE_ROOT}/extract"
REPO_ROOT="$(cd "${SRCROOT}/.." && pwd)"

mkdir -p "${CACHE_ROOT}" "${RUNTIME_ROOT}/node" "${RUNTIME_ROOT}/bridge"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  /usr/bin/curl --fail --location --retry 3 --output "${ARCHIVE_PATH}" "${NODE_URL}"
fi

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')"
if [ "${ACTUAL_SHA256}" != "${NODE_SHA256}" ]; then
  echo "Node archive checksum mismatch" >&2
  exit 1
fi

if [ ! -x "${EXTRACT_ROOT}/node-v${NODE_VERSION}-darwin-${REMODEX_NODE_ARCH}/bin/node" ]; then
  mkdir -p "${EXTRACT_ROOT}"
  /usr/bin/tar -xzf "${ARCHIVE_PATH}" -C "${EXTRACT_ROOT}"
fi

/usr/bin/rsync -a --delete "${EXTRACT_ROOT}/node-v${NODE_VERSION}-darwin-${REMODEX_NODE_ARCH}/" "${RUNTIME_ROOT}/node/"
BRIDGE_BUNDLE="${REMODEX_BRIDGE_BUNDLE:-${REPO_ROOT}/build/bridge-bundle}"
test -f "${BRIDGE_BUNDLE}/bin/remodex-app-helper.js"
/usr/bin/rsync -aL --delete "${BRIDGE_BUNDLE}/" "${RUNTIME_ROOT}/bridge/"
/bin/chmod 755 "${RUNTIME_ROOT}/node/bin/node" "${RUNTIME_ROOT}/bridge/bin/remodex-app-helper.js"
ICONSET="${PROJECT_TEMP_DIR}/Remodex.iconset"
/usr/bin/swift "${SRCROOT}/scripts/build-macos-icon.swift" "${SRCROOT}/CodexMobile/Remodex.icon/Assets/Group 5.png" "${ICONSET}"
/usr/bin/iconutil -c icns "${ICONSET}" -o "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Remodex.icns"
test -s "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Remodex.icns"
