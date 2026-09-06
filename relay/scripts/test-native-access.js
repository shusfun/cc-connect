const assert = require('node:assert/strict');
const { generateKeyPairSync, randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const http = require('node:http');
const { verifyRequest } = require('@remodex/protocol');

async function main() {
  assert.ok(process.argv[2], '需要原生 HTTP 测试程序');
  const key = generateKeyPairSync('ed25519').privateKey.export({ format: 'jwk' });
  const publicKey = Buffer.from(key.x, 'base64url').toString('base64');
  const token = randomBytes(32).toString('base64url');
  const nonces = new Set();
  let redirects = 0, subscriptions = 0, active = 0, initialAt = 0, oversized = false;
  let failure;
  const server = http.createServer(async (request, response) => {
    try {
      if (request.url === '/leak') { redirects++; response.end(); return; }
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const raw = Buffer.concat(chunks).toString();
      const proof = verifyRequest(request, raw, token, publicKey);
      assert.equal(nonces.has(proof.nonce), false);
      nonces.add(proof.nonce);
      const mode = raw ? JSON.parse(raw).mode : '';
      if (request.url === '/v1/access/events') {
        if (oversized) { response.writeHead(200, { 'content-type': 'text/event-stream' }); response.end(`data:${'x'.repeat(80_000)}`); return; }
        if (++subscriptions === 1) {
          initialAt = Date.now();
          response.writeHead(429, { 'content-type': 'application/json', 'retry-after': '2' }); response.end('{"code":"rate_limited"}'); return;
        }
        assert.ok(Date.now() - initialAt >= 1900);
        response.writeHead(200, { 'content-type': 'text/event-stream' });
        active++;
        response.once('close', () => active--);
        response.write('event: snapshot\ndata: {}\n\n');
      } else if (mode === 'redirect') { response.writeHead(302, { location: '/leak' }); response.end(); }
      else if (mode === 'revoke') { response.writeHead(401, { 'content-type': 'application/json' }); response.end('{"code":"credential_revoked"}'); }
      else if (mode === 'oversized') { response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify({ value: 'x'.repeat(80_000) })); }
      else if (mode === 'wrong-mime') { response.writeHead(200, { 'content-type': 'text/html' }); response.end('{}'); }
      else if (mode === 'retry-date') { response.writeHead(429, { 'content-type': 'application/json', 'retry-after': new Date(Date.now() + 3000).toUTCString() }); response.end('{"code":"rate_limited"}'); }
      else { oversized = true; response.writeHead(200, { 'content-type': 'application/json' }); response.end('{}'); }
    } catch (error) { failure = error; response.destroy(); }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const child = spawn(process.argv[2], [], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', chunk => { if (output.length < 1000) output += chunk; });
  child.stderr.resume();
  child.stdin.on('error', () => {});
  child.stdin.end(JSON.stringify({ origin: `http://127.0.0.1:${server.address().port}`, token, privateKey: Buffer.from(key.d, 'base64url').toString('base64') }) + '\n');
  const timer = setTimeout(() => child.kill('SIGTERM'), 30_000);
  try {
    const [code] = await once(child, 'exit');
    assert.equal(failure, undefined);
    assert.equal(code, 0);
    assert.equal(redirects, 0);
    assert.equal(active, 0);
    assert.equal(subscriptions, 2);
    assert.match(output, /native_access_signature_retry_after_redirect_size_and_cancel_passed/);
    console.log('native_access_signature_retry_after_redirect_size_and_cancel_passed');
  } finally { clearTimeout(timer); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
