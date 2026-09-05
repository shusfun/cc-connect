const REPO = 'shusfun/cc-connect';
const fail = code => Object.assign(new Error(code), { code });
function stable(version) { return typeof version === 'string' && /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version); }
function compare(a, b) {
  const av = a.replace(/^v/, '').split('-')[0].split('.').map(BigInt), bv = b.replace(/^v/, '').split('-')[0].split('.').map(BigInt);
  for (let i=0;i<3;i++) if (av[i] !== bv[i]) return av[i] > bv[i] ? 1 : -1;
  return a.includes('-') === b.includes('-') ? 0 : a.includes('-') ? -1 : 1;
}
async function boundedFetch(url, type = 'json', fetchImpl = fetch) {
  const response = await fetchImpl(url, { headers: { accept:'application/vnd.github+json', 'user-agent':'Remodex-Updater' }, signal:AbortSignal.timeout(20000) });
  if (response.status === 403 || response.status === 429) throw fail('github_rate_limited');
  if (!response.ok) throw fail('github_unavailable');
  const chunks=[];let size=0;
  for await (const chunk of response.body) { size += chunk.length; if(size>2_000_000) throw fail('release_too_large');chunks.push(chunk); }
  const data=Buffer.concat(chunks); return type==='json'?JSON.parse(data):data;
}
function validateManifest(manifest, tag, architecture, allowProtocolUpgrade = false) {
  if (!stable(tag) || manifest.version !== tag.replace(/^v/,'') || manifest.repository !== REPO || !/^[a-f0-9]{40}$/.test(manifest.sourceSHA || '') || !Number.isSafeInteger(manifest.updaterProtocol) || manifest.updaterProtocol < 1 || (!allowProtocolUpgrade && manifest.updaterProtocol !== 1)) throw fail('release_incompatible');
  if (!Number.isInteger(manifest.schema) || manifest.schema < 1 || !Number.isInteger(manifest.minimumSchema) || manifest.minimumSchema < 1) throw fail('release_incompatible');
  for (const arch of ['amd64','arm64']) for(const component of ['relay','updater']) {
    if (!new RegExp(`^ghcr\\.io/shusfun/cc-connect-${component}@sha256:[a-f0-9]{64}$`).test(manifest.images?.[component]?.[arch] || '')) throw fail('release_untrusted');
  }
  if(!['amd64','arm64'].includes(architecture))throw fail('architecture_unsupported');
  return manifest;
}
async function checkRelease({ currentVersion, architecture, fetchImpl = fetch, verify, allowProtocolUpgrade = false } = {}) {
  const releases=[];
  for(let page=1;page<=10;page++) {
    const batch=await boundedFetch(`https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}`,'json',fetchImpl);
    if(!Array.isArray(batch))throw fail('release_invalid');
    releases.push(...batch); if(batch.length<100)break;
    if(page===10)throw fail('release_catalog_limit');
  }
  const release=releases.filter(r=>!r.draft&&!r.prerelease&&stable(r.tag_name)).sort((a,b)=>compare(b.tag_name,a.tag_name))[0];
  if(!release || compare(release.tag_name,currentVersion)<=0)return null;
  const base=`https://github.com/${REPO}/releases/download/${release.tag_name}/`;
  const payload=await boundedFetch(`${base}remodex-release.json`,'buffer',fetchImpl);
  const bundle=await boundedFetch(`${base}remodex-release.sigstore.json`,'json',fetchImpl);
  const verifyBlob = verify || require('sigstore').verify;
  try {
    const identity=`https://github.com/${REPO}/.github/workflows/publish-server.yml@refs/tags/${release.tag_name}`;
    await verifyBlob(payload,bundle,{ certificateIssuer:'https://token.actions.githubusercontent.com', certificateIdentityURI:`^${identity.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}$`, tlogThreshold:1, ctLogThreshold:1, tufCachePath:'/tmp/remodex-tuf' });
  } catch { throw fail('release_untrusted'); }
  const manifest=validateManifest(JSON.parse(payload),release.tag_name,architecture,allowProtocolUpgrade);
  return { ...manifest, notes: String(release.body || '').slice(0,20000), tag:release.tag_name };
}
module.exports={stable,compare,validateManifest,checkRelease};
