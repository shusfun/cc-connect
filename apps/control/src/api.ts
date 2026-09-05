export type Row = Record<string, any>;
let csrf = '';
export function setCSRF(value: string) { csrf = value; }
const messages: Record<string, string> = {
  login_required: '登录已过期，请重新登录。', login_failed: '账号或密码不正确。', password_policy: '密码至少 6 位，包含大写和小写英文字母。', password_busy: '密码验证繁忙，请稍后重试。',
  admin_required: '此操作仅限管理员。', csrf_failed: '会话状态已变化，请刷新后重试。', revision_conflict: '内容已被修改，请刷新后重新确认。', account_not_enabled: '账号尚未启用，请等待审核。',
  reauth_required: '请先在本页重新验证管理员密码，有效期五分钟。', updater_unavailable: '更新执行器未连接；当前服务没有被修改。', rate_limited: '请求过于频繁，请稍后重试。',
  setup_token_invalid: '单次安装凭据不正确。', device_forbidden: '你无权管理此设备。', github_unavailable: 'GitHub 暂时不可用，请稍后重试。', maintenance: '服务正在维护，请稍后重试。',
  request_expired: '激活申请已过期，请回到电脑重新发起。', request_consumed: '此申请已处理，正在核对最终状态。', device_limit_reached: '账号设备数量已达上限，请联系管理员调整。', device_owned_by_other_account: '这台设备属于其他账号，请先由原账号释放。', request_timeout: '连接超时，请核对操作状态后重试。', network_failed: '网络连接失败，请检查网络后重试。',
  configuration_expired: '配置验证已过期，请重新提交。', setup_closed: '初始化已经完成，请登录。', no_stable_release: '暂无可用正式版本。', release_untrusted: '发布身份验证失败，已阻止更新。'
  ,update_busy:'已有更新或恢复任务正在处理。', release_changed:'可用版本已变化，请重新检查后确认。', release_incompatible:'版本或更新执行器协议不兼容，请由管理员使用管理脚本处理。', insufficient_space:'剩余空间不足，未执行更新。', github_rate_limited:'GitHub 限流，请稍后检查。', backup_incompatible:'备份实例或数据库版本不兼容。', backup_version_mismatch:'历史备份版本与当前服务不一致，不能直接恢复。'
};
export async function api(path: string, body?: Row, signal?: AbortSignal, headers?: Record<string, string>, operationId?: string): Promise<any> {
  const timeout = AbortSignal.timeout(20000);
  let response: Response;
  try { response = await fetch(`/v1/control/${path}`, { method: body ? 'POST' : 'GET', credentials: 'same-origin', signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    headers: { 'Content-Type': 'application/json', ...(body ? { 'x-csrf-token': csrf } : {}), ...(operationId || body ? { 'x-remodex-operation-id': operationId || crypto.randomUUID() } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
  } catch (error) { if (signal?.aborted) throw error; const code = timeout.aborted ? 'request_timeout' : 'network_failed'; throw Object.assign(new Error(messages[code]), { code }); }
  const value = await response.json();
  if (!response.ok) { const requestId = response.headers.get('x-remodex-request-id'); throw Object.assign(new Error((messages[value.code] || `操作未完成（${value.code || response.status}）`) + (requestId ? ` 诊断编号：${requestId}` : '')), { code: value.code, requestId }); }
  return value;
}
export function date(value: number | string | undefined) { return value ? new Date(value).toLocaleString('zh-CN') : '暂无记录'; }
export function label(value: unknown): string {
  const labels: Record<string,string> = { pending: '待审核', enabled: '已启用', rejected: '已拒绝', disabled: '已停用', active: '有效', revoked: '已撤销', admin: '管理员', user: '用户', macos: 'macOS', windows: 'Windows', idle: '空闲', checking: '检查中', failed: '失败', complete: '已完成', rolled_back: '已回滚', recovery_failed: '恢复失败', stable: '正式版', ok: '正常' };
  return labels[String(value)] || String(value ?? '—');
}
