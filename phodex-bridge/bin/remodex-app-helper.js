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
const { DeviceAccess } = require('../src/device-access');

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

let bootstrap = '';
let started = false;
const bootstrapTimeout = setTimeout(() => { console.error('[remodex] activation_required'); process.exit(1); }, 10000);
process.stdin.on('data', async chunk => {
  if (started) return;
  bootstrap += chunk.toString('utf8');
  if (bootstrap.length > 16384) { process.exit(1); return; }
  if (!bootstrap.includes('\n')) return;
  started = true;
  clearTimeout(bootstrapTimeout);
  try {
    const deviceAccess = new DeviceAccess(JSON.parse(bootstrap.slice(0, bootstrap.indexOf('\n'))));
    bootstrap = '';
    const current = await deviceAccess.request('/v1/access/device');
    deviceAccess.credential.device = current.device;
    deviceAccess.trustedPhone = current.trustedPhone;
    const pairingInvitation = await deviceAccess.request('/v1/access/pairing/invite');
    startBridge({
      config, deviceAccess, pairingInvitation, printPairingQr: false,
      onPairingSession(pairingSession) { writePairingSession(pairingSession); },
      onBridgeStatus(status) { writeBridgeStatus({ ...(readBridgeStatus() || {}), ...status }); },
    });
  } catch (error) {
    console.error(`[remodex] ${error.code || 'activation_failed'}`);
    process.exit(1);
  }
});
