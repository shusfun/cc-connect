const fs = require('node:fs');

// 正式更新由发布签名验证约束；既有测试部署的回滚点可使用不可变本地镜像 ID。
function persistImage(image, file = '/deployment/.env') {
  if (!/^(?:ghcr\.io\/shusfun\/cc-connect-relay@)?sha256:[a-f0-9]{64}$/.test(image)) {
    throw new Error('deployment_image_invalid');
  }
  const text = fs.readFileSync(file, 'utf8');
  if (!/^REMODEX_IMAGE=.+$/m.test(text)) throw new Error('deployment_configuration_invalid');
  fs.writeFileSync(`${file}.tmp`, text.replace(/^REMODEX_IMAGE=.+$/m, `REMODEX_IMAGE=${image}`), { mode: 0o600, flush: true });
  fs.renameSync(`${file}.tmp`, file);
}

module.exports = { persistImage };
