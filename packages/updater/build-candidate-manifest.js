// 候选制品只供测试，不签发 Release 或自动更新清单。
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');

function candidateManifest({ sourceSHA, version, relayDigest, updaterDigest }) {
  if (!/^[a-f0-9]{40}$/.test(sourceSHA || '')) throw new Error('candidate_source_invalid');
  if (!/^\d+\.\d+\.\d+(?:-alpha\.[1-9]\d*)?$/.test(version || '')) throw new Error('candidate_version_invalid');
  const images = {};
  for (const [component, digest] of [['relay', relayDigest], ['updater', updaterDigest]]) {
    if (!/^sha256:[a-f0-9]{64}$/.test(digest || '')) throw new Error('candidate_digest_invalid');
    images[component] = { architectures: ['linux/amd64', 'linux/arm64'], index: `ghcr.io/shusfun/cc-connect-${component}@${digest}` };
  }
  return { repository: 'shusfun/cc-connect', sourceSHA, version, channel: 'candidate', automaticUpdateEligible: false, clientValidation: 'not-certified', images };
}

module.exports = { candidateManifest };
if (require.main === module) {
  const manifest = candidateManifest({ sourceSHA: process.env.GITHUB_SHA, version: require('../../package.json').version, relayDigest: process.env.RELAY_DIGEST, updaterDigest: process.env.UPDATER_DIGEST });
  const out = 'build/server-candidate';
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'remodex-candidate.json'), JSON.stringify(manifest, null, 2) + '\n');
  fs.copyFileSync('relay/compose.yaml', path.join(out, 'compose.yaml'));
  fs.copyFileSync('deploy/remodex.sh', path.join(out, 'remodex.sh'));
  fs.copyFileSync('Docs/PRERELEASE-INSTALL.md', path.join(out, 'INSTALL-TEST.md'));
  fs.copyFileSync('Docs/BUILD-CANDIDATES.md', path.join(out, 'CANDIDATE-STATUS.md'));
  fs.writeFileSync(path.join(out, 'SHA256SUMS'), fs.readdirSync(out).filter(name => name !== 'SHA256SUMS').sort().map(name => `${createHash('sha256').update(fs.readFileSync(path.join(out, name))).digest('hex')}  ${name}`).join('\n') + '\n');
}
