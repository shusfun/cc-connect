const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes, randomUUID, generateKeyPairSync, createHmac } = require('node:crypto');
const http = require('node:http');
const { ControlStore } = require('./control-store');
const { createControlHTTP } = require('./control-http');
const { TransportControl } = require('./transport-control');
const { createTransportHTTP } = require('./transport-http');
const { signedHeaders } = require('@remodex/protocol');

function identity() {
  const key = generateKeyPairSync('ed25519');
  return { privateKey: key.privateKey, publicKey: key.publicKey.export({ format: 'jwk' }).x.replace(/-/g, '+').replace(/_/g, '/') + '=' };
}

async function fixture(context) {
  let now = Date.now();
  let maintenance = false;
  const store = new ControlStore({ filename: ':memory:', masterKey: randomBytes(32), now: () => now });
  const owner = await store.setup({ login: 'owner', password: 'Abcdef', origin: 'https://example.test', githubClientId: 'test', githubClientSecret: 'fixture-secret' });
  store.githubUser({ id: 1, login: 'owner' }, owner.id);
  const hostKey = identity();
  const pending = store.startActivation({ publicKey: hostKey.publicKey, platform: 'macos', systemName: 'fixture' });
  store.approveActivation(owner, pending.id);
  const host = store.redeemActivation(pending.id, pending.token, hostKey.publicKey);
  const phoneKey = identity();
  const invitation = store.invite(host.device.id);
  const claim = store.claimInvitation(invitation.invitation, phoneKey.publicKey);
  store.approvePairing(host.device.id, claim.id, false);
  const phone = store.redeemPairing(claim.id, claim.token, phoneKey.publicKey);
  const turn = { urls: ['turn:example.test:3478', 'turns:example.test:5349?transport=tcp'], secret: randomBytes(32) };
  const transport = new TransportControl({ store, turn, now: () => now, maintenance: () => maintenance });
  context.after(() => { transport.close(); store.close(); });
  const hostAccess = store.authorize(host.token);
  const phoneAccess = store.authorize(phone.token);
  const hostEvents = [], phoneEvents = [];
  transport.presence(hostAccess, { protocolVersion: 1, generation: randomUUID() });
  const attachHost = () => transport.attach(hostAccess, host.token, (event, value) => hostEvents.push({ event, value }), () => {});
  const attachPhone = () => transport.attach(phoneAccess, phone.token, (event, value) => phoneEvents.push({ event, value }), () => {});
  return { store, owner, host, phone, hostKey, phoneKey, hostAccess, phoneAccess, transport, turn, hostEvents, phoneEvents, attachHost, attachPhone,
    advance: milliseconds => { now += milliseconds; }, maintenance: value => { maintenance = value; }, now: () => now };
}

test('transport binds a connection to authenticated devices and issues bounded TURN and lease credentials', async context => {
  const state = await fixture(context);
  state.attachHost(); state.attachPhone();
  const request = { requestId: randomUUID(), protocolVersion: 1 };
  const result = state.transport.connect(state.phoneAccess, request);
  assert.equal(state.transport.connect(state.phoneAccess, request).connectionId, result.connectionId);
  assert.equal(state.hostEvents.at(-1).event, 'lease');
  const lease = state.hostEvents.at(-1).value;
  assert.equal(lease.expiresAt - state.now(), 60_000);
  const ice = result.iceServers[0];
  assert.equal(ice.credential, createHmac('sha1', state.turn.secret).update(ice.username).digest('base64'));
  const signal = { connectionId: result.connectionId, generation: result.generation, sequence: 1, kind: 'offer', payload: { sdp: 'fixture-offer' } };
  assert.deepEqual(state.transport.signal(state.phoneAccess, signal), { accepted: true });
  assert.equal(state.hostEvents.at(-1).value.payload.sdp, 'fixture-offer');
  assert.equal(state.transport.signal(state.phoneAccess, signal).duplicate, true);
  assert.throws(() => state.transport.signal(state.phoneAccess, { ...signal, payload: { sdp: 'changed' } }), { code: 'signal_conflict' });
  assert.throws(() => state.transport.signal({ ...state.phoneAccess, phone_id: randomUUID() }, signal), { code: 'connection_forbidden' });
  assert.throws(() => state.transport.signal(state.phoneAccess, { ...signal, generation: randomUUID() }), { code: 'generation_mismatch' });
});

test('negotiation is cancelled after its deadline and old stream cleanup cannot remove its replacement', async context => {
  const state = await fixture(context);
  const detachOldHost = state.attachHost(); state.attachPhone();
  const result = state.transport.connect(state.phoneAccess, { requestId: randomUUID(), protocolVersion: 1 });
  state.advance(30_001); state.transport.tick();
  assert.equal(state.transport.connections.has(result.connectionId), false);
  state.attachHost(); detachOldHost();
  assert.equal(state.transport.streams.has(`host:${state.hostAccess.device_id}`), true);
});

