const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes, randomUUID } = require('node:crypto');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { ControlStore } = require('./control-store');
const { createControlHTTP } = require('./control-http');

async function fixture(t) {
  let now = Date.now();
  const store = new ControlStore({ filename: ':memory:', masterKey: randomBytes(32), now: () => now });
  const owner = await store.setup({ login: 'owner', password: 'Abcdef', origin: 'https://example.test', githubClientId: 'test', githubClientSecret: 'fixture-secret' });
  store.githubUser({ id: 1, login: 'owner' }, owner.id);
  const other = store.githubUser({ id: 2, login: 'other' }); store.review(owner, other.id, 'enabled', null);
  t.after(() => store.close());
  return { store, owner, other: store.user(other.id), advance: ms => { now += ms; } };
}
test('activation states preserve terminal ownership after expiry without enabling replay', async t => {
  const { store, owner, other, advance } = await fixture(t);
  const pending = store.startActivation({ publicKey: randomBytes(32).toString('base64'), platform: 'macos', systemName: 'test device' });
  assert.equal(pending.expiresAt - pending.serverTime, 300000);
  assert.equal(store.activationStatus(owner, pending.id).status, 'pending');
  store.approveActivation(owner, pending.id);
  assert.throws(() => store.activationStatus(other, pending.id), { code: 'device_forbidden' });
  assert.throws(() => store.approveActivation(owner, pending.id), { code: 'request_consumed' });
  store.redeemActivation(pending.id, pending.token, store.activationStatus(owner, pending.id).publicKey);
  advance(300001);
  assert.equal(store.activationStatus(owner, pending.id).status, 'redeemed');
  assert.throws(() => store.redeemActivation(pending.id, pending.token, ''), { code: 'request_expired' });
  assert.throws(() => store.activationStatus(other, pending.id), { code: 'device_forbidden' });
  store.revokeDevice(store.activationStatus(owner, pending.id).deviceId);
  assert.equal(store.activationStatus(owner, pending.id).status, 'revoked');
  const expired = store.startActivation({ publicKey: randomBytes(32).toString('base64'), platform: 'windows', systemName: 'other test device' });
  advance(300001); assert.equal(store.activationStatus(owner, expired.id).status, 'expired');
  assert.throws(() => store.approveActivation(owner, expired.id), { code: 'request_expired' });
});
test('HTTP traces expose stable errors without secrets, URLs or invitation identifiers', async t => {
  const { store, owner } = await fixture(t), logs = [];
  const control = createControlHTTP({ store, setupToken: randomBytes(32).toString('hex'), logger: row => logs.push(row) });
  const server = http.createServer((req, res) => void control.route(req, res));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  // 后注册的清理先执行，保证 finish 回调不会访问已关闭数据库。
  t.after(() => new Promise(resolve => server.close(resolve)));
  const session = store.session(owner.id), pending = store.startActivation({ publicKey: randomBytes(32).toString('base64'), platform: 'macos', systemName: 'private-system-name' });
  const operationId = randomUUID();
  const response = await fetch(`http://127.0.0.1:${server.address().port}/v1/control/activation/approve`, {
    method: 'POST', headers: { origin: 'https://example.test', cookie: `__Host-remodex=${session.token}`, 'content-type': 'application/json', 'x-csrf-token': 'wrong', 'x-remodex-operation-id': operationId }, body: JSON.stringify({ id: pending.id, password: 'must-not-log' })
  });
  assert.equal(response.status, 403); assert.equal((await response.json()).code, 'csrf_failed');
  const requestId = response.headers.get('x-remodex-request-id'); assert.match(requestId, /^[a-f0-9-]{36}$/);
  const row = logs.find(row => row.requestId === requestId);
  assert.equal(row.operationId, operationId); assert.equal(row.route, 'activation/approve'); assert.equal(row.code, 'csrf_failed');
  const audit = store.db.prepare("SELECT diagnostic FROM audit WHERE action='control.request_rejected'").get();
  assert.equal(JSON.parse(audit.diagnostic).requestId, requestId);
  const text = JSON.stringify(logs) + audit.diagnostic;
  for (const forbidden of [session.token, pending.id, pending.token, 'must-not-log', 'private-system-name', '127.0.0.1']) assert.equal(text.includes(forbidden), false);
});
test('schema 2 migration preserves old audit and sessions, and refuses newer schemas', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'remodex-schema3-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'control.sqlite'), key = randomBytes(32);
  const original = new ControlStore({ filename, masterKey: key });
  const admin = await original.setup({ login: 'owner', password: 'Abcdef', origin: 'https://example.test', githubClientId: 'test', githubClientSecret: 'fixture-secret' });
  const session = original.session(admin.id); original.close();
  const db = new DatabaseSync(filename); db.exec('ALTER TABLE audit DROP COLUMN diagnostic; PRAGMA user_version=2'); db.close();
  const migrated = new ControlStore({ filename, masterKey: key });
  assert.equal(migrated.db.prepare('PRAGMA user_version').get().user_version, 3);
  assert.equal(migrated.browser(session.token).user.id, admin.id);
  assert.equal(migrated.db.prepare("SELECT diagnostic FROM audit WHERE action='setup.created'").get().diagnostic, null);
  migrated.db.exec('PRAGMA user_version=4'); migrated.close();
  assert.throws(() => new ControlStore({ filename, masterKey: key }), /database_update_required/);
});
