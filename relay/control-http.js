const { randomBytes } = require('node:crypto');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { verifyRequest, publicKeyObject } = require('@remodex/protocol');
const { digest, secret, fail } = require('./control-store');

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(JSON.stringify(body));
}
async function readBody(req) {
  let total = 0; const chunks = [];
  for await (const chunk of req) { total += chunk.length; if (total > 16384) fail(413, 'body_too_large'); chunks.push(chunk); }
  const raw = Buffer.concat(chunks).toString('utf8');
  let body;
  try { body = raw ? JSON.parse(raw) : {}; } catch { fail(400, 'invalid_json'); }
  if (!body || Array.isArray(body) || typeof body !== 'object') fail(400, 'invalid_request');
  return { raw, body };
}
function cookie(req, name) { return (req.headers.cookie || '').split(';').map(value => value.trim()).find(value => value.startsWith(`${name}=`))?.slice(name.length + 1) || ''; }
function setSessionCookie(res, token) { res.setHeader('set-cookie', `__Host-remodex=${token}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=${token ? 28800 : 0}`); }

function createControlHTTP({ store, setupToken, fetchImpl = fetch, onRevoked = () => {} }) {
  const setupHash = digest(setupToken);
  const buckets = new Map();
  function rateLimit(req) {
    const now = store.now();
    if (buckets.size > 10000) for (const [key, bucket] of buckets) if (bucket.until <= now) buckets.delete(key);
    const key = digest(req.headers['x-real-ip'] || req.socket.remoteAddress || 'unknown');
    let bucket = buckets.get(key);
    if (!bucket || bucket.until <= now) { bucket = { count: 0, until: now + 60000 }; buckets.set(key, bucket); }
    if (++bucket.count > 60) fail(429, 'rate_limited');
  }
  function proof(req, raw, token, publicKey) {
    try { publicKeyObject(publicKey); const { timestamp, nonce } = verifyRequest(req, raw, token, publicKey); store.useNonce(publicKey, nonce, timestamp); }
    catch (error) { if (error.status) throw error; fail(401, 'invalid_device_proof'); }
  }
  function deviceAuth(req, raw = '') {
    const token = (req.headers.authorization || '').replace(/^Bearer /, '');
    const access = store.authorize(token);
    proof(req, raw, token, access.public_key);
    return access;
  }
  function browser(req, mutate = false) {
    const session = store.browser(cookie(req, '__Host-remodex'));
    if (mutate && (req.headers.origin !== store.get('origin') || req.headers['x-csrf-token'] !== session.csrf)) fail(403, 'csrf_failed');
    return session;
  }
  function administrator(req, mutate = false) {
    const session = browser(req, mutate);
    if (session.user.role !== 'admin' || session.user.status !== 'enabled') fail(403, 'admin_required');
    return session;
  }
  async function route(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const pathname = url.pathname;
    if (!pathname.startsWith('/v1/control/') && !pathname.startsWith('/v1/access/') && !['/','/setup','/login','/admin','/control.js','/control.css'].includes(pathname)) return false;
    try {
      rateLimit(req);
      if (req.method === 'GET' && ['/','/setup','/login','/admin','/control.js','/control.css'].includes(pathname)) {
        const asset = pathname === '/control.js' ? 'control.js' : pathname === '/control.css' ? 'control.css' : 'index.html';
        const type = asset.endsWith('.js') ? 'text/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html';
        res.writeHead(200, { 'content-type': `${type}; charset=utf-8`, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" });
        res.end(readFileSync(path.join(__dirname, 'public', asset))); return true;
      }
      if (pathname === '/v1/control/status' && req.method === 'GET') {
        json(res, 200, { configured: !!store.get('configured'), complete: !!store.get('setupComplete'), instanceId: store.get('instanceId') }); return true;
      }
      if (pathname === '/v1/control/github/start' && req.method === 'GET') {
        if (!store.get('configured')) fail(503, 'setup_incomplete');
        let bindingUserId = null;
        if (!store.get('setupComplete')) bindingUserId = administrator(req).user.id;
        const state = secret(); const verifier = secret(); const binding = secret();
        store.db.prepare('DELETE FROM oauth_states WHERE expires_at<=?').run(store.now());
        store.db.prepare('INSERT INTO oauth_states VALUES (?,?,?,?)').run(digest(state), digest(binding), store.seal(JSON.stringify({ verifier, bindingUserId })), store.now() + 600000);
        const target = new URL('https://github.com/login/oauth/authorize');
        target.search = new URLSearchParams({ client_id: store.get('githubClientId'), redirect_uri: `${store.get('origin')}/v1/control/github/callback`, state, code_challenge: Buffer.from(digest(verifier), 'hex').toString('base64url'), code_challenge_method: 'S256' }).toString();
        res.setHeader('set-cookie', `__Host-remodex-oauth=${binding}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=600`);
        res.writeHead(302, { location: target.href, 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' }); res.end(); return true;
      }
      if (pathname === '/v1/control/github/callback' && req.method === 'GET') {
        const stateHash = digest(url.searchParams.get('state') || '');
        const row = store.db.prepare('SELECT * FROM oauth_states WHERE hash=? AND expires_at>?').get(stateHash, store.now());
        if (!row || row.session_hash !== digest(cookie(req, '__Host-remodex-oauth'))) fail(401, 'oauth_state_invalid');
        store.db.prepare('DELETE FROM oauth_states WHERE hash=?').run(stateHash);
        const code = url.searchParams.get('code'); if (!code || code.length > 1000) fail(401, 'oauth_denied');
        const state = JSON.parse(store.unseal(row.payload));
        const tokenResponse = await fetchImpl('https://github.com/login/oauth/access_token', { method: 'POST', headers: { accept: 'application/json', 'content-type': 'application/json' }, body: JSON.stringify({ client_id: store.get('githubClientId'), client_secret: store.unseal(store.get('githubClientSecret')), code, code_verifier: state.verifier, redirect_uri: `${store.get('origin')}/v1/control/github/callback` }), signal: AbortSignal.timeout(15000) });
        if (!tokenResponse.ok) fail(502, 'github_unavailable');
        const tokenData = await tokenResponse.json(); if (!tokenData.access_token) fail(401, 'github_login_failed');
        const identityResponse = await fetchImpl('https://api.github.com/user', { headers: { authorization: `Bearer ${tokenData.access_token}`, accept: 'application/vnd.github+json', 'user-agent': 'Remodex' }, signal: AbortSignal.timeout(15000) });
        if (!identityResponse.ok) fail(502, 'github_unavailable');
        const user = store.githubUser(await identityResponse.json(), state.bindingUserId);
        if (user.status === 'disabled') fail(403, 'account_disabled');
        const session = store.session(user.id); setSessionCookie(res, session.token);
        res.writeHead(302, { location: '/', 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' }); res.end(); return true;
      }
      if (pathname === '/v1/control/me' && req.method === 'GET') {
        const session = browser(req); json(res, 200, { user: session.user, csrf: session.csrf, origin: store.get('origin') }); return true;
      }
      if (pathname === '/v1/control/users' && req.method === 'GET') {
        administrator(req); json(res, 200, store.db.prepare('SELECT id,github_id,login,role,status,device_limit FROM users ORDER BY created_at DESC LIMIT 500').all()); return true;
      }
      if (pathname === '/v1/control/devices' && req.method === 'GET') {
        const { user } = browser(req); if (user.status !== 'enabled') fail(403, 'account_not_enabled');
        json(res, 200, user.role === 'admin' ? store.db.prepare('SELECT * FROM devices ORDER BY created_at DESC LIMIT 1000').all() : store.db.prepare('SELECT * FROM devices WHERE account_id=? ORDER BY created_at DESC').all(user.id)); return true;
      }
      if (pathname === '/v1/control/activation' && req.method === 'GET') {
        const { user } = browser(req); if (user.status !== 'enabled') fail(403, 'account_not_enabled');
        const request = store.request(url.searchParams.get('id'), 'activation');
        json(res, 200, { id: request.id, status: request.status, publicKey: request.public_key, ...request.payload }); return true;
      }
      if (req.method !== 'POST') fail(404, 'not_found');
      const { raw, body } = await readBody(req);
      let result = { ok: true };
      switch (pathname) {
        case '/v1/control/setup': {
          if (digest(req.headers['x-setup-token'] || '') !== setupHash) fail(403, 'setup_token_invalid');
          const user = await store.setup(body); const session = store.session(user.id); setSessionCookie(res, session.token);
          result = { user, csrf: session.csrf }; break;
        }
        case '/v1/control/login': {
          if (req.headers.origin !== store.get('origin')) fail(403, 'csrf_failed');
          const user = await store.passwordLogin(body.login, body.password); const session = store.session(user.id); setSessionCookie(res, session.token);
          result = { user, csrf: session.csrf }; break;
        }
        case '/v1/control/logout': {
          const session = browser(req, true); store.db.prepare('DELETE FROM browser_sessions WHERE hash=?').run(session.hash); setSessionCookie(res, ''); break;
        }
        case '/v1/control/review': {
          const { user } = administrator(req, true); store.review(user, body.userId, body.status, body.deviceLimit ?? null); onRevoked(); break;
        }
        case '/v1/control/activation/approve': {
          const { user } = browser(req, true); result = store.approveActivation(user, body.id); onRevoked(); break;
        }
        case '/v1/control/device/remark': {
          const { user } = browser(req, true); if (user.status !== 'enabled') fail(403, 'account_not_enabled');
          result = store.remark(user, body.deviceId, body.remark, body.revision); break;
        }
        case '/v1/control/device/revoke': {
          const { user } = browser(req, true); const device = store.device(body.deviceId);
          if (user.status !== 'enabled' || (device.account_id !== user.id && user.role !== 'admin')) fail(403, 'device_forbidden');
          store.transaction(() => { store.revokeDevice(device.id); store.audit(user.id, 'device.revoked', device.id); }); onRevoked(); break;
        }
        case '/v1/access/activation/start': {
          proof(req, raw, '', body.publicKey); result = store.startActivation(body); break;
        }
        case '/v1/access/activation/redeem': {
          proof(req, raw, body.token, body.publicKey); result = store.redeemActivation(body.id, body.token, body.publicKey); break;
        }
        case '/v1/access/pairing/claim': {
          proof(req, raw, '', body.publicKey); result = store.claimInvitation(body.invitation, body.publicKey); break;
        }
        case '/v1/access/pairing/redeem': {
          proof(req, raw, body.token, body.publicKey); result = store.redeemPairing(body.id, body.token, body.publicKey); break;
        }
        case '/v1/access/revoke': {
          if (typeof body.revocationToken !== 'string') fail(400, 'invalid_request');
          store.revokeCredential(body.revocationToken); onRevoked(); break;
        }
        default: {
          const access = deviceAuth(req, raw);
          switch (pathname) {
            case '/v1/access/device': result = { device: access.device, accountId: access.user.id, instanceId: store.get('instanceId'), trustedPhone: store.db.prepare("SELECT p.id,p.public_key FROM grants g JOIN phones p ON p.id=g.phone_id WHERE g.device_id=? AND g.status='active' AND p.status='active'").get(access.device_id) || null }; break;
            case '/v1/access/device/remark': result = store.remark(access.user, access.device_id, body.remark, body.revision); break;
            case '/v1/access/pairing/invite':
              if (access.kind !== 'host') fail(403, 'host_required'); result = store.invite(access.device_id); break;
            case '/v1/access/pairing/pending':
              if (access.kind !== 'host') fail(403, 'host_required');
              result = store.db.prepare("SELECT id,public_key,expires_at FROM requests WHERE kind='pairing' AND status='pending' AND expires_at>? AND json_extract(payload,'$.deviceId')=?").all(store.now(), access.device_id); break;
            case '/v1/access/pairing/approve':
              if (access.kind !== 'host') fail(403, 'host_required'); store.approvePairing(access.device_id, body.id, body.replace); onRevoked(); break;
            default: fail(404, 'not_found');
          }
        }
      }
      json(res, 200, result);
    } catch (error) {
      json(res, error.status || 500, { ok: false, code: error.status ? error.code : 'internal_error' });
    }
    return true;
  }
  return { route, deviceAuth, store };
}
module.exports = { createControlHTTP };
