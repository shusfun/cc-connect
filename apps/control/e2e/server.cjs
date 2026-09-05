// 仅限本地浏览器测试：内存数据库、临时自签证书，不连接生产或读取真实凭据。
const https=require('node:https');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const {randomBytes}=require('node:crypto');
const {ControlStore}=require('../../../relay/control-store');
const {createControlHTTP}=require('../../../relay/control-http');
async function main(){
 const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'remodex-browser-fixture-'));
 const key=path.join(temporary,'key.pem'),cert=path.join(temporary,'cert.pem');
 execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',key,'-out',cert,'-subj','/CN=localhost'],{stdio:'ignore'});
 const origin='https://127.0.0.1:19831';
 const store=new ControlStore({filename:':memory:',masterKey:randomBytes(32)});
 const admin=await store.setup({login:'test-admin',password:'TestAdmin',origin,githubClientId:'fixture',githubClientSecret:'fixture-only'});
 store.githubUser({id:1,login:'test-admin'},admin.id);
 const control=createControlHTTP({store,setupToken:randomBytes(32).toString('hex'),logger:()=>{}});
 const server=https.createServer({key:fs.readFileSync(key),cert:fs.readFileSync(cert)},async(req,res)=>{
  if(req.url==='/__test/activation'&&req.method==='POST'){
   const request=store.startActivation({publicKey:randomBytes(32).toString('base64'),platform:'macos',systemName:'浏览器测试电脑'});
   res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({url:request.approvalURL}));return;
  }
  if(req.url==='/__test/health'){res.writeHead(200);res.end('ready');return;}
  if(!await control.route(req,res)){res.writeHead(404);res.end();}
 });
 server.listen(19831,'127.0.0.1',()=>console.log('Remodex isolated browser fixture ready'));
 let closing=false;const close=()=>{if(closing)return;closing=true;server.close(()=>{store.close();fs.rmSync(temporary,{recursive:true,force:true});process.exit(0);});server.closeAllConnections();};
 process.on('SIGTERM',close);process.on('SIGINT',close);
}
main().catch(()=>{console.error('browser_fixture_failed');process.exit(1);});
