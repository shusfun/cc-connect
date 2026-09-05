const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const version = '0.5.0-alpha.2';

// 在隔离目录运行真实发布入口；假制品仅测试发布拒绝规则，不代表平台构建通过。
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'remodex-publication-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const directory of ['build/release-clients', 'relay', 'deploy', 'Docs', 'packages/updater']) fs.mkdirSync(path.join(root, directory), { recursive: true });
  // 源码版本也是输入夹具；将来 main 升为正式版本时仍须运行 alpha 拒绝测试。
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ version }));
  for (const script of ['publish-prerelease.js', 'publication-contract.js', 'releases.js']) fs.copyFileSync(path.join(__dirname, script), path.join(root, 'packages/updater', script));
  for (const file of ['relay/compose.yaml', 'deploy/remodex.sh', 'Docs/PRERELEASE-INSTALL.md']) fs.writeFileSync(path.join(root, file), 'test fixture');
  const names = ['unsigned.ipa', 'x86_64-Debug.dmg', 'arm64-Debug.dmg', 'win-x64.exe'].map(suffix => `Remodex-${version}-${suffix}`);
  for (const name of names) fs.writeFileSync(path.join(root, 'build/release-clients', name), `fixture:${name}`);
  const run = (extra = {}) => spawnSync(process.execPath, [path.join(root, 'packages/updater/publish-prerelease.js')], {
    cwd: root, encoding: 'utf8', env: { ...process.env, GITHUB_REF_NAME: `v${version}`, GITHUB_SHA: 'a'.repeat(40), RELAY_DIGEST: `sha256:${'b'.repeat(64)}`, UPDATER_DIGEST: `sha256:${'c'.repeat(64)}`, ...extra }
  });
  return { root, names, run };
}

test('预发布独立清单记录真实文件摘要，不能生成正式更新清单', t => {
  const { root, run } = fixture(t);
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  const directory = path.join(root, 'build/release');
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'remodex-prerelease.json')));
  assert.equal(manifest.automaticUpdateEligible, false);
  assert.equal(manifest.sourceSHA, 'a'.repeat(40));
  assert.equal(fs.existsSync(path.join(directory, 'remodex-release.json')), false);
  for (const [name, asset] of Object.entries(manifest.assets)) {
    assert.equal(asset.sha256, createHash('sha256').update(fs.readFileSync(path.join(directory, name))).digest('hex'));
  }
});

for (const fault of ['missing', 'duplicate', 'version', 'digest']) {
  test(`预发布拒绝 ${fault} 制品输入`, t => {
    const { root, names, run } = fixture(t);
    const directory = path.join(root, 'build/release-clients');
    if (fault === 'missing') fs.unlinkSync(path.join(directory, names[0]));
    if (fault === 'duplicate') fs.copyFileSync(path.join(directory, names[0]), path.join(directory, `duplicate-${names[0]}`));
    if (fault === 'version') fs.renameSync(path.join(directory, names[0]), path.join(directory, 'Remodex-0.0.0-unsigned.ipa'));
    const result = run(fault === 'digest' ? { RELAY_DIGEST: 'latest' } : {});
    assert.notEqual(result.status, 0);
    const code = fault === 'digest' ? 'prerelease_image_digest_missing' : fault === 'version' ? 'client_artifact_version_mismatch' : 'client_artifact_missing_or_duplicate';
    assert.ok(result.stderr.includes(code), result.stderr);
    assert.equal(fs.existsSync(path.join(root, 'build/release/remodex-prerelease.json')), false);
  });
}
