#!/usr/bin/env node
// FILE: remodex-app-helper.js
// Purpose: Runs the bundled bridge under Remodex.app ownership and exits when the parent pipe closes.
// Layer: Bundled macOS helper
// Exports: none
// Depends on: ../src/bridge, ../src/daemon-state, ../src/secure-device-state, ../src/session-state

const { startBridge } = require("../src/bridge");
const { readBridgeConfig } = require("../src/codex-desktop-refresher");
const {
  clearBridgeStatus,
  clearPairingSession,
  ensureRemodexLogsDir,
  ensureRemodexStateDir,
  readBridgeStatus,
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
} = require("../src/daemon-state");
const { resetBridgeTrustState } = require("../src/secure-device-state");
const { openLastActiveThread } = require("../src/session-state");

const command = process.argv[2] || "run";

if (command === "reset-pairing") {
  resetBridgeTrustState();
  process.exit(0);
}

if (command === "resume") {
  openLastActiveThread();
  process.exit(0);
}

if (command !== "run") {
  console.error(`[remodex] Unsupported app helper command: ${command}`);
  process.exit(2);
}

const config = readBridgeConfig();
if (!config.relayUrl) {
  console.error("[remodex] No relay URL configured for Remodex.app.");
  process.exit(1);
}

ensureRemodexStateDir();
ensureRemodexLogsDir();
writeDaemonConfig(config);
clearPairingSession();
clearBridgeStatus();

let exiting = false;
function stopWithParent() {
  if (exiting) return;
  exiting = true;
  process.kill(process.pid, "SIGTERM");
}

process.stdin.resume();
process.stdin.once("end", stopWithParent);
process.stdin.once("close", stopWithParent);

startBridge({
  config,
  printPairingQr: false,
  onPairingSession(pairingSession) {
    writePairingSession(pairingSession);
  },
  onBridgeStatus(status) {
    const previous = readBridgeStatus() || {};
    writeBridgeStatus({ ...previous, ...status });
  },
});