test('maintenance and lost control streams never renew direct-connection authorization', async context => {
  const state = await fixture(context);
  state.attachHost(); const detachPhone = state.attachPhone();
  const result = state.transport.connect(state.phoneAccess, { requestId: randomUUID(), protocolVersion: 1 });
  state.transport.signal(state.phoneAccess, { connectionId: result.connectionId, generation: result.generation, sequence: 1, kind: 'offer', payload: { sdp: 'offer' } });
  state.transport.signal(state.hostAccess, { connectionId: result.connectionId, generation: result.generation, sequence: 1, kind: 'answer', payload: { sdp: 'answer' } });
  for (const access of [state.hostAccess, state.phoneAccess]) state.transport.signal(access, { connectionId: result.connectionId, generation: result.generation, sequence: 2, kind: 'connected' });
  const before = state.phoneEvents.filter(row => row.event === 'lease').length;
  state.maintenance(true); state.advance(20_000); state.transport.tick();
  assert.equal(state.phoneEvents.filter(row => row.event === 'lease').length, before);
  state.maintenance(false); detachPhone(); state.advance(20_000); state.transport.tick();
  assert.equal(state.transport.connections.get(result.connectionId).expiresAt, result.serverTime + 60_000);
  state.advance(20_001); state.transport.tick();
  assert.equal(state.transport.connections.size, 0);
});

test('revocation immediately closes both peer authorization and the revoked event stream', async context => {
  const state = await fixture(context);
  state.attachHost(); state.attachPhone();
  state.transport.connect(state.phoneAccess, { requestId: randomUUID(), protocolVersion: 1 });
  state.store.revokeCredential(state.phone.revocationToken);
  state.transport.changed();
  assert.equal(state.transport.connections.size, 0);
  assert.equal(state.transport.streams.has(`phone:${state.phoneAccess.phone_id}`), false);
  assert.equal(state.hostEvents.some(row => row.event === 'connection.closed' && row.value.code === 'access_revoked'), true);
});

test('a host generation replacement rejects all previous negotiation messages and Windows is explicit', async context => {
  const state = await fixture(context);
  state.attachHost(); state.attachPhone();
  const result = state.transport.connect(state.phoneAccess, { requestId: randomUUID(), protocolVersion: 1 });
  state.transport.presence(state.hostAccess, { generation: randomUUID(), protocolVersion: 1 });
  assert.equal(state.transport.connections.size, 0);
  assert.throws(() => state.transport.signal(state.phoneAccess, { connectionId: result.connectionId }), { code: 'connection_forbidden' });
  assert.throws(() => state.transport.presence({ ...state.hostAccess, device: { ...state.hostAccess.device, platform: 'windows' } }, { generation: randomUUID(), protocolVersion: 1 }), { code: 'platform_not_supported' });
});

test('actual HTTP SSE requires a fresh device signature and delivers scoped snapshots without polling', { timeout: 5000 }, async context => {
  const state = await fixture(context);
  const control = createControlHTTP({ store: state.store, setupToken: randomBytes(32).toString('hex') });
  const route = createTransportHTTP({ transport: state.transport, deviceAuth: control.deviceAuth });
  const server = http.createServer((request, response) => { void route(request, response); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const abort = new AbortController();
  context.after(async () => { abort.abort(); state.transport.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const headers = signedHeaders({ method: 'GET', path: '/v1/access/events', token: state.host.token, ...state.hostKey, now: state.now() });
  const response = await fetch(`${origin}/v1/access/events`, { headers, signal: abort.signal });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/event-stream/);
  const reader = response.body.getReader();
  let first = '';
  for (let count = 0; count < 8 && !/event:\s*snapshot/.test(first); count++) {
    const chunk = await reader.read();
    assert.equal(chunk.done, false);
    first += new TextDecoder().decode(chunk.value);
  }
  assert.match(first, /event:\s*snapshot/);
  assert.equal(first.includes(state.host.token), false);
  assert.equal((await fetch(`${origin}/v1/access/events`, { headers })).status, 409);
  assert.equal((await fetch(`${origin}/v1/access/events`)).status, 401);
  abort.abort();
});

test('invalid TURN configuration and failed snapshot writers cannot advertise a live host', async context => {
  const state = await fixture(context);
  const original = state.transport.turn;
  for (const turn of [{ secret: '', urls: original.urls }, { secret: original.secret, urls: ['https://wrong.example'] },
    { secret: original.secret, urls: ['turns:example.test:5349?transport=udp'] }]) {
    state.transport.turn = turn;
    assert.throws(() => state.transport.requireAvailable(), { code: 'turn_unavailable' });
  }
  state.transport.turn = original;
  assert.throws(() => state.transport.attach(state.hostAccess, state.host.token, () => { throw new Error('full'); }, () => {}), { code: 'slow_consumer' });
  assert.equal(state.transport.streams.size, 0);
});

test('negotiation cannot become connected before an offer and answer, or accept a second offer', async context => {
  const state = await fixture(context);
  state.attachHost(); state.attachPhone();
  const result = state.transport.connect(state.phoneAccess, { requestId: randomUUID(), protocolVersion: 1 });
  const base = { connectionId: result.connectionId, generation: result.generation, sequence: 1 };
  assert.throws(() => state.transport.signal(state.hostAccess, { ...base, kind: 'connected' }), { code: 'signal_state' });
  assert.throws(() => state.transport.signal(state.hostAccess, { ...base, kind: 'answer', payload: { sdp: 'answer' } }), { code: 'signal_state' });
  state.transport.signal(state.phoneAccess, { ...base, kind: 'offer', payload: { sdp: 'offer' } });
  assert.throws(() => state.transport.signal(state.phoneAccess, { ...base, sequence: 2, kind: 'offer', payload: { sdp: 'other' } }), { code: 'signal_state' });
  assert.throws(() => state.transport.signal(state.phoneAccess, { ...base, sequence: 2, kind: 'candidate', payload: { candidate: 'candidate', sdpMLineIndex: -1 } }), { code: 'invalid_signal' });
});
