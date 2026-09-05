const test = require('node:test');
const assert = require('node:assert/strict');
const { publicationContract } = require('./publication-contract');
const { stable, validateManifest } = require('./releases');
test('预发布必须匹配源码版本，且不能被正式更新契约接受', () => {
  assert.deepEqual(publicationContract('v0.5.0-alpha.2', '0.5.0-alpha.2'), { version: '0.5.0-alpha.2', prerelease: true });
  assert.equal(stable('v0.5.0-alpha.2'), false);
  assert.throws(() => validateManifest({ version: '0.5.0-alpha.2' }, 'v0.5.0-alpha.2', 'amd64'));
  for (const version of ['0.5.0-alpha.0', '0.5.0-alpha.02', '0.5.0-beta.2', '0.5.0-alpha.2+test', 'main']) assert.throws(() => publicationContract('v' + version, version));
  assert.throws(() => publicationContract('v0.5.0-alpha.2', '0.5.0-alpha.3'));
  assert.deepEqual(publicationContract('v0.5.0', '0.5.0'), { version: '0.5.0', prerelease: false });
});
