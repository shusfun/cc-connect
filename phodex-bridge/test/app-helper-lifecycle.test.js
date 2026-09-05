const test=require('node:test');
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
for(const scenario of ['parent_closed','invalid_bootstrap'])test(`app helper handles preflight without loading Bridge: ${scenario}`,{timeout:8000},async t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'remodex-helper-test-'));
  const helper=spawn(process.execPath,[path.resolve(__dirname,'../bin/remodex-app-helper.js'),'run'],{env:{...process.env,REMODEX_RELAY:'wss://example.invalid',REMODEX_DEVICE_STATE_DIR:directory},stdio:['pipe','pipe','pipe']});
  t.after(()=>{if(helper.exitCode===null)helper.kill('SIGKILL');fs.rmSync(directory,{recursive:true,force:true});});
  let error='';helper.stderr.on('data',chunk=>error+=chunk);helper.stdout.resume();helper.stdin.on('error',()=>{});
  const exit=new Promise((resolve,reject)=>{helper.on('exit',resolve);helper.on('error',reject);});
  if(scenario==='invalid_bootstrap')helper.stdin.write('invalid-json\n');else helper.stdin.end();
  const code=await exit;assert.notEqual(code,undefined);
  if(scenario==='invalid_bootstrap')assert.match(error,/activation_failed/);
});

test('supervisor terminates its running process group when the parent closes', {timeout:8000}, async t => {
  const script=path.resolve(__dirname,'fixtures/supervisor-worker.cjs');
  const helper=spawn(process.execPath,['-e',`require(${JSON.stringify(path.resolve(__dirname,'../src/app-supervisor'))}).supervise(${JSON.stringify(script)})`],{stdio:['pipe','pipe','pipe']});
  let worker;
  t.after(()=>{if(helper.exitCode===null)helper.kill('SIGKILL');if(worker){try{process.kill(-worker,'SIGKILL');}catch{}}});
  helper.stderr.resume();helper.stdin.on('error',()=>{});
  const exit=new Promise((resolve,reject)=>{helper.on('exit',resolve);helper.on('error',reject);});
  const ready=new Promise(resolve=>{let output='';helper.stdout.on('data',chunk=>{output+=chunk;if(output.includes('\n'))resolve(Number(output.trim()));});});
  helper.stdin.write('{}\n');worker=await ready;assert.ok(worker>0);
  helper.stdin.end();await exit;
  assert.throws(()=>process.kill(-worker,0),{code:'ESRCH'});
});
