const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { once } = require('node:events');
const { ControlStore } = require('../control-store');
const { createControlHTTP } = require('../control-http');
const { TransportControl } = require('../transport-control');
const { createTransportHTTP } = require('../transport-http');
const { createBridgeSecureTransport, SECURE_PROTOCOL_VERSION, nonceForDirection } = require('../../phodex-bridge/src/secure-transport');
const { createSyncCoordinator } = require('../../phodex-bridge/src/sync-journal');

function identity(type = 'ed25519') {
  const pair = crypto.generateKeyPairSync(type);
  return { ...pair, privateRaw: Buffer.from(pair.privateKey.export({ format: 'jwk' }).d, 'base64url').toString('base64'),
    publicRaw: Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64') };
}

function prefixed(value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value));
  const length = Buffer.alloc(4);
  length.writeUInt32BE(bytes.length);
  return Buffer.concat([length, bytes]);
}

function phoneProtocol({ hostKey, phoneKey, deviceId, phoneId, sessionId, send, completed }) {
  const ephemeral = identity('x25519');
  const nonce = crypto.randomBytes(32);
  let serverHello, phoneToMac, macToPhone;
  return {
    start() {
      send({ kind: 'clientHello', protocolVersion: SECURE_PROTOCOL_VERSION, sessionId, handshakeMode: 'trusted_reconnect',
        phoneDeviceId: phoneId, phoneIdentityPublicKey: phoneKey.publicRaw, phoneEphemeralPublicKey: ephemeral.publicRaw, clientNonce: nonce.toString('base64') });
    },
    receive(wire) {
      const message = JSON.parse(wire);
      if (message.kind === 'serverHello') {
        serverHello = message;
        assert.equal(message.macDeviceId, deviceId);
        assert.equal(message.macIdentityPublicKey, hostKey.publicRaw);
        assert.equal(message.sessionId, sessionId);
        const transcript = Buffer.concat(['remodex-e2ee-v1', sessionId, SECURE_PROTOCOL_VERSION, 'trusted_reconnect', message.keyEpoch, deviceId, phoneId,
          Buffer.from(hostKey.publicRaw, 'base64'), Buffer.from(phoneKey.publicRaw, 'base64'), Buffer.from(message.macEphemeralPublicKey, 'base64'),
          Buffer.from(ephemeral.publicRaw, 'base64'), nonce, Buffer.from(message.serverNonce, 'base64'), 0].map(prefixed));
        assert.equal(crypto.verify(null, transcript, hostKey.publicKey, Buffer.from(message.macSignature, 'base64')), true);
        const secret = crypto.diffieHellman({ privateKey: ephemeral.privateKey,
          publicKey: crypto.createPublicKey({ format: 'jwk', key: { kty: 'OKP', crv: 'X25519', x: Buffer.from(message.macEphemeralPublicKey, 'base64').toString('base64url') } }) });
        const salt = crypto.createHash('sha256').update(transcript).digest();
        const prefix = `remodex-e2ee-v1|${sessionId}|${deviceId}|${phoneId}|${message.keyEpoch}`;
        phoneToMac = crypto.hkdfSync('sha256', secret, salt, `${prefix}|phoneToMac`, 32);
        macToPhone = crypto.hkdfSync('sha256', secret, salt, `${prefix}|macToPhone`, 32);
        send({ kind: 'clientAuth', sessionId, phoneDeviceId: phoneId, keyEpoch: message.keyEpoch,
          phoneSignature: crypto.sign(null, Buffer.concat([transcript, prefixed('client-auth')]), phoneKey.privateKey).toString('base64') });
      } else if (message.kind === 'secureReady') {
        send({ kind: 'resumeState', sessionId, keyEpoch: serverHello.keyEpoch, lastAppliedBridgeOutboundSeq: 0, bridgeReplayEpoch: serverHello.bridgeReplayEpoch });
        const cipher = crypto.createCipheriv('aes-256-gcm', phoneToMac, nonceForDirection('iphone', 0));
        const ciphertext = Buffer.concat([cipher.update(JSON.stringify({ payloadText: JSON.stringify({ id: 'probe', method: 'sync/hello', params: {} }) })), cipher.final()]);
        send({ kind: 'encryptedEnvelope', v: SECURE_PROTOCOL_VERSION, sessionId, keyEpoch: serverHello.keyEpoch, sender: 'iphone', counter: 0,
          ciphertext: ciphertext.toString('base64'), tag: cipher.getAuthTag().toString('base64') });
      } else if (message.kind === 'encryptedEnvelope') {
        assert.equal(message.sender, 'mac');
        const decipher = crypto.createDecipheriv('aes-256-gcm', macToPhone, nonceForDirection(message.sender, message.counter));
        decipher.setAuthTag(Buffer.from(message.tag, 'base64'));
        const payload = JSON.parse(Buffer.concat([decipher.update(Buffer.from(message.ciphertext, 'base64')), decipher.final()]));
        const response = JSON.parse(payload.payloadText);
        assert.equal(response.id, 'probe');
        assert.equal(response.result.protocolVersion, 1);
        assert.equal(response.result.macDeviceId, deviceId);
        completed();
      } else { throw new Error('unexpected_secure_message'); }
    },
  };
}

