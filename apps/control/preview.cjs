// 独立的内存测试站点，仅绑定 localhost；不连接 VPS，不加载生产凭据。
const http=require('node:http');
const {randomBytes}=require('node:crypto');
const {ControlStore}=require('../../relay/control-store');
const {createControlHTTP}=require('../../relay/control-http');
(async()=>{
  const store=new ControlStore({filename:':memory:',masterKey:randomBytes(32)});
  const admin=await store.setup({login:'preview',password:'PreviewOnly',origin:'https://preview.invalid',githubClientId:'preview',githubClientSecret:'preview-not-real'});
  store.githubUser({id:1,login:'preview'},admin.id);
  for(let id=2;id<8;id++){const user=store.githubUser({id,login:`developer-${id}`});if(id<5)store.review(admin,user.id,'enabled',null);}
  for(const [platform,name] of [['macos','设计工作站'],['windows','开发主机']]){
    const req=store.startActivation({publicKey:randomBytes(32).toString('base64'),platform,systemName:name});store.approveActivation(admin,req.id);
  }
  const control=createControlHTTP({store,setupToken:randomBytes(32).toString('hex'),liveStatus:()=>({available:true,devices:[]})});
  const server=http.createServer(async(req,res)=>{if(!await control.route(req,res)){res.writeHead(404);res.end();}});
  server.listen(19821,'127.0.0.1',()=>{store.set('origin','http://localhost:19821');console.log('Remodex isolated preview: http://localhost:19821');});
  process.on('SIGTERM',()=>server.close(()=>{store.close();process.exit();}));
})().catch(error=>{console.error(error.code||'preview_failed');process.exitCode=1;});
