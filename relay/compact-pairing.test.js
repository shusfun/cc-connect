const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { ControlStore } = require('./control-store');
const { createControlHTTP } = require('./control-http');
const http = require('node:http');
async function fixture(t) {
  let now = Date.now();
  const store = new ControlStore({ filename: ':memory:', masterKey: randomBytes(32), now: () => now }); t.after(() => store.close());
  const owner = await store.setup({login:'owner',password:'Abcdef',origin:'https://example.test',githubClientId:'fixture',githubClientSecret:'fixture-secret'});
  store.githubUser({id:1,login:'owner'},owner.id);
  const key = randomBytes(32).toString('base64'); const pending = store.startActivation({publicKey:key,platform:'macos',systemName:'设备'});
  store.approveActivation(owner,pending.id); const credential=store.redeemActivation(pending.id,pending.token,key);
  return {store,owner,credential,key,advance:ms=>now+=ms};
}
test('预览无写入，失效与撤销关闭入口，邀请仅可消费一次', async t => {
  const f=await fixture(t), invite=f.store.invite(f.credential.deviceId);
  const before=f.store.db.prepare('SELECT total_changes() n').get().n;
  for(let i=0;i<10;i++) { const p=f.store.previewInvitation(invite.invitation); assert.equal(p.device.public_key,f.key); assert.equal(p.expiresAt-p.serverTime,300000); }
  assert.equal(f.store.db.prepare('SELECT total_changes() n').get().n,before);
  f.store.claimInvitation(invite.invitation,randomBytes(32).toString('base64'));
  assert.throws(()=>f.store.previewInvitation(invite.invitation),{code:'invitation_expired'});
  assert.throws(()=>f.store.claimInvitation(invite.invitation,randomBytes(32).toString('base64')),{code:'invitation_expired'});
  const next=f.store.invite(f.credential.deviceId); f.advance(300001);
  assert.throws(()=>f.store.previewInvitation(next.invitation),{code:'invitation_expired'});
  const revoked=f.store.invite(f.credential.deviceId); f.store.revokeDevice(f.credential.deviceId);
  assert.throws(()=>f.store.previewInvitation(revoked.invitation));
  assert.throws(()=>f.store.invite(f.credential.deviceId),{code:'device_revoked'});
});
test('预览 HTTP 禁止缓存、有诊断编号、限流且不输出邀请', async t => {
  const f=await fixture(t), invite=f.store.invite(f.credential.deviceId), logs=[];
  const control=createControlHTTP({store:f.store,setupToken:'x'.repeat(43),logger:row=>logs.push(row)});
  const server=http.createServer((req,res)=>control.route(req,res)); await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>server.close(r)));
  const url=`http://127.0.0.1:${server.address().port}/v1/access/pairing/preview`;
  const request=()=>fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({invitation:invite.invitation})});
  let response=await request(); assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');assert.ok(response.headers.get('x-remodex-request-id')); await response.arrayBuffer();
  for(let i=0;i<60;i++){response=await request();await response.arrayBuffer();}
  assert.equal(response.status,429);assert.ok(response.headers.get('retry-after'));
  const text=JSON.stringify(logs);assert.equal(text.includes(invite.invitation),false);assert.equal(text.includes(f.key),false);
});
