const { randomUUID } = require('node:crypto');
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
const routes = new Set(['status','me','setup','login','logout','review','activation','activation/approve','device/remark','device/revoke','github/start','github/callback','users','devices',
  ...['profile','sessions','overview','accounts','device-list','phones','audit','settings','updates','backups','password','reauth','session/revoke','phone/revoke','pairing/revoke','settings/stage','updates/check','updates/install','backups/create','backups/restore'].map(s=>`manage/${s}`),
  ...['activation/start','activation/redeem','device','device/remark','device/logout','pairing/invite','pairing/preview','pairing/claim','pairing/redeem','pairing/pending','pairing/approve','session'].map(s=>`access/${s}`)]);
function beginDiagnostic(req, res, pathname) {
  if (req.remodexDiagnostic) return req.remodexDiagnostic;
  const name = pathname.startsWith('/v1/access/') ? `access/${pathname.slice(11)}` : pathname.slice('/v1/control/'.length);
  const diagnostic = { requestId: randomUUID(), operationId: uuid.test(req.headers['x-remodex-operation-id'] || '') ? req.headers['x-remodex-operation-id'] : null,
    route: routes.has(name) ? name : 'unknown', stage: 'authorization', code: null };
  req.remodexDiagnostic = diagnostic;
  res.setHeader('x-remodex-request-id', diagnostic.requestId);
  return diagnostic;
}
module.exports = { beginDiagnostic };
