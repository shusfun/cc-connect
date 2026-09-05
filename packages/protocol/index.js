const { createHash, createPublicKey, createPrivateKey, verify, sign, randomBytes } = require('node:crypto');

const REQUEST_TAG = 'remodex-access-v1';
const sha256 = value => createHash('sha256').update(value).digest('hex');
function publicKeyObject(raw) {
  const bytes = Buffer.from(raw, 'base64');
  if (bytes.length !== 32 || bytes.toString('base64') !== raw) throw new Error('invalid_public_key');
  return createPublicKey({ format: 'der', type: 'spki', key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), bytes]) });
}
function requestTranscript({ method, path, body = '', timestamp, nonce, token = '' }) {
  return Buffer.from([REQUEST_TAG, method.toUpperCase(), path, sha256(body), String(timestamp), nonce, sha256(token)].join('\n'));
}
function signedHeaders({ method, path, body = '', token = '', privateKey, publicKey, now = Date.now() }) {
  const nonce = randomBytes(24).toString('base64url');
  const key = typeof privateKey === 'string' ? createPrivateKey({ key: { kty: 'OKP', crv: 'Ed25519', d: Buffer.from(privateKey, 'base64').toString('base64url'), x: Buffer.from(publicKey, 'base64').toString('base64url') }, format: 'jwk' }) : privateKey;
  return {
    authorization: `Bearer ${token}`,
    'x-remodex-key': publicKey,
    'x-remodex-time': String(now),
    'x-remodex-nonce': nonce,
    'x-remodex-signature': sign(null, requestTranscript({ method, path, body, timestamp: now, nonce, token }), key).toString('base64'),
  };
}
function verifyRequest(req, body, token, publicKey) {
  const timestamp = Number(req.headers['x-remodex-time']);
  const nonce = req.headers['x-remodex-nonce'];
  const signature = req.headers['x-remodex-signature'];
  if (typeof signature !== 'string' || typeof nonce !== 'string' || req.headers['x-remodex-key'] !== publicKey) throw new Error('invalid_device_proof');
  const path = new URL(req.url, 'http://localhost').pathname;
  if (!verify(null, requestTranscript({ method: req.method, path, body, timestamp, nonce, token }), publicKeyObject(publicKey), Buffer.from(signature, 'base64'))) throw new Error('invalid_device_proof');
  return { timestamp, nonce };
}
module.exports = { REQUEST_TAG, publicKeyObject, requestTranscript, signedHeaders, verifyRequest };
