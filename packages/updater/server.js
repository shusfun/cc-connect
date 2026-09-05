const http=require('node:http');
const fs=require('node:fs');
const {timingSafeEqual}=require('node:crypto');
const {Engine}=require('./engine');
const {Backups}=require('./backup');
const key=Buffer.from(fs.readFileSync('/run/secrets/master-key','utf8').trim(),'hex');
const token=fs.readFileSync('/run/secrets/updater-token','utf8').trim();
if(key.length!==32||token.length<32)throw new Error('updater_configuration_invalid');
const backups=new Backups({directory:'/state/backups',database:'/data/remodex.sqlite',key});
async function health(){
  try{
    const response=await fetch('http://remodex-relay:9820/health',{signal:AbortSignal.timeout(3000)});
    if(!response.ok||await response.text()!=='{"ok":true}')return false;
    const status=await fetch('http://remodex-relay:9820/v1/control/status',{signal:AbortSignal.timeout(3000)});
    if(!status.ok||!(await status.json()).complete)return false;
    return await new Promise(resolve=>{const req=http.request('http://remodex-relay:9820/relay/update-probe',{headers:{Connection:'Upgrade',Upgrade:'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':'MDEyMzQ1Njc4OWFiY2RlZg=='}},res=>{res.resume();resolve(res.statusCode===401||res.statusCode===403);});req.on('upgrade',(_,socket)=>{socket.destroy();resolve(false);});req.on('error',()=>resolve(false));req.setTimeout(3000,()=>{req.destroy();resolve(false);});req.end();});
  }catch{return false;}
}
const {persistImage}=require('./deployment');
const engine=new Engine({directory:'/state',backups,architecture:process.arch==='arm64'?'arm64':'amd64',currentVersion:require('../../package.json').version,health,persistImage});
const socket='/control/updater.sock';fs.mkdirSync('/control',{recursive:true,mode:0o755});fs.chmodSync('/control',0o755);fs.chmodSync('/state',0o755);
if(fs.existsSync(socket)){if(!fs.lstatSync(socket).isSocket())throw new Error('socket_path_invalid');fs.unlinkSync(socket);}
const server=http.createServer(async(req,res)=>{
  res.setHeader('content-type','application/json');
  try{
    const supplied=Buffer.from((req.headers.authorization||'').replace(/^Bearer /,'')),expected=Buffer.from(token);
    if(supplied.length!==expected.length||!timingSafeEqual(supplied,expected))throw new Error('executor_unauthorized');
    const action=req.url.slice(1);
    if(req.method==='GET'&&action==='status'){res.end(JSON.stringify(engine.status()));return;}
    if(req.method==='GET'&&action==='backups'){res.end(JSON.stringify({items:backups.list(engine.state.backup?.id)}));return;}
    if(req.method!=='POST')throw new Error('operation_forbidden');
    let data='';for await(const chunk of req){data+=chunk;if(data.length>2048)throw new Error('body_too_large');}
    const body=JSON.parse(data||'{}');
    res.statusCode=202;res.end(JSON.stringify(engine.start(action,body)));
  }catch(error){res.statusCode=400;res.end(JSON.stringify({code:/^[a-z_]+$/.test(error.message)?error.message:'executor_failed'}));}
});
engine.recover().then(()=>{server.listen(socket,()=>{fs.chmodSync(socket,0o660);fs.chownSync(socket,0,10001);});});
const timer=setInterval(()=>{if(!engine.busy&&engine.state.phase!=='recovery_failed'){try{engine.start('check');}catch{/* 下一周期重试；状态仍保留。 */}}},6*3600000);
timer.unref();
