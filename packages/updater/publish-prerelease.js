// 测试发布单元与正式自动更新清单分离；本脚本不能生成 remodex-release.json。
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { publicationContract } = require('./publication-contract');
const { version, prerelease } = publicationContract(process.env.GITHUB_REF_NAME, require('../../package.json').version);
if (!prerelease || !/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA || '')) throw new Error('prerelease_identity_invalid');
const images = {};
for (const component of ['relay', 'updater']) {
  const digest = process.env[`${component.toUpperCase()}_DIGEST`];
  if (!/^sha256:[a-f0-9]{64}$/.test(digest || '')) throw new Error('prerelease_image_digest_missing');
  images[component] = { architectures: ['linux/amd64', 'linux/arm64'], index: `ghcr.io/shusfun/cc-connect-${component}@${digest}` };
}
const dir = 'build/release';
fs.mkdirSync(dir, { recursive: true });
const names = fs.readdirSync('build/release-clients', { recursive: true }).filter(name => /\.(ipa|dmg|exe)$/.test(name));
for (const suffix of ['unsigned.ipa', 'x86_64-Debug.dmg', 'arm64-Debug.dmg', '.exe']) {
  if (names.filter(name => name.endsWith(suffix)).length !== 1) throw new Error('client_artifact_missing_or_duplicate');
}
for (const name of names) {
  if (!path.basename(name).includes(version)) throw new Error('client_artifact_version_mismatch');
  fs.copyFileSync(path.join('build/release-clients', name), path.join(dir, path.basename(name)));
}
fs.copyFileSync('relay/compose.yaml', `${dir}/compose.yaml`);
fs.copyFileSync('deploy/remodex.sh', `${dir}/remodex.sh`);
// 预发布不提供伪装为已通过正式签名校验的一键安装脚本。
fs.copyFileSync('Docs/PRERELEASE-INSTALL.md', `${dir}/INSTALL-TEST.md`);
const sha = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const assets = Object.fromEntries(fs.readdirSync(dir).map(name => [name, { sha256: sha(path.join(dir, name)), bytes: fs.statSync(path.join(dir, name)).size }]));
fs.writeFileSync(`${dir}/remodex-prerelease.json`, JSON.stringify({ repository: 'shusfun/cc-connect', version, sourceSHA: process.env.GITHUB_SHA, channel: 'alpha', automaticUpdateEligible: false, images, assets }, null, 2));
fs.writeFileSync(`${dir}/SHA256SUMS`, fs.readdirSync(dir).sort().map(name => `${sha(path.join(dir, name))}  ${name}`).join('\n') + '\n');
