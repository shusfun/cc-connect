const { scrypt, randomBytes, timingSafeEqual } = require('node:crypto');
const { promisify } = require('node:util');
const derive = promisify(scrypt);
let active = 0;
function passwordError(status, code) { return Object.assign(new Error(code), { status, code }); }
function validatePassword(value) {
  if (typeof value !== 'string' || [...value].length < 6 || value.length > 1024 || !/[A-Z]/.test(value) || !/[a-z]/.test(value)) {
    throw passwordError(400, 'password_policy');
  }
}
async function boundedHash(value, salt) {
  if (active >= 4) throw passwordError(429, 'password_busy');
  active++;
  try { return await derive(value, salt, 64); } finally { active--; }
}
async function hashPassword(value) {
  validatePassword(value);
  const salt = randomBytes(32).toString('base64url');
  return `${salt}:${(await boundedHash(value, salt)).toString('hex')}`;
}
async function verifyPassword(value, encoded) {
  if (typeof value !== 'string' || value.length > 1024) return false;
  const [salt, expected] = (encoded || `${'0'.repeat(43)}:${'0'.repeat(128)}`).split(':');
  const actual = await boundedHash(value, salt);
  const bytes = Buffer.from(expected || '', 'hex');
  return bytes.length === actual.length && timingSafeEqual(bytes, actual) && !!encoded;
}
module.exports = { validatePassword, hashPassword, verifyPassword };
