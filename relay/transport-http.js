const { createSession } = require('better-sse');
const { fail } = require('./control-store');

const paths = new Set(['events', 'presence', 'connect', 'signal', 'session'].map(name => `/v1/access/${name}`));

function createTransportHTTP({ transport, deviceAuth }) {
  const buckets = new Map();
  return async function route(req, res) {
    const url = new URL(req.url, 'http://localhost');
    if (!paths.has(url.pathname)) return false;
    try {
      if (url.search) fail(400, 'invalid_request');
      if (req.method !== (url.pathname.endsWith('/events') ? 'GET' : 'POST')) fail(405, 'method_not_allowed');
      let raw = '';
      const chunks = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 70_000) fail(413, 'body_too_large');
        chunks.push(chunk);
      }
      raw = Buffer.concat(chunks).toString('utf8');
      const access = deviceAuth(req, raw);
      for (const [key, value] of buckets) if (value.until <= transport.now()) buckets.delete(key);
      const key = `${access.kind}:${access.phone_id || access.device_id}`;
      if (!buckets.has(key)) {
        if (buckets.size >= 2000) fail(503, 'transport_capacity');
        buckets.set(key, { until: transport.now() + 60_000, count: 0 });
      }
      const bucket = buckets.get(key);
      if (++bucket.count > 300) {
        res.setHeader('retry-after', String(Math.max(1, Math.ceil((bucket.until - transport.now()) / 1000))));
        fail(429, 'rate_limited');
      }
      transport.requireAvailable();
      if (url.pathname.endsWith('/events')) {
        let send;
        let closed = false;
        const pending = [];
        const detach = transport.attach(access, req.headers.authorization.slice(7), (event, data) => {
          if (closed || res.writableLength > 262_144) throw new Error('slow_consumer');
          if (send) send(event, data);
          else { if (pending.length >= 16) throw new Error('slow_consumer'); pending.push([event, data]); }
        }, () => { closed = true; res.end(); });
        res.once('close', detach);
        try {
          const session = await createSession(req, res, { retry: 1000, keepAlive: 20_000, headers: { 'x-accel-buffering': 'no', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } });
          send = (event, data) => session.push(data, event);
          for (const [event, data] of pending) if (!closed) send(event, data);
        } catch (error) { detach(); throw error; }
        return true;
      }
      let body;
      try { body = raw ? JSON.parse(raw) : {}; } catch { fail(400, 'invalid_json'); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) fail(400, 'invalid_request');
      const operation = url.pathname.split('/').at(-1);
      const result = operation === 'session' ? transport.resolve(access) : transport[operation](access, body);
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify(result));
    } catch (error) {
      if (res.headersSent) { res.destroy(); return true; }
      res.writeHead(error.status || 500, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ code: error.status ? error.code : 'internal_error' }));
    }
    return true;
  };
}

module.exports = { createTransportHTTP };
