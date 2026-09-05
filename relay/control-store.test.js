const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes, generateKeyPairSync } = require('node:crypto');
const { ControlStore, digest } = require('./control-store');
const { signedHeaders } = require('@remodex/protocol');
const { createProductionAccess } = require('./production-access');
const { createRelayServer } = require('./server');
const WebSocket = require('ws');

function identity() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return { privateKey, publicKey: publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64') };
}
async function fixture(t) {
  let now = Date.now();
  const store = new ControlStore({ filename: ':memory:', masterKey: randomBytes(32), now: () => now });
  t.after(() => store.close());
  const admin = await store.setup({ login: 'owner', password: 'long-local-password-123', githubClientId: 'client', githubClientSecret: 'private-secret', origin: 'https://relay.example.test' });
  store.githubUser({ id: 1, login: 'owner' }, admin.id);
  function account(id = 2) { return store.githubUser({ id, login: `user-${id}` }); }
  function enabled(id = 2) { const user = account(id); store.review(admin, user.id, 'enabled', null); return store.user(user.id); }
  function activated(user = enabled(), keys = identity()) {
    const request = store.startActivation({ publicKey: keys.publicKey, platform: 'windows', systemName: '公司电脑' });
    const device = store.approveActivation(user, request.id);
    const access = store.redeemActivation(request.id, request.token, keys.publicKey);
    return { ...access, keys, user, device, request };
  }
  function paired(host, keys = identity()) {
    const invitation = store.invite(host.deviceId);
    const request = store.claimInvitation(invitation.invitation, keys.publicKey);
    store.approvePairing(host.deviceId, request.id, true);
    return { ...store.redeemPairing(request.id, request.token, keys.publicKey), keys, request, invitation };
  }
  return { store, admin, account, enabled, activated, paired, advance: milliseconds => { now += milliseconds; } };
}
const rejectsCode = (action, code) => assert.throws(action, error => error.code === code);

