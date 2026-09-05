const { signedHeaders } = require('@remodex/protocol');

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
  async request(path, payload = {}) {
    const body = JSON.stringify(payload);
    const response = await fetch(`${this.origin}${path}`, { method: 'POST', body, headers: { ...this.headers('POST', path, body), 'content-type': 'application/json' }, signal: AbortSignal.timeout(15000) });
    const result = await response.json();
    if (!response.ok) throw Object.assign(new Error(result.code || 'relay_request_failed'), { code: result.code, status: response.status });
    return result;
  }
}
module.exports = { DeviceAccess };
