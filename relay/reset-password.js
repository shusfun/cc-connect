// 仅在 docker exec -i 中使用；密码通过标准输入，不进入参数或日志。
const fs=require('node:fs');
const {ControlStore}=require('./control-store');
const {hashPassword}=require('./password');
(async()=>{
  let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>4096)throw new Error('invalid_input');}
  const {login,password}=JSON.parse(input);input='';const next=await hashPassword(password);
  const store=new ControlStore({filename:process.env.REMODEX_DATABASE,masterKey:Buffer.from(fs.readFileSync(process.env.REMODEX_MASTER_KEY_FILE,'utf8').trim(),'hex')});
  try{store.transaction(()=>{const user=store.db.prepare("SELECT id FROM users WHERE login=? AND role='admin' AND status='enabled'").get(login);if(!user)throw new Error('administrator_missing');store.db.prepare('UPDATE users SET password=? WHERE id=?').run(next,user.id);store.db.prepare('DELETE FROM browser_sessions WHERE user_id=?').run(user.id);store.audit(user.id,'password.recovered',user.id);});console.log('管理员密码已恢复，所有浏览器会话已注销，设备授权不变。');}finally{store.close();}
})().catch(()=>{console.error('密码恢复失败，请检查管理员账号及密码规则。');process.exitCode=1;});
