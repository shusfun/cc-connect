const { stable } = require('./releases');

function publicationContract(tag, sourceVersion) {
  if (typeof tag !== 'string' || tag !== `v${sourceVersion}`) throw new Error('publication_version_mismatch');
  if (stable(sourceVersion)) return { version: sourceVersion, prerelease: false };
  if (/^0\.5\.0-alpha\.[1-9]\d*$/.test(sourceVersion)) return { version: sourceVersion, prerelease: true };
  throw new Error('publication_channel_invalid');
}
module.exports = { publicationContract };
if (require.main === module) {
  const result = publicationContract(process.env.GITHUB_REF_NAME, require('../../package.json').version);
  const output = `version=${result.version}\nprerelease=${result.prerelease}\n`;
  if (process.env.GITHUB_OUTPUT) require('node:fs').appendFileSync(process.env.GITHUB_OUTPUT, output);
  else process.stdout.write(output);
}
