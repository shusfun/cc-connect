// FILE: index.js
// Purpose: Exposes the app-owned Bridge runtime and local support APIs.
// Layer: Bridge module entry
// Exports: bridge lifecycle, pairing reset, thread resume, and rollout watching.
// Depends on: ./bridge, ./secure-device-state, ./session-state, ./rollout-watch

const { startBridge } = require("./bridge");
const { readBridgeDeviceState, resetBridgeTrustState } = require("./secure-device-state");
const { openLastActiveThread } = require("./session-state");
const { watchThreadRollout } = require("./rollout-watch");
const { readBridgeConfig } = require("./codex-desktop-refresher");

module.exports = {
  readBridgeConfig,
  readBridgeDeviceState,
  startBridge,
  resetBridgePairing: resetBridgeTrustState,
  openLastActiveThread,
  watchThreadRollout,
};
