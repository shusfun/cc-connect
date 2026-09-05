const { fail, digest } = require('./control-store');
const { verifyPassword } = require('./password');

function pageQuery(params) {
  const page = Number(params.get('page') || 1), size = Number(params.get('size') || 20);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000000 || !Number.isSafeInteger(size) || size < 1 || size > 100) fail(400, 'invalid_page');
  return { page, size, offset: (page - 1) * size, query: String(params.get('q') || '').slice(0, 100), status: params.get('status') || '' };
}
function management(store, { updater, liveStatus = () => ({ available: false, devices: [] }) } = {}) {
  function security(session) {
    store.db.prepare('INSERT OR IGNORE INTO session_security VALUES (?,?,?,0)').run(session.hash, digest(`session-id:${session.hash}`), store.now());
    return store.db.prepare('SELECT * FROM session_security WHERE session_hash=?').get(session.hash);
  }
  function admin(session, recent = false) {
    if (session.user.role !== 'admin' || session.user.status !== 'enabled') fail(403, 'admin_required');
    if (recent && security(session).verified_at < store.now() - 300000) fail(403, 'reauth_required');
  }
  function enabled(session) { if (session.user.status !== 'enabled') fail(403, 'account_not_enabled'); }
  function paged(sql, args, params) {
    const p = pageQuery(params);
    return { items: store.db.prepare(`${sql} LIMIT ? OFFSET ?`).all(...args, p.size, p.offset), total: store.db.prepare(`SELECT count(*) AS n FROM (${sql})`).get(...args).n, page: p.page, size: p.size };
  }
  async function get(name, session, params) {
    const user = session.user;
    if (name === 'profile') { security(session); return { user, canChangePassword: user.role === 'admin', verifiedUntil: security(session).verified_at + 300000 }; }
    enabled(session);
    if (name === 'sessions') {
      security(session);
      return store.db.prepare('SELECT s.id,s.created_at,b.expires_at FROM session_security s JOIN browser_sessions b ON b.hash=s.session_hash WHERE b.user_id=? AND b.expires_at>? ORDER BY s.created_at DESC').all(user.id, store.now()).map(row => ({ ...row, current: row.id === security(session).id }));
    }
    if (name === 'overview') {
      const own = user.role === 'admin' ? '' : ' WHERE account_id=?', args = own ? [user.id] : [];
      const live=liveStatus(), allowed=new Set(store.db.prepare(`SELECT id FROM devices${own}`).all(...args).map(row=>row.id));
      return { version: process.env.REMODEX_RELEASE_VERSION || require('../package.json').version, devices: store.db.prepare(`SELECT status,count(*) AS count FROM devices${own} GROUP BY status`).all(...args), accounts: user.role === 'admin' ? store.db.prepare('SELECT status,count(*) AS count FROM users GROUP BY status').all() : [], live: {...live,devices:live.devices.filter(id=>allowed.has(id))}, health: 'ok', schema: store.db.prepare('PRAGMA user_version').get().user_version };
    }
    if (name === 'device-list') {
      const p = pageQuery(params), args = [], where = ['1=1'];
      if (user.role !== 'admin') { where.push('d.account_id=?'); args.push(user.id); }
      if (p.status) { where.push('d.status=?'); args.push(p.status); }
      if (p.query) { where.push('(instr(d.remark,?)>0 OR instr(d.system_name,?)>0)'); args.push(p.query, p.query); }
      const result = paged(`SELECT d.*,u.login AS owner,g.phone_id,g.status AS pairing_status FROM devices d JOIN users u ON u.id=d.account_id LEFT JOIN grants g ON g.device_id=d.id WHERE ${where.join(' AND ')} ORDER BY d.created_at DESC,d.id`, args, params);
      const live = liveStatus();
      result.items = result.items.map(row => ({ ...row, online: live.available ? live.devices.includes(row.id) : null }));
      return result;
    }
    if (name === 'phones') {
      const args = user.role === 'admin' ? [] : [user.id];
      const result = paged(`SELECT p.id,p.account_id,p.status,u.login AS owner FROM phones p JOIN users u ON u.id=p.account_id ${args.length ? 'WHERE p.account_id=?' : ''} ORDER BY p.id`, args, params);
      return { ...result, items: result.items.map(p => ({ ...p, devices: store.db.prepare('SELECT d.id,d.remark,g.status FROM grants g JOIN devices d ON d.id=g.device_id WHERE g.phone_id=?').all(p.id) })) };
    }
    admin(session);
    if (name === 'accounts') {
      const p = pageQuery(params);
      return paged('SELECT id,github_id,login,role,status,device_limit,created_at FROM users WHERE (?=\'\' OR instr(login,?)>0) AND (?=\'\' OR status=?) ORDER BY created_at DESC,id', [p.query,p.query,p.status,p.status], params);
    }
    if (name === 'audit') {
      const p = pageQuery(params), from = Number(params.get('from') || 0), to = Number(params.get('to') || store.now());
      if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to)) fail(400, 'invalid_request');
      return paged('SELECT * FROM audit WHERE at>=? AND at<=? AND (?=\'\' OR instr(action,?)>0) AND (?=\'\' OR result=?) ORDER BY at DESC,id', [from,to,p.query,p.query,p.status,p.status], params);
    }
    if (name === 'settings') return { origin: store.get('origin'), githubClientId: store.get('githubClientId'), hasGithubSecret: !!store.get('githubClientSecret'), revision: store.get('configRevision') || 1, channel: 'stable', pending: !!store.get('pendingOAuth') };
    if (['updates','backups'].includes(name)) {
      if (!updater) return { available: false, code: 'updater_unavailable' };
      return updater(name === 'updates' ? 'status' : 'backups');
    }
    fail(404, 'not_found');
  }
  async function post(name, session, body) {
    const user = session.user;
    enabled(session);
    if (name === 'password') { await store.changePassword(user, body.oldPassword, body.newPassword); return { ok: true, loggedOut: true }; }
    if (name === 'reauth') {
      admin(session);
      const row = store.db.prepare('SELECT password FROM users WHERE id=?').get(user.id);
      if (!await verifyPassword(body.password, row?.password)) fail(401, 'login_failed');
      security(session); store.db.prepare('UPDATE session_security SET verified_at=? WHERE session_hash=?').run(store.now(), session.hash);
      return { ok: true };
    }
    if (name === 'session/revoke') {
      security(session);
      store.db.prepare('DELETE FROM browser_sessions WHERE user_id=? AND hash IN (SELECT session_hash FROM session_security WHERE id=?)').run(user.id, String(body.id));
      return { ok: true };
    }
    if (name === 'phone/revoke' || name === 'pairing/revoke') {
      return store.transaction(() => {
        const phone = store.db.prepare('SELECT * FROM phones WHERE id=?').get(String(body.phoneId));
        if (!phone || (phone.account_id !== user.id && user.role !== 'admin')) fail(403, 'device_forbidden');
        if (name === 'phone/revoke') {
          store.db.prepare("UPDATE phones SET status='revoked' WHERE id=?").run(phone.id);
          store.db.prepare("UPDATE grants SET status='revoked' WHERE phone_id=?").run(phone.id);
          store.db.prepare('UPDATE credentials SET revoked=1 WHERE phone_id=?').run(phone.id);
        } else {
          store.db.prepare("UPDATE grants SET status='revoked' WHERE phone_id=? AND device_id=?").run(phone.id, String(body.deviceId));
          store.db.prepare('UPDATE credentials SET revoked=1 WHERE phone_id=? AND device_id=?').run(phone.id, String(body.deviceId));
        }
        store.audit(user.id, name.replace('/', '.'), phone.id); return { ok: true };
      });
    }
    admin(session, name !== 'updates/check');
    if (name === 'settings/stage') {
      if (body.revision !== (store.get('configRevision') || 1)) fail(409, 'revision_conflict');
      let origin; try { origin = new URL(body.origin); } catch { fail(400, 'https_origin_required'); }
      if (origin.protocol !== 'https:' || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) fail(400, 'https_origin_required');
      if (typeof body.githubClientId !== 'string' || !body.githubClientId.trim() || body.githubClientId.length > 200) fail(400, 'invalid_request');
      const secret = body.githubClientSecret || store.unseal(store.get('githubClientSecret'));
      if (typeof secret !== 'string' || secret.length > 1000) fail(400, 'invalid_request');
      store.set('pendingOAuth', store.seal(JSON.stringify({ origin: origin.origin, githubClientId: body.githubClientId, githubClientSecret: secret, revision: body.revision, actor: user.id, expires: store.now() + 600000 })));
      store.audit(user.id, 'settings.staged', user.id);
      return { ok: true, verifyURL: '/v1/control/github/start?configuration=staged' };
    }
    const actions = { 'updates/check': 'check', 'updates/install': 'install', 'backups/create': 'backup', 'backups/restore': 'restore' };
      if (actions[name]) {
      if (!updater) fail(503, 'updater_unavailable');
      const result = await updater(actions[name], { version: body.version, backupId: body.backupId });
      store.audit(user.id, name.replace('/', '.'), null); return result;
    }
    fail(404, 'not_found');
  }
  return { get, post, security };
}
module.exports = { management, pageQuery };
