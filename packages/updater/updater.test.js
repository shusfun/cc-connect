const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {DatabaseSync}=require('node:sqlite');
const {randomBytes}=require('node:crypto');
const {stable,compare,validateManifest,checkRelease}=require('./releases');
const {own,createSpec}=require('./docker');
const {Backups}=require('./backup');
const {Engine}=require('./engine');
const manifest={version:'1.2.0',repository:'shusfun/cc-connect',sourceSHA:'a'.repeat(40),updaterProtocol:1,schema:2,minimumSchema:1,images:Object.fromEntries(['relay','updater'].map(c=>[c,{amd64:`ghcr.io/shusfun/cc-connect-${c}@sha256:${'b'.repeat(64)}`,arm64:`ghcr.io/shusfun/cc-connect-${c}@sha256:${'b'.repeat(64)}`}]))};
test('only stable semantic versions; stable supersedes alpha without downgrade',()=>{
  for(const s of ['v1.2.0','0.5.0','12.0.0'])assert.ok(stable(s));
  for(const s of ['1.2.0-alpha.1','01.2.0','main','1.2','1.2.0+build'])assert.equal(stable(s),false);
  assert.equal(compare('0.5.0','0.5.0-alpha.1'),1);assert.equal(compare('1.0.0','2.0.0'),-1);
});
test('release identity and image repositories are fixed',()=>{
  assert.equal(validateManifest(manifest,'v1.2.0','amd64'),manifest);
  for(const bad of [{...manifest,updaterProtocol:2},{...manifest,repository:'attacker/repo'},{...manifest,images:{}}])assert.throws(()=>validateManifest(bad,'v1.2.0','amd64'));
});
test('checks skip prereleases and enforce anchored workflow certificate identity',async()=>{
  const urls=[];const fetchImpl=async url=>{urls.push(url);return new Response(JSON.stringify(url.includes('/releases?')?[{tag_name:'v9.0.0-beta',prerelease:true},{tag_name:'v1.2.0',body:'Release'}]:url.endsWith('sigstore.json')?{}:manifest));};
  const result=await checkRelease({currentVersion:'0.5.0-alpha.1',architecture:'amd64',fetchImpl,verify:async(_payload,_bundle,options)=>{
    assert.equal(options.certificateIssuer,'https://token.actions.githubusercontent.com');assert.ok(options.certificateIdentityURI.startsWith('^'));assert.ok(options.certificateIdentityURI.endsWith('$'));
    assert.ok(new RegExp(options.certificateIdentityURI).test('https://github.com/shusfun/cc-connect/.github/workflows/publish-server.yml@refs/tags/v1.2.0'));
    assert.equal(new RegExp(options.certificateIdentityURI).test('https://github.com/shusfun/cc-connect/.github/workflows/publish-server.yml@refs/tags/v1.2.0.attacker'),false);
  }});assert.equal(result.version,'1.2.0');assert.ok(urls.every(url=>!url.includes('beta/')));
  await assert.rejects(checkRelease({currentVersion:'0.5.0',architecture:'amd64',fetchImpl,verify:async()=>{throw new Error('bad');}}),{code:'release_untrusted'});
});
function container(){return {Id:'a'.repeat(64),Name:'/remodex-relay',Mounts:[],State:{Running:true,Status:'running',Health:{Status:'healthy'}},Config:{User:'10001:10001',Labels:{'cn.syggu.remodex.owner':'remodex','com.docker.compose.service':'relay','org.opencontainers.image.version':'1.0.0'}},HostConfig:{ReadonlyRootfs:true,CapDrop:['ALL'],PortBindings:{'9820/tcp':[{HostIp:'127.0.0.1',HostPort:'9820'}]}}};}
test('Docker mutations require exact ownership and original localhost binding',()=>{const c=container();assert.equal(own(c),c);assert.equal(createSpec(c,manifest.images.relay.amd64).HostConfig.ReadonlyRootfs,true);c.Config.Labels['cn.syggu.remodex.owner']='other';assert.throws(()=>own(c));c.Config.Labels['cn.syggu.remodex.owner']='remodex';c.HostConfig.PortBindings['9820/tcp'][0].HostIp='0.0.0.0';assert.throws(()=>own(c));});
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'remodex-update-test-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return dir;}
test('deployment persists immutable test rollback ID but rejects tags and foreign registries',t=>{
  const file=path.join(temporary(t),'.env'),{persistImage}=require('./deployment');
  fs.writeFileSync(file,'REMODEX_IMAGE=old\nREMODEX_UPDATER_IMAGE=unchanged\n');
  for(const image of [`sha256:${'a'.repeat(64)}`,manifest.images.relay.amd64]){
    persistImage(image,file);assert.ok(fs.readFileSync(file,'utf8').includes(`REMODEX_IMAGE=${image}\n`));
  }
  for(const image of ['latest','test:local',`evil.io/relay@sha256:${'b'.repeat(64)}`,'sha256:abc'])assert.throws(()=>persistImage(image,file),/deployment_image_invalid/);
  assert.ok(fs.readFileSync(file,'utf8').includes('REMODEX_UPDATER_IMAGE=unchanged'));
});
test('encrypted consistent backup checks integrity and historical restore revokes credentials',async t=>{
  const directory=temporary(t),database=path.join(directory,'control.sqlite');const db=new DatabaseSync(database);
  db.exec("PRAGMA journal_mode=WAL; CREATE TABLE settings(key TEXT,value TEXT); INSERT INTO settings VALUES ('instanceId','\"instance\"'); CREATE TABLE browser_sessions(id); INSERT INTO browser_sessions VALUES(1); CREATE TABLE credentials(revoked); INSERT INTO credentials VALUES(0); CREATE TABLE devices(status); INSERT INTO devices VALUES('active'); CREATE TABLE phones(status); CREATE TABLE grants(status); CREATE TABLE requests(id); CREATE TABLE invitations(id); CREATE TABLE oauth_states(id); PRAGMA user_version=2;");
  const backups=new Backups({directory:path.join(directory,'backups'),database,key:randomBytes(32)});const entry=await backups.create('1.0.0');db.close();
  assert.equal(fs.readFileSync(backups.file(entry.id)).includes(Buffer.from('SQLite format')),false);
  assert.throws(()=>backups.restore(entry.id,{instance:'other',schema:2}),/backup_incompatible/);
  backups.restore(entry.id,{instance:'instance',schema:2});const restored=new DatabaseSync(database);assert.equal(restored.prepare('SELECT count(*) n FROM browser_sessions').get().n,0);assert.equal(restored.prepare('SELECT revoked FROM credentials').get().revoked,1);restored.close();
  fs.appendFileSync(backups.file(entry.id),'corrupt');assert.throws(()=>backups.decode(entry.id));
});
test('transaction restores previous image and backup on health failure',async t=>{
  const directory=temporary(t),calls=[],old=container();let fresh=null,restored=false;
  const callDocker=async(method,url,body)=>{
    calls.push([method,url]);
    if(url==='/containers/remodex-relay/json')return fresh||old;
    if(url===`/containers/${old.Id}/json`)return old;
    if(url.includes('/images/create'))return null;
    if(url.includes('/rename?')){old.Name='/remodex-relay-rollback';return null;}
    if(url.startsWith('/containers/create')){fresh={...container(),Id:'c'.repeat(64),Config:{...container().Config,Labels:body.Labels},State:{Status:'exited'}};return fresh;}
    if(fresh&&url===`/containers/${fresh.Id}/json`)return fresh;
    if(method==='DELETE'){fresh=null;return null;}
    return null;
  };
  const engine=new Engine({directory,architecture:'amd64',currentVersion:'1.0.0',callDocker,check:async()=>manifest,health:async()=>true,backups:{create:async()=>({id:'backup',instance:'instance',schema:2}),restore:()=>{restored=true;},prune:()=>{}}});
  engine.start('install',{version:'1.2.0'});assert.throws(()=>engine.start('install'),/update_busy/);
  while(engine.busy)await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(engine.state.phase,'rolled_back');assert.equal(restored,true);assert.equal(fs.existsSync(engine.gate),false);assert.ok(calls.some(([method])=>method==='DELETE'));
});
