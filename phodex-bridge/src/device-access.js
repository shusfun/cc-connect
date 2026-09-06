const { signedHeaders } = require('@remodex/protocol');

function retryAfterMilliseconds(value, now = Date.now()) {
  if (!value) return 0;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const deadline = Date.parse(value);
  return Number.isFinite(deadline) ? Math.max(0, deadline - now) : 0;
}

class DeviceAccess {
  constructor({ relay, privateKey, publicKey, credential }) {
    const origin = new URL(relay.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:'));
    if (origin.protocol !== 'https:' || origin.username || origin.password) throw new Error('https_relay_required');
    if (!credential?.token || !privateKey || !publicKey) throw new Error('activation_required');
    this.origin = origin.origin;
    this.privateKey = privateKey;
    this.publicKey = publicKey;
    this.credential = credential;
  }
  headers(method, path, body = '') { return signedHeaders({ method, path, body, token: this.credential.token, privateKey: this.privateKey, publicKey: this.publicKey }); }
  async request(path, payload = {}, { signal } = {}) {
    const body = JSON.stringify(payload);
    const timeout = AbortSignal.timeout(15000);
    const response = await fetch(`${this.origin}${path}`, { method: 'POST', body, headers: { ...this.headers('POST', path, body), 'content-type': 'application/json' }, signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
    let result;
    try { result = await response.json(); }
    catch {
      if (response.ok) throw Object.assign(new Error('relay_response_invalid'), { code: 'relay_response_invalid' });
      result = { code: 'relay_request_failed' };
    }
    if (!response.ok) throw Object.assign(new Error(result.code || 'relay_request_failed'), { code: result.code, status: response.status, retryAfter: retryAfterMilliseconds(response.headers.get('retry-after')) });
    return result;
  }
}
module.exports = { DeviceAccess, retryAfterMilliseconds };
