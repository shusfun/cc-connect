// FILE: daemon-state.test.js
// Purpose: Verifies daemon config/runtime persistence helpers for the macOS launchd bridge flow.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/daemon-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  clearBridgeStatus,
  clearPairingSession,
  ensureRemodexLogsDir,
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  resolveBridgeLogsDir,
  resolveBridgeStatusPath,
  resolveBridgeStdoutLogPath,
  resolveDaemonConfigPath,
  resolvePairingSessionPath,
  resolveRemodexStateDir,
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
} = require("../src/daemon-state");

test("daemon-state stores config, pairing payloads, and status under the remodex state dir", () => {
  withTempDaemonEnv(({ rootDir }) => {
    writeDaemonConfig({ relayUrl: "ws://127.0.0.1:9000/relay" });
    writePairingSession({ sessionId: "session-1" }, {
      now: () => 1_710_000_000_000,
    });
    writeBridgeStatus({ state: "running", connectionStatus: "connected" }, {
      now: () => 1_710_000_100_000,
    });

    assert.equal(resolveRemodexStateDir(), rootDir);
    assert.deepEqual(readDaemonConfig(), { relayUrl: "ws://127.0.0.1:9000/relay" });
    assert.equal(readPairingSession()?.pairingPayload?.sessionId, "session-1");
    assert.equal(readBridgeStatus()?.connectionStatus, "connected");
    assert.equal(fs.existsSync(resolveDaemonConfigPath()), true);
    assert.equal(fs.existsSync(resolvePairingSessionPath()), true);
    assert.equal(fs.existsSync(resolveBridgeStatusPath()), true);
  });
});

test("pairing state publication is atomic and preserves the old state on rename failure", () => {
  withTempDaemonEnv(() => {
    writePairingSession({ pairingPayload: { invitation: 'old' }, qrText: 'old' });
    const fsImpl = { ...fs, renameSync() { throw new Error('disk_write_failed'); } };
    assert.throws(() => writePairingSession({ pairingPayload: { invitation: 'new' }, qrText: 'new' }, { fsImpl }), /disk_write_failed/);
    assert.equal(readPairingSession().qrText, 'old');
    assert.equal(fs.readdirSync(resolveRemodexStateDir()).some(name => name.endsWith('.tmp')), false);
  });
});

test("daemon-state clears stale runtime files without touching the config", () => {
  withTempDaemonEnv(() => {
    writeDaemonConfig({ relayUrl: "ws://127.0.0.1:9000/relay" });
    writePairingSession({ sessionId: "session-2" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected" });

    clearPairingSession({});
    clearBridgeStatus({});

    assert.deepEqual(readDaemonConfig(), { relayUrl: "ws://127.0.0.1:9000/relay" });
    assert.equal(readPairingSession(), null);
    assert.equal(readBridgeStatus(), null);
  });
});

test("daemon-state creates the logs directory and derived log paths inside the state root", () => {
  withTempDaemonEnv(({ rootDir }) => {
    ensureRemodexLogsDir({});

    assert.equal(resolveBridgeLogsDir(), path.join(rootDir, "logs"));
    assert.equal(resolveBridgeStdoutLogPath(), path.join(rootDir, "logs", "bridge.stdout.log"));
    assert.equal(fs.existsSync(resolveBridgeLogsDir()), true);
  });
});

function withTempDaemonEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-daemon-state-"));
  process.env.REMODEX_DEVICE_STATE_DIR = rootDir;

  try {
    return run({ rootDir });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    fs.rmSync(rootDir, { recursive: true, force: true });
  }
}
