#!/bin/sh
# 将固定版本的 x86_64 Node 与当前 Bridge 复制进 Remodex.app，不依赖全局 npm/CLI。
set -eu

NODE_VERSION="26.6.0"
NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-x64.tar.gz"
NODE_SHA256="de075ffc09f33cc4b44ed38e1e4b2ef71f699b986f6d5952329da4973220726d"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
RUNTIME_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/RemodexRuntime"
CACHE_ROOT="${PROJECT_TEMP_DIR}/remodex-node-${NODE_VERSION}"
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

if [ ! -x "${EXTRACT_ROOT}/node-v${NODE_VERSION}-darwin-x64/bin/node" ]; then
  mkdir -p "${EXTRACT_ROOT}"
  /usr/bin/tar -xzf "${ARCHIVE_PATH}" -C "${EXTRACT_ROOT}"
fi

/usr/bin/rsync -a --delete "${EXTRACT_ROOT}/node-v${NODE_VERSION}-darwin-x64/" "${RUNTIME_ROOT}/node/"
/usr/bin/rsync -a --delete \
  --exclude 'node_modules' \
  --exclude 'test' \
  --exclude 'scripts' \
  "${REPO_ROOT}/phodex-bridge/" "${RUNTIME_ROOT}/bridge/"
/usr/bin/rsync -aL --delete "${REPO_ROOT}/phodex-bridge/node_modules/" "${RUNTIME_ROOT}/bridge/node_modules/"
/bin/chmod 755 "${RUNTIME_ROOT}/node/bin/node" "${RUNTIME_ROOT}/bridge/bin/remodex-app-helper.js"
