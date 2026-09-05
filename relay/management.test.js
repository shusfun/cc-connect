const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes, scryptSync } = require('node:crypto');
const { ControlStore } = require('./control-store');
const { management } = require('./management');
const { validatePassword } = require('./password');
async function fixture(t) {
  const store = new ControlStore({ filename: ':memory:', masterKey: randomBytes(32) }); t.after(() => store.close());
  const user = await store.setup({ login: 'owner', password: 'Abcdef', githubClientId: 'client', githubClientSecret: 'secret', origin: 'https://example.test' });
  store.githubUser({ id: 1, login: 'owner' }, user.id);
  const api = management(store), token = store.session(user.id).token;
  return { store, user, api, session: store.browser(token), token };
}
test('password policy allows six mixed-case letters and optional punctuation', () => {
  for (const value of ['Abcdef','aBCDEF123!']) assert.doesNotThrow(() => validatePassword(value));
  for (const value of ['abcdeF'.slice(1),'abcdef','ABCDEF','123456',null]) assert.throws(() => validatePassword(value), { code: 'password_policy' });
});
test('password change revokes every browser session but does not alter devices', async t => {
  const { store, user, api, session, token } = await fixture(t), second = store.session(user.id).token;
  const req = store.startActivation({ publicKey: randomBytes(32).toString('base64'), platform: 'macos', systemName: '测试' });
  const device = store.approveActivation(user, req.id);
  await assert.rejects(api.post('password', session, { oldPassword: 'wrong', newPassword: 'Xyzabc' }), { code: 'login_failed' });
  await api.post('password', session, { oldPassword: 'Abcdef', newPassword: 'Xyzabc' });
  for (const value of [token, second]) assert.throws(() => store.browser(value), { code: 'login_required' });
  assert.equal((await store.passwordLogin('owner','Xyzabc')).id, user.id);
  assert.equal(store.device(device.id).status, 'active');
});
test('legacy passwords remain usable without applying new policy at login', async t => {
  const { store, user } = await fixture(t); const salt = 'legacy-salt';
  store.db.prepare('UPDATE users SET password=? WHERE id=?').run(`${salt}:${scryptSync('old-lowercase-only',salt,64).toString('hex')}`,user.id);
  assert.equal((await store.passwordLogin('owner','old-lowercase-only')).id,user.id);
});
test('pending users cannot enumerate business data or enter admin routes', async t => {
  const { store, api } = await fixture(t); const user = store.githubUser({ id: 2, login: 'pending' }); const session = store.browser(store.session(user.id).token);
  for (const name of ['overview','device-list','phones','accounts','audit','settings']) await assert.rejects(api.get(name,session,new URLSearchParams()), { code:'account_not_enabled' });
  assert.equal((await api.get('profile',session,new URLSearchParams())).canChangePassword,false);
});
test('account list pagination returns totals instead of silently truncating', async t => {
  const { api, session, store } = await fixture(t);
  for (let id=2;id<26;id++) store.githubUser({ id, login:`person${id}` });
  const result = await api.get('accounts',session,new URLSearchParams('page=2&size=10'));
  assert.equal(result.total,25); assert.equal(result.items.length,10);
  await assert.rejects(api.get('accounts',session,new URLSearchParams('size=999')), {code:'invalid_page'});
});
test('configuration requires fresh authentication and does not publish unverified credentials', async t => {
  const { api, session, store } = await fixture(t);
  const body = { revision:1, origin:'https://next.example.test',githubClientId:'next',githubClientSecret:'new-secret' };
  await assert.rejects(api.post('settings/stage',session,body),{code:'reauth_required'});
  await api.post('reauth',session,{password:'Abcdef'});
  await api.post('settings/stage',session,body);
  assert.equal(store.get('githubClientId'),'client');
  const visible = await api.get('settings',session,new URLSearchParams());
  assert.equal(JSON.stringify(visible).includes('new-secret'),false);
});