test('setup has one owner; secret is encrypted and administrator binding is explicit', async t => {
  const { store } = await fixture(t);
  assert.notEqual(store.get('githubClientSecret'), 'private-secret');
  assert.equal(store.unseal(store.get('githubClientSecret')), 'private-secret');
  await assert.rejects(store.setup({}), error => error.code === 'setup_closed');
  const next = store.githubUser({ id: 10, login: 'intruder' });
  assert.equal(next.role, 'user'); assert.equal(next.status, 'pending');
});
test('pending user cannot activate; GitHub rename preserves identity', async t => {
  const { store, account } = await fixture(t); const user = account();
  const request = store.startActivation({ ...identity(), platform: 'macos', systemName: 'Mac' });
  rejectsCode(() => store.approveActivation(user, request.id), 'account_not_enabled');
  assert.equal(store.githubUser({ id: 2, login: 'renamed' }).id, user.id);
});
test('password login verifies password and logout deletes the server session', async t => {
  const { store, admin } = await fixture(t);
  await assert.rejects(store.passwordLogin('owner', 'wrong'), error => error.code === 'login_failed');
  assert.equal((await store.passwordLogin('owner', 'long-local-password-123')).id, admin.id);
  const session = store.session(admin.id); assert.equal(store.browser(session.token).user.id, admin.id);
  store.db.prepare('DELETE FROM browser_sessions WHERE hash=?').run(digest(session.token));
  rejectsCode(() => store.browser(session.token), 'login_required');
});
test('activation is single use, expires, and cannot be moved to another account', async t => {
  const { store, activated, enabled, advance } = await fixture(t); const host = activated();
  rejectsCode(() => store.redeemActivation(host.request.id, host.request.token, host.keys.publicKey), 'request_consumed');
  const request = store.startActivation({ publicKey: host.keys.publicKey, platform: 'macos', systemName: 'Other' });
  rejectsCode(() => store.approveActivation(enabled(3), request.id), 'device_owned_by_other_account');
  advance(300001); rejectsCode(() => store.request(request.id, 'activation'), 'request_expired');
});
test('remark revisions prevent lost updates and cross-account edits', async t => {
  const { store, activated, enabled } = await fixture(t); const host = activated();
  const device = store.remark(host.user, host.deviceId, '家里的 Windows', 1);
  assert.equal(device.revision, 2); assert.equal(device.public_key, host.keys.publicKey);
  rejectsCode(() => store.remark(host.user, host.deviceId, 'stale', 1), 'revision_conflict');
  rejectsCode(() => store.remark(enabled(3), host.deviceId, 'other', 2), 'device_forbidden');
});
test('device quota applies across pending activations without limiting phone switching', async t => {
  const { store, admin, enabled, activated } = await fixture(t); const user = enabled();
  store.review(admin, user.id, 'enabled', 1); const limited = store.user(user.id); activated(limited);
  assert.throws(() => activated(limited), error => error.code === 'device_limit_reached');
});
test('invitation is single use, requires host approval and stays within an account', async t => {
  const { store, activated, paired, enabled } = await fixture(t); const host = activated(); const phone = paired(host);
  rejectsCode(() => store.claimInvitation(phone.invitation.invitation, phone.keys.publicKey), 'invitation_expired');
  const invitation = store.invite(host.deviceId); const other = identity(); const pending = store.claimInvitation(invitation.invitation, other.publicKey);
  rejectsCode(() => store.redeemPairing(pending.id, pending.token, other.publicKey), 'approval_pending');
  rejectsCode(() => store.approvePairing(host.deviceId, pending.id, false), 'phone_replacement_required');
  const otherHost = activated(enabled(3)); const otherInvite = store.invite(otherHost.deviceId);
  rejectsCode(() => store.claimInvitation(otherInvite.invitation, phone.keys.publicKey), 'phone_account_conflict');
});
test('one phone can pair with multiple computers; replacement revokes only the replaced grant', async t => {
  const { store, activated, paired } = await fixture(t); const first = activated(); const second = activated(first.user);
  const phone = paired(first); const secondGrant = paired(second, phone.keys);
  assert.equal(phone.phoneId, secondGrant.phoneId);
  paired(first);
  rejectsCode(() => store.authorize(phone.token), 'credential_revoked');
  assert.equal(store.authorize(secondGrant.token).device_id, second.deviceId);
});
test('disable and re-enable cannot resurrect credentials or outstanding approvals', async t => {
  const { store, admin, activated, paired } = await fixture(t); const host = activated(); const phone = paired(host);
  store.review(admin, host.user.id, 'disabled', null); store.review(admin, host.user.id, 'enabled', null);
  rejectsCode(() => store.authorize(host.token), 'credential_revoked'); rejectsCode(() => store.authorize(phone.token), 'credential_revoked');
});
test('revocation-only token cannot login; revoking one computer preserves the other', async t => {
  const { store, activated } = await fixture(t); const host = activated(); const other = activated(host.user);
  rejectsCode(() => store.authorize(host.revocationToken), 'credential_revoked');
  store.revokeCredential(host.revocationToken); store.revokeCredential(host.revocationToken);
  rejectsCode(() => store.authorize(host.token), 'credential_revoked'); assert.equal(store.authorize(other.token).device_id, other.deviceId);
});
test('nonce reuse and expired requests are rejected', async t => {
  const { store, advance } = await fixture(t); const nonce = 'n'.repeat(32); const timestamp = store.now();
  store.useNonce('key', nonce, timestamp); rejectsCode(() => store.useNonce('key', nonce, timestamp), 'request_replayed');
  advance(61000); rejectsCode(() => store.useNonce('key', 'x'.repeat(32), timestamp), 'request_expired');
});
test('failed transaction never publishes a partial account change', async t => {
  const { store, activated } = await fixture(t); const host = activated();
  assert.throws(() => store.transaction(() => { store.revokeDevice(host.deviceId); throw new Error('storage fault'); }));
  assert.equal(store.authorize(host.token).device.status, 'active');
});
test('production websocket rejects bearer-only clients and signed cross-device room access', async t => {
  const f = await fixture(t); const host = f.activated(); const other = f.activated(host.user); const phone = f.paired(other);
  const accessControl = createProductionAccess({ store: f.store, setupToken: 'x'.repeat(43) });
  const { server, wss } = createRelayServer({ accessControl });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { for (const ws of wss.clients) ws.terminate(); accessControl.close(); await new Promise(resolve => server.close(resolve)); wss.close(); });
  const address = `ws://127.0.0.1:${server.address().port}`;
  const rejected = headers => new Promise((resolve, reject) => { const ws = new WebSocket(`${address}/relay/test-session`, { headers }); ws.on('unexpected-response', (_req, response) => { response.resume(); ws.terminate(); resolve(response.statusCode); }); ws.on('error', () => {}); ws.on('open', () => { ws.close(); reject(new Error('unauthorized socket opened')); }); });
  assert.equal(await rejected({ authorization: `Bearer ${host.token}` }), 401);
  const ws = new WebSocket(`${address}/relay/test-session`, { headers: signedHeaders({ method: 'GET', path: '/relay/test-session', token: host.token, ...host.keys }) });
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  assert.equal(await rejected(signedHeaders({ method: 'GET', path: '/relay/test-session', token: phone.token, ...phone.keys })), 401);
  assert.equal(ws.readyState, WebSocket.OPEN);
  const body = '{}'; const headers = signedHeaders({ method: 'POST', path: '/v1/access/device', body, token: host.token, ...host.keys });
  const endpoint = `http://127.0.0.1:${server.address().port}/v1/access/device`;
  assert.equal((await fetch(endpoint, { method: 'POST', headers, body })).status, 200);
  assert.equal((await fetch(endpoint, { method: 'POST', headers, body })).status, 409);
});
