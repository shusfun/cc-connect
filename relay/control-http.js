const { randomBytes } = require('node:crypto');
const { readFileSync, existsSync } = require('node:fs');
const path = require('node:path');
const { verifyRequest, publicKeyObject } = require('@remodex/protocol');
const { digest, secret, fail } = require('./control-store');
const { beginDiagnostic } = require('./diagnostics');

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

function createControlHTTP({ store, setupToken, fetchImpl = fetch, onRevoked = () => {}, updater, liveStatus, logger = record => console.info(JSON.stringify(record)) }) {
  const management = require('./management').management(store, { updater, liveStatus });
  const setupHash = digest(setupToken);
  const buckets = new Map();
  function rateLimit(req) {
    const now = store.now();
    if (buckets.size > 10000) for (const [key, bucket] of buckets) if (bucket.until <= now) buckets.delete(key);
    const key = digest(req.headers['x-real-ip'] || req.socket.remoteAddress || 'unknown');
    let bucket = buckets.get(key);
    if (!bucket || bucket.until <= now) { bucket = { count: 0, until: now + 60000 }; buckets.set(key, bucket); }
    if (++bucket.count > 60) { req.remodexRetryAfter = Math.max(1, Math.ceil((bucket.until - now) / 1000)); fail(429, 'rate_limited'); }
  }
  function proof(req, raw, token, publicKey) {
    try { publicKeyObject(publicKey); const { timestamp, nonce } = verifyRequest(req, raw, token, publicKey); store.useNonce(publicKey, nonce, timestamp); if (req.remodexDiagnostic) req.remodexDiagnostic.stage = 'handler'; }
    catch (error) { if (error.status) throw error; fail(401, 'invalid_device_proof'); }
  }
  function deviceAuth(req, raw = '') {
    const token = (req.headers.authorization || '').replace(/^Bearer /, '');
    const access = store.authorize(token);
    proof(req, raw, token, access.public_key);
    req.remodexActor = access.user.id;
    if (req.remodexDiagnostic) req.remodexDiagnostic.stage = 'handler';
    return access;
  }
  function browser(req, mutate = false) {
    const session = store.browser(cookie(req, '__Host-remodex'));
    req.remodexActor = session.user.id;
    if (mutate && (req.headers.origin !== store.get('origin') || req.headers['x-csrf-token'] !== session.csrf)) fail(403, 'csrf_failed');
    if (req.remodexDiagnostic) req.remodexDiagnostic.stage = 'handler';
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
    const appPage = /^\/(?:setup|login|admin(?:\/(?:accounts|devices|phones|profile|settings|audit|updates))?)?$/.test(pathname);
    const assetName = pathname.match(/^\/assets\/([a-zA-Z0-9_.-]+\.(?:js|css))$/)?.[1];
    if (!pathname.startsWith('/v1/control/') && !pathname.startsWith('/v1/access/') && !appPage && !assetName && !['/control.js','/control.css'].includes(pathname)) return false;
    if (pathname.startsWith('/v1/')) {
      const diagnostic = beginDiagnostic(req, res, pathname), started = performance.now();
      res.once('finish', () => {
        // 正常轮询不逐次落库；失败和关键写操作保留安全的关联信息。
        if (['approval_pending','rate_limited'].includes(diagnostic.code) || (res.statusCode < 400 && (req.method === 'GET' || ['access/device','access/pairing/pending','access/session'].includes(diagnostic.route)))) return;
        const record = { ...diagnostic, status: res.statusCode, durationMs: Math.round(performance.now() - started), result: res.statusCode < 400 ? 'success' : 'failure' };
        try { logger({ event: 'management_request', ...record }); } catch { /* 诊断失败不能改变已完成请求的结果。 */ }
        if (req.remodexActor) {
          try { store.audit(req.remodexActor, record.result === 'failure' ? 'control.request_rejected' : 'control.request_completed', null, record.result, record); }
          catch { try { logger({ event: 'diagnostic_unavailable', requestId: diagnostic.requestId }); } catch {} }
        }
      });
    }
    try {
      rateLimit(req);
      if (req.method === 'GET' && (appPage || assetName || ['/control.js','/control.css'].includes(pathname))) {
        const asset = assetName ? `assets/${assetName}` : pathname === '/control.js' ? 'control.js' : pathname === '/control.css' ? 'control.css' : 'index.html';
        const type = asset.endsWith('.js') ? 'text/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html';
        const file = path.join(__dirname, 'public/app', asset);
        if (!existsSync(file)) fail(assetName ? 404 : 503, assetName ? 'not_found' : 'control_build_required');
        const styleNonce = randomBytes(18).toString('base64');
        res.writeHead(200, { 'content-type': `${type}; charset=utf-8`, 'cache-control': assetName ? 'public, max-age=31536000, immutable' : 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'content-security-policy': `default-src 'self'; script-src 'self'; style-src 'self' 'nonce-${styleNonce}'; style-src-attr 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'` });
        const content = readFileSync(file);
        res.end(type === 'text/html' ? content.toString('utf8').replace('__REMODEX_STYLE_NONCE__', styleNonce) : content); return true;
      }
      if (pathname === '/v1/control/status' && req.method === 'GET') {
        json(res, 200, { configured: !!store.get('configured'), complete: !!store.get('setupComplete'), instanceId: store.get('instanceId') }); return true;
      }
      if (pathname === '/v1/control/github/start' && req.method === 'GET') {
        if (!store.get('configured')) fail(503, 'setup_incomplete');
        let bindingUserId = null;
        if (!store.get('setupComplete')) bindingUserId = administrator(req).user.id;
        let staged;
        if (url.searchParams.get('configuration') === 'staged') {
          const { user } = administrator(req);
          try { staged = JSON.parse(store.unseal(store.get('pendingOAuth'))); } catch { fail(409, 'configuration_missing'); }
          if (staged.actor !== user.id || staged.expires < store.now()) fail(409, 'configuration_expired');
        }
        const state = secret(); const verifier = secret(); const binding = secret();
        store.db.prepare('DELETE FROM oauth_states WHERE expires_at<=?').run(store.now());
        store.db.prepare('INSERT INTO oauth_states VALUES (?,?,?,?)').run(digest(state), digest(binding), store.seal(JSON.stringify({ verifier, bindingUserId, staged })), store.now() + 600000);
        const target = new URL('https://github.com/login/oauth/authorize');
        target.search = new URLSearchParams({ client_id: staged?.githubClientId || store.get('githubClientId'), redirect_uri: `${store.get('origin')}/v1/control/github/callback`, state, code_challenge: Buffer.from(digest(verifier), 'hex').toString('base64url'), code_challenge_method: 'S256' }).toString();
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
        const tokenResponse = await fetchImpl('https://github.com/login/oauth/access_token', { method: 'POST', headers: { accept: 'application/json', 'content-type': 'application/json' }, body: JSON.stringify({ client_id: state.staged?.githubClientId || store.get('githubClientId'), client_secret: state.staged?.githubClientSecret || store.unseal(store.get('githubClientSecret')), code, code_verifier: state.verifier, redirect_uri: `${store.get('origin')}/v1/control/github/callback` }), signal: AbortSignal.timeout(15000) });
        if (!tokenResponse.ok) fail(502, 'github_unavailable');
        const tokenData = await tokenResponse.json(); if (!tokenData.access_token) fail(401, 'github_login_failed');
        const identityResponse = await fetchImpl('https://api.github.com/user', { headers: { authorization: `Bearer ${tokenData.access_token}`, accept: 'application/vnd.github+json', 'user-agent': 'Remodex' }, signal: AbortSignal.timeout(15000) });
        if (!identityResponse.ok) fail(502, 'github_unavailable');
        const identity = await identityResponse.json();
        if (state.staged) {
          const candidate = state.staged;
          const { user } = administrator(req);
          store.transaction(() => {
            if (user.id !== candidate.actor || String(identity.id) !== user.github_id) fail(403, 'binding_forbidden');
            if (candidate.expires < store.now() || candidate.revision !== (store.get('configRevision') || 1) || JSON.stringify(candidate) !== store.unseal(store.get('pendingOAuth'))) fail(409, 'revision_conflict');
            store.set('origin', candidate.origin); store.set('githubClientId', candidate.githubClientId); store.set('githubClientSecret', store.seal(candidate.githubClientSecret));
            store.set('configRevision', candidate.revision + 1); store.set('pendingOAuth', null); store.audit(user.id, 'settings.updated', user.id);
          });
          res.writeHead(302, { location: `${candidate.origin}/admin/settings`, 'cache-control': 'no-store' }); res.end(); return true;
        }
        const user = store.githubUser(identity, state.bindingUserId);
        if (user.status === 'disabled') fail(403, 'account_disabled');
        const session = store.session(user.id); setSessionCookie(res, session.token);
        res.writeHead(302, { location: '/', 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' }); res.end(); return true;
      }
      if (pathname === '/v1/control/me' && req.method === 'GET') {
        const session = browser(req); management.security(session); json(res, 200, { user: session.user, csrf: session.csrf, origin: store.get('origin') }); return true;
      }
      if (pathname.startsWith('/v1/control/manage/') && req.method === 'GET') {
        json(res, 200, await management.get(pathname.slice('/v1/control/manage/'.length), browser(req), url.searchParams)); return true;
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
        json(res, 200, store.activationStatus(user, url.searchParams.get('id'))); return true;
      }
      if (req.method !== 'POST') fail(404, 'not_found');
      const { raw, body } = await readBody(req);
      if (pathname.startsWith('/v1/control/manage/')) {
        const name = pathname.slice('/v1/control/manage/'.length);
        const result = await management.post(name, browser(req, true), body);
        if (result.loggedOut) setSessionCookie(res, '');
        if (name.endsWith('/revoke')) onRevoked();
        json(res, 200, result); return true;
      }
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
        case '/v1/access/pairing/preview': {
          result = store.previewInvitation(body.invitation);
          const live = liveStatus?.();
          if (live?.available && !live.devices.includes(result.device.id)) fail(404, 'device_offline');
          break;
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
      if (req.remodexDiagnostic) req.remodexDiagnostic.code = error.status && /^[a-z_]+$/.test(error.code || '') ? error.code : 'internal_error';
      if (req.remodexRetryAfter) res.setHeader('retry-after', String(req.remodexRetryAfter));
      json(res, error.status || 500, { ok: false, code: error.status ? error.code : 'internal_error' });
    }
    return true;
  }
  return { route, deviceAuth, store };
}
module.exports = { createControlHTTP };
