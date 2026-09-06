const { setTimeout: delay } = require('node:timers/promises');

const terminalCodes = new Set(['activation_required', 'credential_invalid', 'credential_revoked', 'device_revoked', 'pairing_revoked', 'access_revoked', 'invalid_device_proof', 'update_required', 'platform_not_supported', 'relay_response_invalid']);

function startupFailure(error) {
  const code = typeof error?.code === 'string' && /^[a-z][a-z0-9_]{0,79}$/.test(error.code) ? error.code : 'relay_network_failed';
  return { code, terminal: terminalCodes.has(code) || [400, 401, 403, 404, 410, 426].includes(error?.status) };
}

async function recoverStartup(operation, { signal, onRetry = () => {}, sleep = milliseconds => delay(milliseconds, undefined, { signal }), random = Math.random } = {}) {
  let attempt = 0;
  while (!signal?.aborted) {
    try { return await operation(); }
    catch (error) {
      if (signal?.aborted) throw signal.reason;
      const failure = startupFailure(error);
      if (failure.terminal) throw error;
      const base = Math.min(30_000, 1000 * 2 ** Math.min(attempt++, 5));
      const retryAfter = Number.isFinite(error?.retryAfter) ? Math.max(0, error.retryAfter) : 0;
      const wait = Math.max(retryAfter, Math.min(30_000, base * (1 + Math.min(1, Math.max(0, random())) * 0.2)));
      onRetry({ code: failure.code, retryAfterMs: wait });
      let remaining = wait;
      while (remaining > 0) {
        if (signal?.aborted) throw signal.reason;
        const interval = Math.min(remaining, 300_000);
        await sleep(interval);
        remaining -= interval;
      }
    }
  }
  throw signal.reason;
}

module.exports = { recoverStartup, startupFailure };
