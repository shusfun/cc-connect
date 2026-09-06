#!/usr/bin/env node
// FILE: remodex-app-helper.js
// Purpose: Runs the bundled bridge under Remodex.app ownership and exits when the parent pipe closes.
// Layer: Bundled macOS helper
// Exports: none
// Depends on: ../src/bridge, ../src/daemon-state, ../src/secure-device-state, ../src/session-state

const command = process.argv[2] || 'run';
if (command === 'control' && process.platform !== 'win32') {
  const workerCommand = process.argv[3];
  if (!['resume', 'reset-pairing'].includes(workerCommand)) {
    console.error('[remodex] control_command_invalid');
    process.exit(2);
  }
  require('../src/app-supervisor').supervise(__filename, { workerCommand });
  return;
}
if (command === 'run' && process.platform !== 'win32') {
  require('../src/app-supervisor').supervise(__filename);
  return;
}

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
const { recoverStartup, startupFailure } = require('../src/startup-recovery');

if (command === "reset-pairing") {
  resetBridgeTrustState();
  process.exit(0);
}

if (command === "resume") {
  openLastActiveThread();
  process.exit(0);
}

if (command !== "run" && command !== "worker") {
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
const startupAbort = new AbortController();
function stopWithParent() {
  if (exiting) return;
  exiting = true;
  startupAbort.abort();
  process.kill(process.pid, "SIGTERM");
}

process.stdin.resume();
process.stdin.once("end", stopWithParent);
process.stdin.once("close", stopWithParent);

let bootstrap = '';
let started = false;
let refreshInvitation;
let controlInput = '';
const bootstrapTimeout = setTimeout(() => { console.error('[remodex] activation_required'); process.exit(1); }, 10000);
process.stdin.on('data', async chunk => {
  if (started) {
    controlInput += chunk.toString('utf8');
    if (controlInput.length > 1024) { process.exit(1); return; }
    while (controlInput.includes('\n')) {
      const end = controlInput.indexOf('\n'); const line = controlInput.slice(0, end); controlInput = controlInput.slice(end + 1);
      try {
        const command = JSON.parse(line);
        if (command.command !== 'refresh-pairing' || !refreshInvitation) throw new Error('control_not_ready');
        await refreshInvitation();
      } catch { console.error('[remodex] pairing_refresh_failed'); }
    }
    return;
  }
  bootstrap += chunk.toString('utf8');
  if (bootstrap.length > 16384) { process.exit(1); return; }
  if (!bootstrap.includes('\n')) return;
  started = true;
  clearTimeout(bootstrapTimeout);
  let startupStatus = { connectionStatus: 'connecting', state: 'starting', lastError: '' };
  const publishStartup = () => writeBridgeStatus({ ...startupStatus, ownerGeneration: process.env.REMODEX_OWNER_GENERATION });
  publishStartup();
  const startupHeartbeat = setInterval(publishStartup, 5000);
  try {
    const deviceAccess = new DeviceAccess(JSON.parse(bootstrap.slice(0, bootstrap.indexOf('\n'))));
    bootstrap = '';
    const pairingInvitation = await recoverStartup(async () => {
      const current = await deviceAccess.request('/v1/access/device', {}, { signal: startupAbort.signal });
      deviceAccess.credential.device = current.device;
      deviceAccess.trustedPhone = current.trustedPhone;
      return deviceAccess.request('/v1/access/pairing/invite', {}, { signal: startupAbort.signal });
    }, { signal: startupAbort.signal, onRetry: failure => {
      startupStatus = { connectionStatus: 'connecting', state: 'recovering', lastError: failure.code, retryAfterMs: failure.retryAfterMs };
      publishStartup();
    } });
    clearInterval(startupHeartbeat);
    startBridge({
      config, deviceAccess, pairingInvitation, printPairingQr: false,
      onControlReady(refresh) { refreshInvitation = refresh; },
      onPairingSession(pairingSession) { writePairingSession(pairingSession); },
      onBridgeStatus(status) { writeBridgeStatus({ ...(readBridgeStatus() || {}), ...status, ownerGeneration: process.env.REMODEX_OWNER_GENERATION }); },
    });
  } catch (error) {
    clearInterval(startupHeartbeat);
    if (startupAbort.signal.aborted) return;
    const failure = startupFailure(error);
    startupStatus = { connectionStatus: 'error', state: 'blocked', lastError: failure.terminal ? failure.code : 'activation_failed' };
    publishStartup();
    console.error(`[remodex] ${startupStatus.lastError}`);
  }
});
