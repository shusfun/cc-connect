const { test } = require('node:test');
const assert = require('node:assert/strict');
const { candidateManifest } = require('./build-candidate-manifest');
const input = { sourceSHA: 'a'.repeat(40), version: '0.5.0-alpha.2', relayDigest: `sha256:${'b'.repeat(64)}`, updaterDigest: `sha256:${'c'.repeat(64)}` };
test('候选清单明确未认证且不能进入正式更新渠道', () => {
  const manifest = candidateManifest(input);
  assert.equal(manifest.automaticUpdateEligible, false);
  assert.equal(manifest.channel, 'candidate');
  assert.equal(manifest.clientValidation, 'not-certified');
  assert.equal(manifest.sourceSHA, input.sourceSHA);
  assert.equal(manifest.images.relay.index, `ghcr.io/shusfun/cc-connect-relay@${input.relayDigest}`);
  assert.deepEqual(manifest.images.updater.architectures, ['linux/amd64', 'linux/arm64']);
});
test('候选清单拒绝缺失身份、任意镜像和无效摘要', () => {
  for (const key of Object.keys(input)) assert.throws(() => candidateManifest({ ...input, [key]: '' }));
  assert.throws(() => candidateManifest({ ...input, relayDigest: 'evil.example/relay:latest' }));
});
