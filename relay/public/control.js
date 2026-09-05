const content = document.querySelector('#content');
const notice = document.querySelector('#notice');
let csrf = '';
const labels = { pending: '待审核', enabled: '已启用', rejected: '已拒绝', disabled: '已停用', active: '已激活', revoked: '已撤销', macos: 'macOS', windows: 'Windows' };
const errors = { login_required: '请先登录。', login_failed: '账号或密码不正确。', setup_token_invalid: '安装凭据不正确。', password_too_short: '管理员密码至少需要 14 个字符。', revision_conflict: '备注已被其他客户端修改，请刷新后重试。', account_not_enabled: '账号尚未审核通过。', csrf_failed: '登录状态已变化，请刷新页面。', github_unavailable: 'GitHub 暂时不可用，请稍后重试。', device_limit_reached: '已达到账号设备上限。', device_owned_by_other_account: '设备仍属于其他账号，请先解除原归属。' };
function element(tag, text, parent = content) { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; parent.append(node); return node; }
function button(text, action, parent) { const node = element('button', text, parent); node.type = 'button'; node.onclick = async () => { node.disabled = true; notice.textContent = ''; try { await action(); } catch (error) { notice.textContent = error.message; } finally { node.disabled = false; } }; return node; }
function input(form, label, name, type = 'text', value = '') { const caption = element('label', label, form); const field = element('input', undefined, form); field.id = name; field.name = name; field.type = type; field.value = value; caption.htmlFor = name; field.required = true; return field; }
async function api(path, body, headers = {}) {
  const response = await fetch(`/v1/control/${path}`, { method: body === undefined ? 'GET' : 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrf, ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = await response.json(); if (!response.ok) { const error = new Error(errors[data.code] || `操作未完成（${data.code || response.status}）`); error.code = data.code; throw error; } return data;
}
function section(title) { const root = element('section'); element('h2', title, root); return root; }
function github(parent) { const link = element('a', '使用 GitHub 登录', parent); link.href = '/v1/control/github/start'; link.className = 'action'; }
async function render() {
  content.replaceChildren();
  const status = await api('status');
  if (!status.configured) {
    const root = section('首次初始化');
    element('p', '容器已启动。请使用安装脚本给出的单次凭据创建管理员，并配置 GitHub 登录。随后必须绑定管理员的 GitHub 身份才能启用设备激活。', root);
    const form = element('form', undefined, root);
    const fields = { setupToken: input(form, '单次安装凭据', 'setupToken', 'password'), login: input(form, '管理员账号', 'login'), password: input(form, '管理员密码（至少 14 字符）', 'password', 'password'), origin: input(form, 'HTTPS 服务地址', 'origin', 'url', location.origin), githubClientId: input(form, 'GitHub OAuth Client ID', 'githubClientId'), githubClientSecret: input(form, 'GitHub OAuth Client Secret', 'githubClientSecret', 'password') };
    element('p', `GitHub OAuth 回调地址：${location.origin}/v1/control/github/callback`, root);
    button('创建管理员并继续', async () => { if (!form.reportValidity()) return; const body = Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, value.value])); const token = body.setupToken; delete body.setupToken; const result = await api('setup', body, { 'x-setup-token': token }); csrf = result.csrf; await render(); }, form);
    form.onsubmit = event => event.preventDefault(); return;
  }
  let identity;
  try { identity = await api('me'); } catch (error) { if (error.code !== 'login_required' && error.code !== 'account_disabled') throw error; }
  if (!identity) {
    const root = section('登录 Remodex'); github(root);
    element('p', '普通用户通过 GitHub 登录后提交账号申请；管理员审核通过后才能激活电脑。', root);
    const form = element('form', undefined, root); const login = input(form, '本地管理员账号', 'login'); const password = input(form, '管理员密码', 'password', 'password');
    button('管理员密码登录', async () => { const result = await api('login', { login: login.value, password: password.value }); csrf = result.csrf; await render(); }, form);
    form.onsubmit = event => event.preventDefault(); return;
  }
  csrf = identity.csrf; const user = identity.user;
  const logout = document.querySelector('#logout'); logout.hidden = false; logout.onclick = async () => { try { await api('logout', {}); logout.hidden = true; await render(); } catch (error) { notice.textContent = error.message; } };
  const summary = section(`${user.login} · ${labels[user.status]}`);
  if (!status.complete) { element('p', '最后一步：绑定管理员 GitHub 身份。此操作不会授予仓库访问权限。', summary); github(summary); return; }
  if (user.status !== 'enabled') { element('p', '申请已记录。请等待管理员审核；本页面不会自动授予设备激活权限。', summary); button('刷新审核状态', render, summary); return; }
  const activationId = new URL(location.href).searchParams.get('activation') || sessionStorage.getItem('activation');
  if (activationId) {
    sessionStorage.setItem('activation', activationId);
    const request = await api(`activation?id=${encodeURIComponent(activationId)}`);
    const root = section('确认激活设备'); element('p', `${request.systemName} · ${labels[request.platform]}`, root);
    element('p', `请核对电脑上显示的核对码：${request.code}`, root); element('code', request.publicKey, root);
    button('确认是我的设备，批准激活', async () => { await api('activation/approve', { id: request.id }); sessionStorage.removeItem('activation'); history.replaceState(null, '', '/'); notice.textContent = '已批准，请返回电脑完成激活。'; await render(); }, root);
  }
  if (user.role === 'admin') {
    const root = section('账号审核'); const users = await api('users');
    for (const account of users.filter(item => item.role !== 'admin')) {
      const row = element('div', undefined, root); row.className = 'row'; element('strong', `${account.login} · ${labels[account.status]}`, row);
      const limit = input(row, '设备上限（留空表示不限）', `limit-${account.id}`, 'number', account.device_limit ?? ''); limit.required = false; limit.min = '0';
      for (const [status, text] of [['enabled','批准／启用'],['rejected','拒绝'],['disabled','停用并撤销设备']]) button(text, async () => { if (status === 'disabled' && !confirm('停用后会撤销该账号所有设备和配对，重新启用不会自动恢复。确定继续？')) return; await api('review', { userId: account.id, status, deviceLimit: limit.value === '' ? null : Number(limit.value) }); await render(); }, row);
    }
  }
  const root = section('设备'); const devices = await api('devices');
  if (!devices.length) element('p', '暂无设备。请在 macOS 或 Windows Remodex 中发起激活。', root);
  for (const device of devices) {
    const row = element('div', undefined, root); row.className = 'row'; element('strong', `${device.remark} · ${labels[device.platform]} · ${labels[device.status]}`, row);
    element('p', `系统名称：${device.system_name}`, row); const remark = input(row, '设备备注', `remark-${device.id}`, 'text', device.remark);
    button('保存备注', async () => { await api('device/remark', { deviceId: device.id, remark: remark.value, revision: device.revision }); await render(); }, row);
    if (device.status === 'active') button('撤销设备', async () => { if (!confirm('将断开这台设备并撤销配对，不删除本机项目。确定继续？')) return; await api('device/revoke', { deviceId: device.id }); await render(); }, row);
  }
  const help = section('连接客户端'); element('p', '电脑激活后显示限时二维码，iPhone 扫码并由电脑确认。手机无需 GitHub 登录。切换设备不会停止另一台电脑的任务。', help);
  element('code', identity.origin.replace(/^https:/, 'wss:'), help);
}
const activation = new URL(location.href).searchParams.get('activation'); if (activation) sessionStorage.setItem('activation', activation);
render().catch(error => { notice.textContent = error.message; });
