const { readFileSync } = require('node:fs');
const { ControlStore, fail } = require('./control-store');
const { createControlHTTP } = require('./control-http');

function createProductionAccess({ store, setupToken, fetchImpl, env = process.env } = {}) {
  const ownsStore = !store;
  if (!store) {
    if (!env.REMODEX_MASTER_KEY_FILE || !env.REMODEX_SETUP_TOKEN_FILE || !env.REMODEX_DATABASE) throw new Error('control_configuration_required');
    store = new ControlStore({ filename: env.REMODEX_DATABASE, masterKey: Buffer.from(readFileSync(env.REMODEX_MASTER_KEY_FILE, 'utf8').trim(), 'hex') });
    setupToken = readFileSync(env.REMODEX_SETUP_TOKEN_FILE, 'utf8').trim();
  }
  if (typeof setupToken !== 'string' || setupToken.length < 32) throw new Error('setup_token_required');
  const connections = new Set();
  const hosts = new Map();
  const phones = new Map();
  function revokeConnections() {
    for (const connection of connections) {
      try { store.authorize(connection.token); }
      catch { connection.ws.close(4003, 'access_revoked'); }
    }
  }
  const control = createControlHTTP({ store, setupToken, fetchImpl, onRevoked: revokeConnections });
  const sweep = setInterval(revokeConnections, 1000); sweep.unref();
  return {
    store,
    async route(req, res) {
      if (new URL(req.url, 'http://localhost').pathname === '/v1/access/session' && req.method === 'POST') {
        try {
          const chunks = []; let size = 0;
          for await (const chunk of req) { size += chunk.length; if (size > 1024) fail(413, 'body_too_large'); chunks.push(chunk); }
          const access = control.deviceAuth(req, Buffer.concat(chunks).toString('utf8'));
          if (access.kind !== 'phone') fail(403, 'phone_required');
          const host = hosts.get(access.device_id);
          if (!host || host.ws.readyState !== 1) fail(404, 'device_offline');
          res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
          res.end(JSON.stringify({ sessionId: host.sessionId, device: access.device, accountId: access.user.id, instanceId: store.get('instanceId') }));
        } catch (error) { res.writeHead(error.status || 500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ code: error.status ? error.code : 'internal_error' })); }
        return true;
      }
      return control.route(req, res);
    },
    authorizeUpgrade(req) {
      const access = control.deviceAuth(req);
      const pathname = new URL(req.url, 'http://localhost').pathname;
      const match = /^\/relay\/([a-zA-Z0-9-]{1,100})$/.exec(pathname);
      if (!match) fail(400, 'invalid_session');
      const sessionId = match[1];
      if (access.kind === 'phone') {
        const host = hosts.get(access.device_id);
        if (!host || host.sessionId !== sessionId || host.ws.readyState !== 1) fail(403, 'session_forbidden');
        req.headers['x-role'] = 'iphone';
      } else {
        for (const [deviceId, existing] of hosts) if (existing.sessionId === sessionId && deviceId !== access.device_id) fail(403, 'session_forbidden');
        req.headers['x-role'] = 'mac';
        req.headers['x-mac-device-id'] = access.device_id;
        req.headers['x-mac-identity-public-key'] = access.public_key;
        req.headers['x-machine-name'] = access.device.remark;
      }
      return { ...access, sessionId };
    },
    attach(ws, req) {
      const access = req.remodexAccess;
      const connection = { ws, token: req.headers.authorization.slice(7), sessionId: access.sessionId, deviceId: access.device_id, phoneId: access.phone_id };
      connections.add(connection);
      if (access.kind === 'host') {
        const previous = hosts.get(access.device_id);
        if (previous && previous.ws !== ws) previous.ws.close(4001, 'host_replaced');
        hosts.set(access.device_id, connection);
        store.db.prepare('UPDATE devices SET last_seen=? WHERE id=?').run(store.now(), access.device_id);
      } else {
        const previous = phones.get(access.phone_id);
        if (previous && previous.ws !== ws) previous.ws.close(4001, 'active_device_changed');
        phones.set(access.phone_id, connection);
      }
      ws.on('close', () => {
        connections.delete(connection);
        if (hosts.get(access.device_id) === connection) hosts.delete(access.device_id);
        if (phones.get(access.phone_id) === connection) phones.delete(access.phone_id);
      });
    },
    close() { clearInterval(sweep); for (const connection of connections) connection.ws.close(1001, 'server_shutdown'); if (ownsStore) store.close(); },
  };
}
module.exports = { createProductionAccess };
