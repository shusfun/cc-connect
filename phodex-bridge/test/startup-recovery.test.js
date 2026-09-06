const test = require('node:test');
const assert = require('node:assert/strict');
const { recoverStartup } = require('../src/startup-recovery');
const { retryAfterMilliseconds } = require('../src/device-access');

test('startup survives maintenance and network errors without restarting a worker', async () => {
  let calls = 0;
  const waits = [], events = [];
  const result = await recoverStartup(async () => {
    calls++;
    if (calls === 1) throw Object.assign(new Error('private response'), { code: 'maintenance', status: 503, retryAfter: 5000 });
    if (calls < 9) throw new Error('private network information');
    return 'ready';
  }, { random: () => 0, sleep: async delay => waits.push(delay), onRetry: value => events.push(value) });
  assert.equal(result, 'ready');
  assert.deepEqual(waits, [5000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  assert.equal(JSON.stringify(events).includes('private'), false);
});

test('revoked credentials and incompatible responses never retry', async () => {
  for (const code of ['credential_revoked', 'platform_not_supported', 'relay_response_invalid']) {
    let calls = 0;
    await assert.rejects(recoverStartup(async () => { calls++; throw Object.assign(new Error(code), { code }); }), { code });
    assert.equal(calls, 1);
  }
});

test('stopping startup cancels a pending backoff rather than launching another request', async () => {
  const controller = new AbortController();
  let calls = 0;
  await assert.rejects(recoverStartup(async () => { calls++; throw new Error('offline'); }, {
    signal: controller.signal,
    onRetry: () => controller.abort(new Error('owner_stopped')),
  }));
  assert.equal(calls, 1);
});

test('Retry-After supports HTTP dates and never retries earlier than a long server delay', async () => {
  const now = Date.parse('2026-09-06T00:00:00Z');
  assert.equal(retryAfterMilliseconds('Sun, 06 Sep 2026 00:00:40 GMT', now), 40_000);
  assert.equal(retryAfterMilliseconds('12', now), 12_000);
  assert.equal(retryAfterMilliseconds('invalid', now), 0);
  let calls = 0;
  const waits = [];
  await recoverStartup(async () => {
    if (calls++ === 0) throw Object.assign(new Error('maintenance'), { retryAfter: 900_000 });
  }, { sleep: async delay => waits.push(delay), random: () => 0 });
  assert.equal(waits.reduce((total, delay) => total + delay, 0), 900_000);
  assert.equal(calls, 2);
});
