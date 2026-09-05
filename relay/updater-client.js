const http=require('node:http');
const {readFileSync}=require('node:fs');
function updaterClient(env){
  if(!env.REMODEX_UPDATER_TOKEN_FILE||!env.REMODEX_UPDATER_SOCKET)return undefined;
  const token=readFileSync(env.REMODEX_UPDATER_TOKEN_FILE,'utf8').trim();
  return (action,body)=>new Promise((resolve,reject)=>{
    const request=http.request({socketPath:env.REMODEX_UPDATER_SOCKET,path:`/${action}`,method:body?'POST':'GET',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'}},response=>{
      let data='';response.on('data',chunk=>{data+=chunk;if(data.length>2_000_000)request.destroy(new Error('executor_response_large'));});response.on('end',()=>{try{const value=JSON.parse(data);if(response.statusCode>=400)reject(Object.assign(new Error(value.code),{status:409,code:value.code}));else resolve(value);}catch{reject(Object.assign(new Error('updater_unavailable'),{status:503,code:'updater_unavailable'}));}});
    });request.setTimeout(10000,()=>request.destroy());request.on('error',()=>reject(Object.assign(new Error('updater_unavailable'),{status:503,code:'updater_unavailable'})));request.end(body?JSON.stringify(body):undefined);
  });
}
module.exports={updaterClient};
