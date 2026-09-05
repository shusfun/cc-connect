const fs=require('node:fs');
const path=require('node:path');
const {docker,own,createSpec}=require('./docker');
const {checkRelease}=require('./releases');
const {randomUUID}=require('node:crypto');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
class Engine {
  constructor({directory,backups,architecture,currentVersion,callDocker=docker,check=checkRelease,health,persistImage=()=>{}}){
    Object.assign(this,{directory,backups,architecture,currentVersion,callDocker,check,health,persistImage});
    fs.mkdirSync(directory,{recursive:true,mode:0o755});
    this.file=path.join(directory,'transaction.json');this.gate=path.join(directory,'maintenance');
    this.state=fs.existsSync(this.file)?JSON.parse(fs.readFileSync(this.file)): {phase:'idle'};this.busy=false;
  }
  save(patch){this.state={...this.state,...patch,updatedAt:Date.now()};const tmp=`${this.file}.tmp`;fs.writeFileSync(tmp,JSON.stringify(this.state),{mode:0o600,flush:true});fs.renameSync(tmp,this.file);}
  status(){const {previous,newId,oldId,backup,...publicState}=this.state;return {...publicState,available:true,busy:this.busy};}
  maintain(){fs.writeFileSync(this.gate,'maintenance',{mode:0o644,flush:true});}
  unmaintain(){if(fs.existsSync(this.gate))fs.unlinkSync(this.gate);}
  async inspect(){return own(await this.callDocker('GET','/containers/remodex-relay/json'));}
  async checkNow(){
    const current=await this.inspect();this.currentVersion=current.Config.Labels['org.opencontainers.image.version']||this.currentVersion;
    const candidate=await this.check({currentVersion:this.currentVersion,architecture:this.architecture});
    this.save({checkedAt:Date.now(),candidate,currentVersion:this.currentVersion,error:null});return candidate;
  }
  async ready(id){
    for(let i=0;i<30;i++){
      const container=own(await this.callDocker('GET',`/containers/${id}/json`));
      if(container.State.Status==='exited')throw new Error('container_exited');
      if(container.State.Health?.Status==='healthy'&&await this.health())return;
      await delay(2000);
    }
    throw new Error('health_failed');
  }
  space(){const disk=fs.statfsSync(this.directory);if(disk.bavail*disk.bsize<512*1024*1024)throw new Error('insufficient_space');}
  async recover(){
    if(this.state.phase==='complete'){this.unmaintain();return;}
    if(!['preparing','stopping','backing_up','replacing','verifying','restoring','rolling_back'].includes(this.state.phase))return;
    // 重启后只进行一次确定的回滚；失败保持维护，等待管理员处理。
    this.busy=true;try{await this.rollback();}catch{this.save({phase:'recovery_failed',error:'recovery_failed'});}finally{this.busy=false;}
  }
  start(action,body={}){
    if(this.busy||(this.state.phase==='recovery_failed'&&action!=='rollback'))throw new Error('update_busy');
    if(!['check','backup','install','restore','rollback'].includes(action))throw new Error('operation_forbidden');
    if(action==='rollback'&&(this.state.phase!=='recovery_failed'||!fs.existsSync(this.gate)||!this.state.oldId))throw new Error('rollback_forbidden');
    this.busy=true;
    // 返回后任务继续，业务容器重启不会中断更新执行器。
    const task=async()=>{
      try {
        if(action==='check'){this.save({phase:'checking',error:null});await this.checkNow();this.save({phase:'idle'});}
        else if(action==='backup'){this.space();const old=await this.inspect();const metadata=await this.backups.create(old.Config.Labels['org.opencontainers.image.version']||this.currentVersion);this.backups.prune(this.state.backup?.id);this.save({phase:'idle',lastBackup:metadata.createdAt,error:null});}
        else if(action==='rollback')await this.rollback();
        else await this.replace(action,body);
      }catch(error){
        if(this.state.oldId&&fs.existsSync(this.gate)&&!['complete','rolled_back'].includes(this.state.phase)){
          try{await this.rollback();}catch{this.save({phase:'recovery_failed',error:'recovery_failed'});}
        }else this.save({phase:'failed',error:/^[a-z_]+$/.test(error.code||error.message)?error.code||error.message:'update_failed'});
      }finally{this.busy=false;}
    };
    queueMicrotask(task);return {accepted:true};
  }
  async replace(action,body){
    this.space();const old=await this.inspect();
    let candidate;
    if(action==='install'){
      candidate=await this.checkNow();
      if(!candidate||candidate.version!==body.version)throw new Error('release_changed');
      await this.callDocker('POST',`/images/create?fromImage=${encodeURIComponent(candidate.images.relay[this.architecture])}`);
    }
    const oldVersion=old.Config.Labels['org.opencontainers.image.version']||this.currentVersion;
    if(action==='restore'){const selected=this.backups.decode(body.backupId);if(selected.version!==oldVersion)throw new Error('backup_version_mismatch');}
    this.save({phase:'preparing',transaction:randomUUID(),oldId:old.Id,newId:null,previous:old,backup:null,operation:action,error:null});
    this.maintain();this.save({phase:'stopping'});
    await this.callDocker('POST',`/containers/${old.Id}/stop?t=20`);
    this.save({phase:'backing_up'});
    const backup=await this.backups.create(oldVersion);this.save({backup});
    if(candidate&&(backup.schema<candidate.minimumSchema||backup.schema>candidate.schema))throw new Error('schema_incompatible');
    if(action==='restore'){
      this.save({phase:'restoring'});this.backups.restore(body.backupId,{instance:backup.instance,schema:backup.schema,revoke:true});
      await this.callDocker('POST',`/containers/${old.Id}/start`);this.save({phase:'verifying'});await this.ready(old.Id);
    }else{
      this.save({phase:'replacing'});
      await this.callDocker('POST',`/containers/${old.Id}/rename?name=remodex-relay-rollback`);
      const spec=createSpec(old,candidate.images.relay[this.architecture]);
      spec.Env=(spec.Env||[]).filter(v=>!v.startsWith('REMODEX_RELEASE_VERSION='));spec.Env.push(`REMODEX_RELEASE_VERSION=${candidate.version}`);
      spec.Labels={...spec.Labels,'org.opencontainers.image.version':candidate.version,'org.opencontainers.image.revision':candidate.sourceSHA,'cn.syggu.remodex.transaction':this.state.transaction};
      const created=await this.callDocker('POST','/containers/create?name=remodex-relay',spec);this.save({newId:created.Id});
      await this.callDocker('POST',`/containers/${created.Id}/start`);this.save({phase:'verifying'});await this.ready(created.Id);
    }
    // 提交点之后绝不自动恢复旧库，以免覆盖新写入。
    if(candidate)this.persistImage(candidate.images.relay[this.architecture]);
    this.save({phase:'complete',currentVersion:candidate?.version||oldVersion,candidate:null,e2e:'awaiting_client',error:null});this.unmaintain();
    if(action==='install') {
      try { await this.callDocker('DELETE',`/containers/${old.Id}`); }
      catch { this.save({warning:'rollback_container_cleanup_required'}); }
    }
    this.backups.prune(backup.id);
  }
  async rollback(){
    this.maintain();this.save({phase:'rolling_back'});
    const old=own(await this.callDocker('GET',`/containers/${this.state.oldId}/json`));
    let fresh;
    try{fresh=own(await this.callDocker('GET','/containers/remodex-relay/json'));}catch(error){if(error.status!==404)throw error;}
    if(fresh&&fresh.Id!==old.Id){if(fresh.Config.Labels['cn.syggu.remodex.transaction']!==this.state.transaction)throw new Error('container_ownership_mismatch');await this.callDocker('POST',`/containers/${fresh.Id}/stop?t=20`);await this.callDocker('DELETE',`/containers/${fresh.Id}`);}
    if(old.State.Running)await this.callDocker('POST',`/containers/${old.Id}/stop?t=20`);
    if(this.state.backup)this.backups.restore(this.state.backup.id,{instance:this.state.backup.instance,schema:this.state.backup.schema,revoke:false});
    if(old.Name!=='/remodex-relay')await this.callDocker('POST',`/containers/${old.Id}/rename?name=remodex-relay`);
    await this.callDocker('POST',`/containers/${old.Id}/start`);await this.ready(old.Id);
    if(old.Config.Image)this.persistImage(old.Config.Image);
    this.save({phase:'rolled_back',error:'update_rolled_back'});this.unmaintain();
  }
}
module.exports={Engine};
