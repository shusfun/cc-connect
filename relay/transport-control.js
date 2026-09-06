const { createHmac, randomUUID, createHash } = require('node:crypto');
const { fail } = require('./control-store');

const TRANSPORT_VERSION = 1;
const LEASE_MS = 60_000;
const NEGOTIATION_MS = 30_000;
const MAX_STREAMS = 1000;
const MAX_SIGNAL_BYTES = 65_536;
const identifier = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const streamKey = access => access.kind === 'host' ? `host:${access.device_id}` : `phone:${access.phone_id}`;

class TransportControl {
  constructor({ store, turn, now = () => Date.now(), maintenance = () => false, maximumStreams = MAX_STREAMS }) {
    this.store = store;
    this.turn = turn;
    this.now = now;
    this.maintenance = maintenance;
    this.maximumStreams = maximumStreams;
    this.presences = new Map();
    this.streams = new Map();
    this.connections = new Map();
    this.requests = new Map();
  }

  requireAvailable() {
    if (this.maintenance()) fail(503, 'maintenance');
    const secret = this.turn?.secret;
    if ((!Buffer.isBuffer(secret) && typeof secret !== 'string') || Buffer.byteLength(secret) < 32
      || !Array.isArray(this.turn.urls) || !this.turn.urls.length || this.turn.urls.length > 8
      || this.turn.urls.some(value => typeof value !== 'string' || value.length > 512 || !/^turns?:[^\s/@?#]+:\d{1,5}(?:\?transport=(?:tcp|udp))?$/.test(value)
        || (value.startsWith('turns:') && value.endsWith('transport=udp')))) fail(503, 'turn_unavailable');
  }

  presence(access, body) {
    this.requireAvailable();
    if (access.kind !== 'host') fail(403, 'host_required');
    if (access.device.platform !== 'macos') fail(426, 'platform_not_supported');
    if (body.protocolVersion !== TRANSPORT_VERSION || !identifier(body.generation)) fail(426, 'update_required');
    const previous = this.presences.get(access.device_id);
    if (previous?.generation === body.generation) {
      previous.expiresAt = this.now() + LEASE_MS;
      return this.presenceResult(previous);
    }
    if (!previous && this.presences.size >= this.maximumStreams) fail(503, 'transport_capacity');
    this.disconnectDevice(access.device_id, 'host_replaced');
    const presence = { generation: body.generation, sessionId: randomUUID(), expiresAt: this.now() + LEASE_MS };
    this.presences.set(access.device_id, presence);
    return this.presenceResult(presence);
  }

  presenceResult(presence) {
    return { generation: presence.generation, sessionId: presence.sessionId, protocolVersion: TRANSPORT_VERSION, serverTime: this.now() };
  }

  attach(access, token, send, close) {
    this.requireAvailable();
    if (access.device.platform !== 'macos') fail(426, 'platform_not_supported');
    const key = streamKey(access);
    if (!this.streams.has(key) && this.streams.size >= this.maximumStreams) fail(503, 'transport_capacity');
    if (access.kind === 'host' && !this.presences.has(access.device_id)) fail(409, 'presence_required');
    const previous = this.streams.get(key);
    if (previous) {
      this.removeStream(previous, 'stream_replaced', previous.access.device_id !== access.device_id);
    }
    const stream = { id: randomUUID(), key, access, token, send, close, lastLeaseAt: 0 };
    this.streams.set(key, stream);
    for (const connection of [...this.connections.values()]) {
      if (this.participates(connection, access) && connection.state !== 'connected') this.cancel(connection, 'negotiation_interrupted');
    }
    try {
      if (!this.emit(stream, 'snapshot', this.snapshot(access))) fail(503, 'slow_consumer');
    } catch (error) { this.removeStream(stream, 'snapshot_failed', true); throw error; }
    return () => this.removeStream(stream, 'stream_disconnected', false);
  }

  snapshot(access) {
    const current = this.store.authorize(this.streams.get(streamKey(access))?.token);
    const pendingPhones = current.kind === 'host'
      ? this.store.db.prepare("SELECT id,public_key,expires_at FROM requests WHERE kind='pairing' AND status='pending' AND expires_at>? AND json_extract(payload,'$.deviceId')=? LIMIT 65").all(this.now(), current.device_id)
      : [];
    if (pendingPhones.length > 64) fail(503, 'snapshot_capacity');
    return { device: current.device, pendingPhones, protocolVersion: TRANSPORT_VERSION, serverTime: this.now(), ...this.presences.has(current.device_id) && this.presenceResult(this.presences.get(current.device_id)) };
  }

  resolve(access) {
    this.requireAvailable();
    if (access.kind !== 'phone') fail(403, 'phone_required');
    if (access.device.platform !== 'macos') fail(426, 'platform_not_supported');
    const presence = this.presences.get(access.device_id);
    if (!presence || !this.streams.has(`host:${access.device_id}`)) fail(404, 'device_offline');
    return { ...this.presenceResult(presence), device: access.device, accountId: access.user.id, instanceId: this.store.get('instanceId') };
  }

  connect(access, body) {
    const session = this.resolve(access);
    if (!identifier(body.requestId) || body.protocolVersion !== TRANSPORT_VERSION) fail(400, 'invalid_connect');
    const phone = this.streams.get(streamKey(access));
    if (!phone || phone.access.device_id !== access.device_id) fail(409, 'events_required');
    const requestKey = `${access.phone_id}:${body.requestId}`;
    const previousRequest = this.requests.get(requestKey);
    if (previousRequest) {
      const previous = this.connections.get(previousRequest.id);
      if (!previous || previous.deviceId !== access.device_id) fail(410, 'request_expired');
      return this.connectionResult(previous);
    }
    if (this.requests.size >= this.maximumStreams * 8) fail(429, 'rate_limited');
    for (const connection of [...this.connections.values()]) {
      if (connection.deviceId === access.device_id || connection.phoneId === access.phone_id) this.cancel(connection, 'connection_replaced');
    }
    const connection = {
      id: randomUUID(), sessionId: session.sessionId, hostGeneration: session.generation,
      deviceId: access.device_id, accountId: access.user.id, phoneId: access.phone_id,
      state: 'negotiating', deadline: this.now() + NEGOTIATION_MS, sequence: 0,
      ready: new Set(), descriptions: new Set(), signals: new Map(), expiresAt: this.now() + LEASE_MS,
    };
    this.connections.set(connection.id, connection);
    connection.timer = setTimeout(() => {
      if (this.connections.get(connection.id) === connection && connection.state !== 'connected') this.cancel(connection, 'negotiation_expired');
    }, NEGOTIATION_MS);
    connection.timer.unref?.();
    this.requests.set(requestKey, { id: connection.id, expiresAt: this.now() + 120_000 });
    const result = this.connectionResult(connection);
    if (!this.emit(this.streams.get(`host:${access.device_id}`), 'connect', result)) {
      this.cancel(connection, 'peer_offline');
      fail(409, 'peer_offline');
    }
    this.lease(connection);
    return result;
  }

  connectionResult(connection) {
    const expiresAt = this.now() + 3_600_000;
    const username = `${Math.floor(expiresAt / 1000)}:${connection.id}`;
    const credential = createHmac('sha1', this.turn.secret).update(username).digest('base64');
    return {
      connectionId: connection.id, generation: connection.id, hostGeneration: connection.hostGeneration,
      sessionId: connection.sessionId, protocolVersion: TRANSPORT_VERSION, serverTime: this.now(),
      negotiationExpiresAt: connection.deadline, iceCredentialExpiresAt: expiresAt,
      iceServers: [{ urls: this.turn.urls, username, credential }],
    };
  }

  participates(connection, access) {
    return connection.accountId === access.user.id && connection.deviceId === access.device_id
      && (access.kind === 'host' || connection.phoneId === access.phone_id);
  }

  signal(access, body) {
    this.requireAvailable();
    const connection = this.connections.get(body.connectionId);
    if (!connection || !this.participates(connection, access)) fail(403, 'connection_forbidden');
    if (body.generation !== connection.id || this.presences.get(access.device_id)?.generation !== connection.hostGeneration) fail(409, 'generation_mismatch');
    if (connection.expiresAt <= this.now() || (connection.state !== 'connected' && connection.deadline <= this.now())) {
      this.cancel(connection, 'negotiation_expired');
      fail(410, 'connection_expired');
    }
    const sender = this.streams.get(streamKey(access));
    if (!sender || sender.access.device_id !== access.device_id) fail(409, 'events_required');
    const allowed = access.kind === 'phone' ? ['offer', 'candidate', 'connected', 'cancel'] : ['answer', 'candidate', 'connected', 'cancel'];
    if (!allowed.includes(body.kind) || !Number.isSafeInteger(body.sequence) || body.sequence < 1 || body.sequence > 256) fail(400, 'invalid_signal');
    if (['offer', 'answer'].includes(body.kind) && (typeof body.payload?.sdp !== 'string' || !body.payload.sdp)) fail(400, 'invalid_signal');
    if (body.kind === 'candidate' && (typeof body.payload?.candidate !== 'string' || Buffer.byteLength(body.payload.candidate) > 8192
      || !Number.isInteger(body.payload.sdpMLineIndex) || body.payload.sdpMLineIndex < 0 || body.payload.sdpMLineIndex > 65_535
      || (body.payload.sdpMid != null && (typeof body.payload.sdpMid !== 'string' || Buffer.byteLength(body.payload.sdpMid) > 256)))) fail(400, 'invalid_signal');
    const raw = JSON.stringify({ kind: body.kind, payload: body.payload });
    if (Buffer.byteLength(raw) > MAX_SIGNAL_BYTES) fail(413, 'signal_too_large');
    const key = `${access.kind}:${body.sequence}`;
    const hash = createHash('sha256').update(raw).digest('hex');
    if (connection.signals.has(key)) {
      if (connection.signals.get(key) !== hash) fail(409, 'signal_conflict');
      return { accepted: true, duplicate: true };
    }
    if (['offer', 'answer'].includes(body.kind)) {
      if (connection.descriptions.has(body.kind) || (body.kind === 'answer' && !connection.descriptions.has('offer'))) fail(409, 'signal_state');
      connection.descriptions.add(body.kind);
    }
    if (body.kind === 'connected' && !connection.descriptions.has('answer')) fail(409, 'signal_state');
    connection.signals.set(key, hash);
    if (body.kind === 'cancel') { this.cancel(connection, 'peer_cancelled'); return { accepted: true }; }
    if (body.kind === 'connected') {
      connection.ready.add(access.kind);
      if (connection.ready.size === 2) {
        connection.state = 'connected';
        clearTimeout(connection.timer);
      }
      return { accepted: true };
    }
    const peer = this.streams.get(access.kind === 'host' ? `phone:${connection.phoneId}` : `host:${connection.deviceId}`);
    if (!peer) { this.cancel(connection, 'peer_offline'); fail(409, 'peer_offline'); }
    if (!this.emit(peer, 'signal', { connectionId: connection.id, generation: connection.id, kind: body.kind, sequence: body.sequence, payload: body.payload })) {
      this.cancel(connection, 'peer_offline');
      fail(409, 'peer_offline');
    }
    return { accepted: true };
  }

  emit(stream, event, data) {
    if (!stream || this.streams.get(stream.key) !== stream) return false;
    try { stream.send(event, data); return true; }
    catch { this.removeStream(stream, 'stream_failed', false); return false; }
  }

  lease(connection) {
    if (this.maintenance()) return;
    const host = this.streams.get(`host:${connection.deviceId}`);
    const phone = this.streams.get(`phone:${connection.phoneId}`);
    if (!host || !phone || phone.access.device_id !== connection.deviceId) return;
    try { this.store.authorize(host.token); this.store.authorize(phone.token); }
    catch { this.cancel(connection, 'access_revoked'); return; }
    connection.sequence += 1;
    connection.expiresAt = this.now() + LEASE_MS;
    const lease = { generation: connection.id, sequence: connection.sequence, issuedAt: this.now(), expiresAt: connection.expiresAt };
    this.emit(host, 'lease', lease);
    this.emit(phone, 'lease', lease);
  }

  tick() {
    for (const stream of [...this.streams.values()]) {
      try { this.store.authorize(stream.token); }
      catch { this.removeStream(stream, 'access_revoked', true); continue; }
      if (this.maintenance()) this.emit(stream, 'maintenance', { code: 'maintenance' });
    }
    for (const connection of [...this.connections.values()]) {
      if (connection.expiresAt <= this.now() || (connection.state !== 'connected' && connection.deadline <= this.now())) this.cancel(connection, 'connection_expired');
      else this.lease(connection);
    }
    for (const [key, request] of this.requests) if (request.expiresAt <= this.now()) this.requests.delete(key);
    for (const [key, presence] of this.presences) {
      if (this.streams.has(`host:${key}`)) presence.expiresAt = this.now() + LEASE_MS;
      else if (presence.expiresAt <= this.now()) this.presences.delete(key);
    }
  }

  changed() {
    for (const stream of [...this.streams.values()]) {
      try { this.emit(stream, 'snapshot', this.snapshot(stream.access)); }
      catch { this.removeStream(stream, 'access_revoked', true); }
    }
  }

  cancel(connection, code) {
    if (!this.connections.delete(connection.id)) return;
    clearTimeout(connection.timer);
    for (const key of [`host:${connection.deviceId}`, `phone:${connection.phoneId}`]) {
      this.emit(this.streams.get(key), 'connection.closed', { connectionId: connection.id, generation: connection.id, code });
    }
    connection.signals.clear();
  }

  removeStream(stream, code, cancelConnections) {
    if (this.streams.get(stream.key) !== stream) return;
    if (cancelConnections) for (const connection of [...this.connections.values()]) {
      if (this.participates(connection, stream.access)) this.cancel(connection, code);
    }
    this.streams.delete(stream.key);
    try { stream.close(code); } catch { }
  }

  disconnectDevice(deviceId, code) {
    for (const connection of [...this.connections.values()]) if (connection.deviceId === deviceId) this.cancel(connection, code);
    const stream = this.streams.get(`host:${deviceId}`);
    if (stream) this.removeStream(stream, code, true);
  }

  close() {
    for (const connection of [...this.connections.values()]) this.cancel(connection, 'server_shutdown');
    for (const stream of [...this.streams.values()]) this.removeStream(stream, 'server_shutdown', false);
    this.presences.clear();
    this.requests.clear();
  }
}

module.exports = { TransportControl, TRANSPORT_VERSION, LEASE_MS, NEGOTIATION_MS, MAX_SIGNAL_BYTES };
