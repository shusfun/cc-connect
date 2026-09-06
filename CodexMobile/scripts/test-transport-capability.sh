#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo '此入口需要 macOS 和 Swift。' >&2; exit 1; }
[[ "$(node --version)" == v26.6.0 ]] || { echo '需要 Node 26.6.0。' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/remodex-transport-tests.XXXXXX")"
echo "本地能力证据目录：$WORK"
swift build --package-path "$ROOT/CodexMobile" --scratch-path "$WORK/build" --cache-path "$WORK/cache" --disable-keychain --disable-netrc
SDK="$WORK/build/artifacts/codexmobile/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
[[ -d "$SDK/WebRTC.framework" ]] || { echo '缺少锁定的 Mac WebRTC Framework。' >&2; exit 1; }
swiftc -swift-version 5 -emit-library -emit-module -module-name LDSwiftEventSource \
  "$WORK/build/checkouts/swift-eventsource/Source/"*.swift \
  -o "$WORK/libLDSwiftEventSource.dylib" -emit-module-path "$WORK/LDSwiftEventSource.swiftmodule"
COMMON=(-swift-version 5 -parse-as-library -I "$WORK" -L "$WORK" -lLDSwiftEventSource -F "$SDK" -framework WebRTC \
  -Xlinker -rpath -Xlinker "$WORK" -Xlinker -rpath -Xlinker "$SDK")
for NAME in transport-policy peer-data-channel native-signaling access-http; do
  swiftc "${COMMON[@]}" "$ROOT/CodexMobile/SharedTransport/"*.swift "$ROOT/CodexMobile/scripts/test-$NAME.swift" -o "$WORK/$NAME"
done
"$WORK/transport-policy"
"$WORK/peer-data-channel"
node "$ROOT/relay/scripts/test-native-transport.js" "$WORK/native-signaling" "${REMODEX_TEST_PATH:-direct}"
node "$ROOT/relay/scripts/test-native-access.js" "$WORK/access-http"
swiftc "${COMMON[@]}" "$ROOT/CodexMobile/scripts/test-webrtc-capability.swift" -o "$WORK/webrtc-cycles"
"$WORK/webrtc-cycles" "${REMODEX_TEST_CYCLES:-100}"
swiftc -swift-version 5 -parse-as-library "$ROOT/CodexMobile/RemodexMenuBar/AsyncProcessRunner.swift" \
  "$ROOT/CodexMobile/scripts/test-macos-process.swift" -o "$WORK/process-tests"
"$WORK/process-tests" "$(command -v node)"
echo '本地能力验证通过；这不代表 iPhone、公网 HTTPS、TURN 全路径或发布验收通过。'