async function main() {
  const executable = process.argv[2];
  if (!executable) throw new Error('native_probe_executable_required');
  const mode = process.argv[3] || 'direct';
  assert.ok(['direct', 'turn-udp', 'turn-tcp', 'turn-tls'].includes(mode));
  const relayOnly = mode !== 'direct';
  const urls = relayOnly ? JSON.parse(process.env.REMODEX_TEST_TURN_URLS || '[]') : ['turn:127.0.0.1:9?transport=udp'];
  if (relayOnly) {
    assert.equal(urls.length, 1, '每次只验证一种 TURN 承载');
    assert.match(urls[0], mode === 'turn-tls' ? /^turns:.+\?transport=tcp$/ : new RegExp(`^turn:.+\\?transport=${mode === 'turn-udp' ? 'udp' : 'tcp'}$`));
    assert.ok(process.env.REMODEX_TEST_TURN_SECRET?.length >= 32, '需要隔离测试 TURN 的短期凭据签发密钥');
  }
  const store = new ControlStore({ filename: ':memory:', masterKey: crypto.randomBytes(32) });
  const owner = await store.setup({ login: 'owner', password: 'Abcdef', origin: 'https://example.test', githubClientId: 'test', githubClientSecret: 'test-only-secret' });
  store.githubUser({ id: 1, login: 'owner' }, owner.id);
  const hostKey = identity(), phoneKey = identity();
  const activation = store.startActivation({ publicKey: hostKey.publicRaw, platform: 'macos', systemName: 'capability' });
  store.approveActivation(owner, activation.id);
  const host = store.redeemActivation(activation.id, activation.token, hostKey.publicRaw);
  const invitation = store.invite(host.device.id);
  const pairing = store.claimInvitation(invitation.invitation, phoneKey.publicRaw);
  store.approvePairing(host.device.id, pairing.id, false);
  const phone = store.redeemPairing(pairing.id, pairing.token, phoneKey.publicRaw);
  const phoneId = store.authorize(phone.token).phone_id;
  const transport = new TransportControl({ store, turn: { urls, secret: relayOnly ? process.env.REMODEX_TEST_TURN_SECRET : crypto.randomBytes(32) } });
  const control = createControlHTTP({ store, setupToken: crypto.randomBytes(32).toString('hex') });
  const route = createTransportHTTP({ transport, deviceAuth: control.deviceAuth });
  const server = http.createServer((request, response) => { void route(request, response); });
  const ticker = setInterval(() => transport.tick(), 20_000);
  let child;
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const exited = once(child, 'exit');
    child.stderr.resume();
    child.stdin.on('error', () => {});
    child.stdin.write(JSON.stringify({ origin: `http://127.0.0.1:${server.address().port}`, relayOnly,
      host: { token: host.token, privateKey: hostKey.privateRaw }, phone: { token: phone.token, privateKey: phoneKey.privateRaw } }) + '\n');
    await new Promise((resolve, reject) => {
      const deadline = setTimeout(() => reject(new Error('native_capability_timeout')), 90_000);
      const lines = createInterface({ input: child.stdout });
      let secure, client, completed = false;
      const sync = createSyncCoordinator({ macDeviceId: host.device.id, persist: false, sendCodexRequest: async () => { throw new Error('unexpected_codex_request'); } });
      const send = (peer, wire) => child.stdin.write(JSON.stringify({ peer, wire: Buffer.from(typeof wire === 'string' ? wire : JSON.stringify(wire)).toString('base64') }) + '\n');
      const onExit = () => { clearTimeout(deadline); if (!completed) reject(new Error('native_probe_exited')); };
      child.once('exit', onExit);
      lines.on('line', line => {
        try {
          const event = JSON.parse(line);
          if (event.event === 'failed') throw new Error(`native_${event.code}`);
          if (event.event === 'ready') {
            assert.equal(event.relayed, relayOnly);
            secure = createBridgeSecureTransport({ sessionId: event.sessionId, relayUrl: 'wss://capability.invalid', persistTrustedPhone: false,
              deviceState: { macDeviceId: host.device.id, macIdentityPrivateKey: hostKey.privateRaw, macIdentityPublicKey: hostKey.publicRaw, trustedPhones: { [phoneId]: phoneKey.publicRaw } } });
            client = phoneProtocol({ hostKey, phoneKey, deviceId: host.device.id, phoneId, sessionId: event.sessionId, send: wire => send('phone', wire), completed() {
              completed = true;
              store.revokeCredential(phone.revocationToken);
              transport.changed();
            } });
            transport.streams.get(`host:${host.device.id}`).close('test_reconnect');
          } else if (event.event === 'resubscribed' && event.peer === 'host') {
            client.start();
          } else if (event.event === 'wire') {
            const wire = Buffer.from(event.wire, 'base64').toString();
            if (event.peer === 'phone') client.receive(wire);
            else secure.handleIncomingWireMessage(wire, {
              sendControlMessage: message => send('host', message),
              onApplicationMessage: message => sync.handleRequest(message, response => secure.queueOutboundApplicationMessage(response, output => send('host', output))),
            });
          } else if (event.event === 'revoked' && event.peer === 'host') {
            assert.equal(completed, true);
            clearTimeout(deadline);
            child.removeListener('exit', onExit);
            resolve();
          }
        } catch (error) { clearTimeout(deadline); reject(error); }
      });
    });
    child.stdin.end(JSON.stringify({ command: 'stop' }) + '\n');
    const [code] = await exited;
    assert.equal(code, 0);
    console.log(`native_signed_sse_loopback_http_signaling_${mode}_e2e_sync_hello_reconnect_revocation_passed`);
  } finally {
    clearInterval(ticker);
    child?.kill('SIGTERM');
    transport.close();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    store.close();
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
