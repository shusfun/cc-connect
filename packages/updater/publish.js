const fs=require('node:fs');
const path=require('node:path');
const {createHash}=require('node:crypto');
const {stable}=require('./releases');
const {sign}=require('sigstore');
(async()=>{
  const tag=process.env.GITHUB_REF_NAME,version=tag?.replace(/^v/,'');
  if(!stable(tag)||require('../../package.json').version!==version||!/^sha256:[a-f0-9]{64}$/.test(process.env.RELAY_DIGEST||'')||!/^sha256:[a-f0-9]{64}$/.test(process.env.UPDATER_DIGEST||''))throw new Error('release_contract_invalid');
  const dir='build/release';fs.mkdirSync(dir,{recursive:true});
  const clients=fs.readdirSync('build/release-clients',{recursive:true}).filter(name=>/\.(ipa|dmg|exe)$/.test(name));
  for(const suffix of ['unsigned.ipa','x86_64-Debug.dmg','arm64-Debug.dmg','.exe'])if(!clients.some(n=>n.endsWith(suffix)))throw new Error('client_artifact_missing');
  for(const name of clients){if(!name.includes(version))throw new Error('artifact_version_mismatch');fs.copyFileSync(path.join('build/release-clients',name),path.join(dir,path.basename(name)));}
  const images=Object.fromEntries(['relay','updater'].map(component=>[component,Object.fromEntries(['amd64','arm64'].map(arch=>[arch,`ghcr.io/shusfun/cc-connect-${component}@${process.env[`${component.toUpperCase()}_DIGEST`]}`]))]));
  fs.copyFileSync('relay/compose.yaml',`${dir}/compose.yaml`);fs.copyFileSync('deploy/remodex.sh',`${dir}/remodex.sh`);
  fs.writeFileSync(`${dir}/install.sh`,fs.readFileSync('deploy/install.sh','utf8').replace('@REMODEX_BOOTSTRAP_IMAGE@',images.updater.amd64));
  const assets=Object.fromEntries(fs.readdirSync(dir).map(name=>[name,createHash('sha256').update(fs.readFileSync(path.join(dir,name))).digest('hex')]));
  const manifest={repository:'shusfun/cc-connect',version,sourceSHA:process.env.GITHUB_SHA,updaterProtocol:1,schema:3,minimumSchema:1,images,assets};
  const payload=Buffer.from(JSON.stringify(manifest,null,2));
  const tokenURL=new URL(process.env.ACTIONS_ID_TOKEN_REQUEST_URL);tokenURL.searchParams.set('audience','sigstore');
  const response=await fetch(tokenURL,{headers:{Authorization:`Bearer ${process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}`}});if(!response.ok)throw new Error('oidc_failed');
  const {value:identityToken}=await response.json();const bundle=await sign(payload,{identityToken});
  fs.writeFileSync(`${dir}/remodex-release.json`,payload);fs.writeFileSync(`${dir}/remodex-release.sigstore.json`,JSON.stringify(bundle));
  fs.writeFileSync(`${dir}/SHA256SUMS`,fs.readdirSync(dir).map(name=>`${createHash('sha256').update(fs.readFileSync(path.join(dir,name))).digest('hex')}  ${name}`).join('\n')+'\n');
})().catch(()=>{console.error('发布单元验证或签名失败；不会发布不完整 Release。');process.exitCode=1;});
