const fs=require('node:fs');
const path=require('node:path');
const {DatabaseSync,backup}=require('node:sqlite');
const {createCipheriv,createDecipheriv,randomBytes,randomUUID,createHash}=require('node:crypto');
const hash=b=>createHash('sha256').update(b).digest('hex');
class Backups {
  constructor({directory,database,key}){this.directory=directory;this.database=database;this.key=key;fs.mkdirSync(directory,{recursive:true,mode:0o700});}
  validateDatabase(){
    for(const suffix of ['', '-wal','-shm']){const file=this.database+suffix;if(fs.existsSync(file)&&!fs.lstatSync(file).isFile())throw new Error('database_path_invalid');}
    if(!fs.lstatSync(path.dirname(this.database)).isDirectory())throw new Error('database_path_invalid');
  }
  file(id){if(!/^[a-f0-9-]{36}$/.test(id))throw new Error('backup_invalid');return path.join(this.directory,`${id}.enc`);}
  decode(id){const bytes=fs.readFileSync(this.file(id));const cipher=createDecipheriv('aes-256-gcm',this.key,bytes.subarray(0,12));cipher.setAuthTag(bytes.subarray(-16));const value=JSON.parse(Buffer.concat([cipher.update(bytes.subarray(12,-16)),cipher.final()]));const data=Buffer.from(value.data,'base64');if(hash(data)!==value.sha256)throw new Error('backup_corrupt');return {...value,data};}
  list(protectedId){return fs.readdirSync(this.directory).filter(n=>/^[a-f0-9-]{36}\.enc$/.test(n)).map(n=>{const id=n.slice(0,-4);try{const {data,...metadata}=this.decode(id);return {...metadata,protected:id===protectedId};}catch{return {id,corrupt:true,protected:id===protectedId};}}).sort((a,b)=>(b.createdAt||0)-(a.createdAt||0));}
  async create(version){
    this.validateDatabase();
    const id=randomUUID(),tmp=path.join(this.directory,`${id}.sqlite`),db=new DatabaseSync(this.database,{readOnly:true});
    try{
      await backup(db,tmp);const schema=db.prepare('PRAGMA user_version').get().user_version;const instance=JSON.parse(db.prepare("SELECT value FROM settings WHERE key='instanceId'").get().value);
      const data=fs.readFileSync(tmp),iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',this.key,iv);
      const metadata={id,version,schema,instance,createdAt:Date.now(),sha256:hash(data)};
      const payload=Buffer.from(JSON.stringify({...metadata,data:data.toString('base64')}));
      fs.writeFileSync(this.file(id),Buffer.concat([iv,cipher.update(payload),cipher.final(),cipher.getAuthTag()]),{mode:0o600,flag:'wx',flush:true});return metadata;
    }finally{db.close();if(fs.existsSync(tmp))fs.unlinkSync(tmp);}
  }
  restore(id,{instance,schema,revoke=true}){
    this.validateDatabase();
    const value=this.decode(id);if(value.instance!==instance||value.schema!==schema)throw new Error('backup_incompatible');
    const tmp=path.join(this.directory,`${randomUUID()}.restore`);fs.writeFileSync(tmp,value.data,{mode:0o600,flag:'wx',flush:true});
    const db=new DatabaseSync(tmp);
    try{
      if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw new Error('backup_corrupt');
      if(revoke)db.exec("BEGIN IMMEDIATE; DELETE FROM browser_sessions; UPDATE credentials SET revoked=1; UPDATE devices SET status='revoked'; UPDATE phones SET status='revoked'; UPDATE grants SET status='revoked'; DELETE FROM requests; DELETE FROM invitations; DELETE FROM oauth_states; COMMIT;");
      db.exec('PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;');
    }finally{db.close();}
    // 临时文件保留执行器所有权；跨卷复制后才移交最终数据库，避免 copyFile 要求额外 FOWNER。
    // 调用者须先停业务容器；只清理这一个已关闭数据库的 WAL/SHM。
    for(const suffix of ['-wal','-shm'])if(fs.existsSync(this.database+suffix))fs.unlinkSync(this.database+suffix);
    // 备份卷与数据库卷可以不同，不能使用跨文件系统 rename。
    // 临时文件随机且 O_EXCL 创建；不跟随业务用户预植的同名链接。
    const destination=`${this.database}.${randomUUID()}.restore`;
    fs.copyFileSync(tmp,destination,fs.constants.COPYFILE_EXCL);
    fs.chmodSync(destination,0o600);if(process.getuid?.()===0)fs.chownSync(destination,10001,10001);
    const handle=fs.openSync(destination,'r');fs.fsyncSync(handle);fs.closeSync(handle);
    fs.renameSync(destination,this.database);fs.unlinkSync(tmp);
  }
  prune(protectedId){const list=this.list(protectedId);for(const row of list.slice(10))if(!row.protected&&!row.corrupt)fs.unlinkSync(this.file(row.id));}
}
module.exports={Backups};
