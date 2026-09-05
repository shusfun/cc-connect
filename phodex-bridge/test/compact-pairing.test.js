const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes, createHash } = require('node:crypto');
const { compactPairingCode, relaySessionURL, relayOrigin } = require('@remodex/protocol');
const QR = require('qrcode-terminal/vendor/QRCode');
const levels = require('qrcode-terminal/vendor/QRCode/QRErrorCorrectLevel');
test('紧凑二维码保持完整密钥，1000 次编码一致，模块数低于旧 JSON', () => {
  const payload = { v: 1, relay: 'wss://cc.syggu.cn', invitation: randomBytes(32).toString('base64url'), macIdentityPublicKey: randomBytes(32).toString('base64'), sessionId: '3e5937ce-59f4-4811-b2af-e85f87b9bfad', macDeviceId: '3e5937ce-59f4-4811-b2af-e85f87b9bfae', expiresAt: 1900000000000, displayName: '开发电脑', accountId: '3e5937ce-59f4-4811-b2af-e85f87b9bfaf', instanceId: '3e5937ce-59f4-4811-b2af-e85f87b9bfaa', platform: 'macos' };
  const text = compactPairingCode(payload); assert.ok(Buffer.byteLength(text) <= 140);
  for (let i = 0; i < 1000; i++) assert.equal(compactPairingCode({ ...payload }), text);
  assert.deepEqual(JSON.parse(text.slice(5)), [payload.relay, payload.invitation, payload.macIdentityPublicKey]);
  const make = value => { const qr = new QR(-1, levels.M); qr.addData(value); qr.make(); return qr; };
  const old = make(JSON.stringify(payload)), compact = make(text);
  assert.ok(compact.getModuleCount() < old.getModuleCount());
  const patternDigest = qr => createHash('sha256').update(JSON.stringify(qr.modules)).digest('hex');
  const expectedPattern = patternDigest(compact);
  for (let i = 0; i < 1000; i++) assert.equal(patternDigest(make(text)), expectedPattern);
  console.info(JSON.stringify({ oldBytes: Buffer.byteLength(JSON.stringify(payload)), compactBytes: Buffer.byteLength(text), oldModules: old.getModuleCount(), compactModules: compact.getModuleCount(), correction: 'M' }));
});
test('Relay 地址统一规范化，拒绝不安全或歧义地址', () => {
  for (const address of ['wss://cc.syggu.cn','wss://cc.syggu.cn/','wss://cc.syggu.cn/relay','https://cc.syggu.cn/relay/']) assert.equal(relaySessionURL(address, 'sample-session'), 'wss://cc.syggu.cn/relay/sample-session');
  for (const address of ['ws://example.test','wss://user:pass@example.test','wss://example.test/other','wss://example.test?token=secret']) assert.throws(() => relayOrigin(address));
  assert.throws(() => relaySessionURL('wss://example.test', '../other'));
  assert.throws(() => compactPairingCode({ relay: 'wss://example.test', invitation: 'short', macIdentityPublicKey: 'bad' }));
});
