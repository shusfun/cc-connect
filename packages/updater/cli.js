const http=require('node:http');
const fs=require('node:fs');
const [action,arg]=process.argv.slice(2);
if(!['status','backups','check','backup','install','restore','rollback'].includes(action))throw new Error('operation_forbidden');
const token=fs.readFileSync('/run/secrets/updater-token','utf8').trim();
const body=action==='install'?{version:arg}:action==='restore'?{backupId:arg}:{};
const request=http.request({socketPath:'/control/updater.sock',path:`/${action}`,method:['status','backups'].includes(action)?'GET':'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'}},response=>{
  response.pipe(process.stdout);response.on('end',()=>{if(response.statusCode>=400)process.exitCode=1;});
});request.on('error',()=>{console.error('无法连接更新执行器。');process.exitCode=1;});request.end(JSON.stringify(body));
