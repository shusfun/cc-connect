const { DatabaseSync } = require('node:sqlite');
const { randomBytes, randomUUID, createHash, createCipheriv, createDecipheriv, timingSafeEqual, scrypt } = require('node:crypto');
const { promisify } = require('node:util');

const derivePassword = promisify(scrypt);
const digest = value => createHash('sha256').update(value).digest('hex');
const secret = () => randomBytes(32).toString('base64url');
function fail(status, code) { throw Object.assign(new Error(code), { status, code }); }
function requireValue(value, maximum = 200) {
  if (typeof value !== 'string' || !value.trim() || value.length > maximum) fail(400, 'invalid_request');
  return value.trim();
}

class ControlStore {
  constructor({ filename, masterKey, now = Date.now }) {
    if (!Buffer.isBuffer(masterKey) || masterKey.length !== 32) throw new Error('master_key_required');
    this.masterKey = masterKey;
    this.now = now;
    this.db = new DatabaseSync(filename);
    this.db.exec('PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;');
    const version = this.db.prepare('PRAGMA user_version').get().user_version;
    if (version > 1) throw new Error('database_update_required');
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, github_id TEXT UNIQUE, login TEXT NOT NULL, password TEXT,
        role TEXT NOT NULL CHECK(role IN ('admin','user')),
        status TEXT NOT NULL CHECK(status IN ('pending','enabled','rejected','disabled')),
        device_limit INTEGER CHECK(device_limit IS NULL OR device_limit>=0), created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS browser_sessions (
        hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), csrf TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS oauth_states (
        hash TEXT PRIMARY KEY, session_hash TEXT NOT NULL, payload TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES users(id), public_key TEXT NOT NULL UNIQUE,
        platform TEXT NOT NULL CHECK(platform IN ('macos','windows')), system_name TEXT NOT NULL,
        remark TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL CHECK(status IN ('active','revoked')), created_at INTEGER NOT NULL, last_seen INTEGER);
      CREATE TABLE IF NOT EXISTS phones (
        id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES users(id), public_key TEXT UNIQUE NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('active','revoked')));
      CREATE TABLE IF NOT EXISTS grants (
        device_id TEXT PRIMARY KEY REFERENCES devices(id), phone_id TEXT NOT NULL REFERENCES phones(id),
        status TEXT NOT NULL CHECK(status IN ('active','revoked')));
      CREATE TABLE IF NOT EXISTS credentials (
        hash TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('host','phone')), device_id TEXT NOT NULL REFERENCES devices(id),
        phone_id TEXT REFERENCES phones(id), public_key TEXT NOT NULL, revocation_hash TEXT NOT NULL UNIQUE,
        revoked INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS requests (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, token_hash TEXT NOT NULL, public_key TEXT NOT NULL,
        payload TEXT NOT NULL, status TEXT NOT NULL, account_id TEXT REFERENCES users(id), expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS invitations (
        hash TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id), expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS nonces (hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS audit (
        id TEXT PRIMARY KEY, at INTEGER NOT NULL, actor_id TEXT, action TEXT NOT NULL, target_id TEXT);
      PRAGMA user_version=1;
    `);
  }
  close() { this.db.close(); }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = action(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  get(key) { const row = this.db.prepare('SELECT value FROM settings WHERE key=?').get(key); return row ? JSON.parse(row.value) : null; }
  set(key, value) { this.db.prepare('INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key, JSON.stringify(value)); }
  seal(value) {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.masterKey, iv);
    return Buffer.concat([iv, cipher.update(value, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64');
  }
  unseal(value) {
    const bytes = Buffer.from(value, 'base64');
    const cipher = createDecipheriv('aes-256-gcm', this.masterKey, bytes.subarray(0, 12));
    cipher.setAuthTag(bytes.subarray(-16));
    return Buffer.concat([cipher.update(bytes.subarray(12, -16)), cipher.final()]).toString('utf8');
  }
  audit(actor, action, target) { this.db.prepare('INSERT INTO audit VALUES (?,?,?,?,?)').run(randomUUID(), this.now(), actor, action, target); }
  async setup({ login, password, githubClientId, githubClientSecret, origin }) {
    if (this.get('configured')) fail(409, 'setup_closed');
    login = requireValue(login, 80);
    if (typeof password !== 'string' || password.length < 14 || password.length > 1024) fail(400, 'password_too_short');
    const publicURL = new URL(origin);
    if (publicURL.protocol !== 'https:' || publicURL.username || publicURL.password || publicURL.pathname !== '/' || publicURL.search || publicURL.hash) fail(400, 'https_origin_required');
    const salt = secret();
    const derived = await derivePassword(password, salt, 64);
    return this.transaction(() => {
      if (this.get('configured')) fail(409, 'setup_closed');
      const id = randomUUID();
      this.db.prepare('INSERT INTO users VALUES (?,NULL,?,?,?, ?,NULL,?)').run(id, login, `${salt}:${derived.toString('hex')}`, 'admin', 'enabled', this.now());
      this.set('origin', publicURL.origin);
      this.set('instanceId', randomUUID());
      this.set('githubClientId', requireValue(githubClientId));
      this.set('githubClientSecret', this.seal(requireValue(githubClientSecret, 1000)));
      this.set('configured', true);
      this.set('setupComplete', false);
      this.audit(id, 'setup.created', id);
      return this.user(id);
    });
  }
  user(id) { return this.db.prepare('SELECT id,github_id,login,role,status,device_limit FROM users WHERE id=?').get(id); }
  async passwordLogin(login, password) {
    const row = this.db.prepare("SELECT * FROM users WHERE login=? AND role='admin'").get(String(login));
    const [salt, expected] = (row?.password || `${'0'.repeat(43)}:${'0'.repeat(128)}`).split(':');
    const actual = await derivePassword(String(password).slice(0, 1024), salt, 64);
    if (!row || !timingSafeEqual(Buffer.from(expected, 'hex'), actual) || row.status !== 'enabled') fail(401, 'login_failed');
    return this.user(row.id);
  }
  session(userId) {
    const token = secret(); const csrf = secret();
    this.db.prepare('INSERT INTO browser_sessions VALUES (?,?,?,?)').run(digest(token), userId, csrf, this.now() + 8 * 3600000);
    return { token, csrf };
  }
  browser(token) {
    const row = this.db.prepare('SELECT * FROM browser_sessions WHERE hash=? AND expires_at>?').get(digest(token || ''), this.now());
    if (!row) fail(401, 'login_required');
    const user = this.user(row.user_id);
    if (!user || user.status === 'disabled') fail(403, 'account_disabled');
    return { ...row, user };
  }
  githubUser(identity, bindingUserId) {
    const githubId = String(identity.id);
    if (!/^\d+$/.test(githubId)) fail(401, 'github_identity_invalid');
    return this.transaction(() => {
      const existing = this.db.prepare('SELECT id FROM users WHERE github_id=?').get(githubId);
      if (bindingUserId) {
        const admin = this.user(bindingUserId);
        if (admin?.role !== 'admin' || admin.status !== 'enabled' || this.get('setupComplete')) fail(403, 'binding_forbidden');
        if (existing && existing.id !== bindingUserId) fail(409, 'github_already_bound');
        this.db.prepare('UPDATE users SET github_id=? WHERE id=?').run(githubId, bindingUserId);
        this.set('setupComplete', true);
        this.audit(bindingUserId, 'setup.completed', bindingUserId);
        return this.user(bindingUserId);
      }
      if (!this.get('setupComplete')) fail(403, 'setup_incomplete');
      if (existing) {
        this.db.prepare("UPDATE users SET login=? WHERE id=? AND role='user'").run(requireValue(identity.login, 80), existing.id);
        return this.user(existing.id);
      }
      const id = randomUUID();
      this.db.prepare("INSERT INTO users VALUES (?,?,?,NULL,'user','pending',NULL,?)").run(id, githubId, requireValue(identity.login, 80), this.now());
      this.audit(id, 'account.requested', id);
      return this.user(id);
    });
  }
  review(actor, userId, status, limit) {
    if (actor.role !== 'admin' || actor.status !== 'enabled') fail(403, 'admin_required');
    if (!['enabled','rejected','disabled'].includes(status) || (limit !== null && (!Number.isSafeInteger(limit) || limit < 0))) fail(400, 'invalid_request');
    return this.transaction(() => {
      const target = this.user(userId);
      if (!target || target.role === 'admin') fail(403, 'account_review_forbidden');
      this.db.prepare('UPDATE users SET status=?,device_limit=? WHERE id=?').run(status, limit, userId);
      if (status !== 'enabled') {
        for (const row of this.db.prepare('SELECT id FROM devices WHERE account_id=?').all(userId)) this.revokeDevice(row.id);
        this.db.prepare('DELETE FROM browser_sessions WHERE user_id=?').run(userId);
      }
      this.audit(actor.id, `account.${status}`, userId);
    });
  }
  startActivation({ publicKey, platform, systemName }) {
    if (!this.get('setupComplete')) fail(503, 'setup_incomplete');
    if (!['macos','windows'].includes(platform)) fail(400, 'unsupported_platform');
    const id = randomUUID(); const token = secret(); const code = randomBytes(4).toString('hex').toUpperCase();
    this.db.prepare("INSERT INTO requests VALUES (?,'activation',?,?,?,'pending',NULL,?)").run(id, digest(token), publicKey, JSON.stringify({ platform, systemName: requireValue(systemName, 100), code }), this.now() + 300000);
    return { id, token, code, expiresAt: this.now() + 300000, approvalURL: `${this.get('origin')}/?activation=${id}` };
  }
  request(id, kind) {
    const row = this.db.prepare('SELECT * FROM requests WHERE id=? AND kind=? AND expires_at>?').get(id, kind, this.now());
    if (!row) fail(410, 'request_expired');
    return { ...row, payload: JSON.parse(row.payload) };
  }
  approveActivation(actor, id) {
    if (actor.status !== 'enabled') fail(403, 'account_not_enabled');
    return this.transaction(() => {
      const request = this.request(id, 'activation');
      if (request.status !== 'pending') fail(409, 'request_consumed');
      const existing = this.db.prepare('SELECT * FROM devices WHERE public_key=?').get(request.public_key);
      if (existing && existing.account_id !== actor.id) fail(409, 'device_owned_by_other_account');
      const count = this.db.prepare("SELECT count(*) AS n FROM devices WHERE account_id=? AND status='active'").get(actor.id).n;
      if (actor.device_limit !== null && count >= actor.device_limit && existing?.status !== 'active') fail(409, 'device_limit_reached');
      const deviceId = existing?.id || randomUUID();
      if (existing) this.revokeDevice(deviceId);
      this.db.prepare(`INSERT INTO devices VALUES (?,?,?,?,?,?,1,'active',?,NULL)
        ON CONFLICT(id) DO UPDATE SET status='active',system_name=excluded.system_name,revision=devices.revision+1`).run(deviceId, actor.id, request.public_key, request.payload.platform, request.payload.systemName, request.payload.systemName, this.now());
      this.db.prepare("UPDATE requests SET status='approved',account_id=?,payload=? WHERE id=?").run(actor.id, JSON.stringify({ ...request.payload, deviceId }), id);
      this.audit(actor.id, 'device.activated', deviceId);
      return this.device(deviceId);
    });
  }
  credential(kind, deviceId, publicKey, phoneId = null) {
    const token = secret(); const revocationToken = secret();
    this.db.prepare('INSERT INTO credentials VALUES (?,?,?,?,?,?,0,?)').run(digest(token), kind, deviceId, phoneId, publicKey, digest(revocationToken), this.now());
    const device = this.device(deviceId);
    return { token, revocationToken, kind, deviceId, phoneId, accountId: device.account_id, instanceId: this.get('instanceId'), device };
  }
  redeemActivation(id, token, publicKey) {
    return this.transaction(() => {
      const request = this.request(id, 'activation');
      if (request.token_hash !== digest(token) || request.public_key !== publicKey) fail(401, 'invalid_device_proof');
      if (request.status !== 'approved') fail(409, request.status === 'pending' ? 'approval_pending' : 'request_consumed');
      const device = this.device(request.payload.deviceId);
      if (device.status !== 'active' || this.user(device.account_id)?.status !== 'enabled') fail(403, 'device_revoked');
      this.db.prepare("UPDATE requests SET status='redeemed' WHERE id=?").run(id);
      return this.credential('host', device.id, publicKey);
    });
  }
  device(id) { const row = this.db.prepare('SELECT * FROM devices WHERE id=?').get(id); if (!row) fail(404, 'device_not_found'); return row; }
  authorize(token) {
    const row = this.db.prepare('SELECT * FROM credentials WHERE hash=? AND revoked=0').get(digest(token || ''));
    if (!row) fail(401, 'credential_revoked');
    const device = this.device(row.device_id);
    const user = this.user(device.account_id);
    if (device.status !== 'active' || user?.status !== 'enabled') fail(403, 'device_revoked');
    if (row.kind === 'phone') {
      const grant = this.db.prepare("SELECT g.* FROM grants g JOIN phones p ON p.id=g.phone_id WHERE g.device_id=? AND g.phone_id=? AND g.status='active' AND p.status='active'").get(row.device_id, row.phone_id);
      if (!grant) fail(403, 'pairing_revoked');
    }
    return { ...row, device, user };
  }
  useNonce(publicKey, nonce, timestamp) {
    if (typeof nonce !== 'string' || nonce.length < 24 || nonce.length > 100 || !Number.isSafeInteger(timestamp) || Math.abs(this.now() - timestamp) > 60000) fail(401, 'request_expired');
    this.db.prepare('DELETE FROM nonces WHERE expires_at<=?').run(this.now());
    const inserted = this.db.prepare('INSERT OR IGNORE INTO nonces VALUES (?,?)').run(digest(`${publicKey}:${nonce}`), this.now() + 120000);
    if (!inserted.changes) fail(409, 'request_replayed');
  }
  remark(actor, deviceId, remark, revision) {
    const device = this.device(deviceId);
    if (actor.id !== device.account_id && actor.role !== 'admin') fail(403, 'device_forbidden');
    remark = requireValue(remark, 100);
    const result = this.db.prepare('UPDATE devices SET remark=?,revision=revision+1 WHERE id=? AND revision=?').run(remark, deviceId, revision);
    if (!result.changes) fail(409, 'revision_conflict');
    return this.device(deviceId);
  }
  revokeDevice(id) {
    this.db.prepare("UPDATE devices SET status='revoked',revision=revision+1 WHERE id=?").run(id);
    this.db.prepare('UPDATE credentials SET revoked=1 WHERE device_id=?').run(id);
    this.db.prepare("UPDATE grants SET status='revoked' WHERE device_id=?").run(id);
    this.db.prepare('DELETE FROM invitations WHERE device_id=?').run(id);
  }
  revokeCredential(token) {
    return this.transaction(() => {
      const row = this.db.prepare('SELECT * FROM credentials WHERE revocation_hash=?').get(digest(token));
      if (!row) fail(401, 'invalid_revocation');
      if (row.kind === 'host') this.revokeDevice(row.device_id);
      else {
        this.db.prepare('UPDATE credentials SET revoked=1 WHERE device_id=? AND phone_id=?').run(row.device_id, row.phone_id);
        this.db.prepare("UPDATE grants SET status='revoked' WHERE device_id=? AND phone_id=?").run(row.device_id, row.phone_id);
      }
    });
  }
  invite(deviceId) {
    const token = secret(); const expiresAt = this.now() + 300000;
    this.db.prepare('DELETE FROM invitations WHERE device_id=?').run(deviceId);
    this.db.prepare('INSERT INTO invitations VALUES (?,?,?,0)').run(digest(token), deviceId, expiresAt);
    return { invitation: token, expiresAt };
  }
  claimInvitation(invitation, publicKey) {
    return this.transaction(() => {
      const row = this.db.prepare('SELECT * FROM invitations WHERE hash=? AND used=0 AND expires_at>?').get(digest(invitation), this.now());
      if (!row) fail(410, 'invitation_expired');
      const device = this.device(row.device_id);
      if (device.status !== 'active' || this.user(device.account_id)?.status !== 'enabled') fail(403, 'device_revoked');
      const phone = this.db.prepare('SELECT * FROM phones WHERE public_key=?').get(publicKey);
      if (phone && phone.account_id !== device.account_id) fail(403, 'phone_account_conflict');
      this.db.prepare('UPDATE invitations SET used=1 WHERE hash=?').run(row.hash);
      const id = randomUUID(); const token = secret();
      this.db.prepare("INSERT INTO requests VALUES (?,'pairing',?,?,?,'pending',?,?)").run(id, digest(token), publicKey, JSON.stringify({ deviceId: device.id }), device.account_id, row.expires_at);
      return { id, token, device, accountId: device.account_id, instanceId: this.get('instanceId'), expiresAt: row.expires_at };
    });
  }
  approvePairing(deviceId, id, replace) {
    return this.transaction(() => {
      const request = this.request(id, 'pairing');
      if (request.payload.deviceId !== deviceId || request.status !== 'pending') fail(403, 'pairing_forbidden');
      const device = this.device(deviceId);
      if (device.status !== 'active' || request.account_id !== device.account_id) fail(403, 'device_revoked');
      const old = this.db.prepare("SELECT * FROM grants WHERE device_id=? AND status='active'").get(deviceId);
      if (old && replace !== true) fail(409, 'phone_replacement_required');
      let phone = this.db.prepare('SELECT * FROM phones WHERE public_key=?').get(request.public_key);
      if (phone && phone.account_id !== device.account_id) fail(403, 'phone_account_conflict');
      if (!phone) {
        phone = { id: randomUUID() };
        this.db.prepare("INSERT INTO phones VALUES (?,?,?,'active')").run(phone.id, device.account_id, request.public_key);
      } else this.db.prepare("UPDATE phones SET status='active' WHERE id=?").run(phone.id);
      this.db.prepare("UPDATE credentials SET revoked=1 WHERE device_id=? AND kind='phone'").run(deviceId);
      this.db.prepare("INSERT INTO grants VALUES (?,?,'active') ON CONFLICT(device_id) DO UPDATE SET phone_id=excluded.phone_id,status='active'").run(deviceId, phone.id);
      this.db.prepare("UPDATE requests SET status='approved',payload=? WHERE id=?").run(JSON.stringify({ deviceId, phoneId: phone.id }), id);
      this.audit(device.account_id, 'pairing.approved', deviceId);
    });
  }
  redeemPairing(id, token, publicKey) {
    return this.transaction(() => {
      const request = this.request(id, 'pairing');
      if (request.token_hash !== digest(token) || request.public_key !== publicKey) fail(401, 'invalid_device_proof');
      if (request.status !== 'approved') fail(409, request.status === 'pending' ? 'approval_pending' : 'request_consumed');
      const grant = this.db.prepare("SELECT * FROM grants WHERE device_id=? AND phone_id=? AND status='active'").get(request.payload.deviceId, request.payload.phoneId);
      if (!grant || this.user(request.account_id)?.status !== 'enabled' || this.device(grant.device_id).status !== 'active') fail(403, 'pairing_revoked');
      this.db.prepare("UPDATE requests SET status='redeemed' WHERE id=?").run(id);
      return this.credential('phone', grant.device_id, publicKey, grant.phone_id);
    });
  }
}

module.exports = { ControlStore, digest, secret, fail, requireValue };
