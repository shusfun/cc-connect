const {checkRelease}=require('./releases');
(async()=>{
  const release=await checkRelease({currentVersion:'0.0.0',architecture:process.arch==='arm64'?'arm64':'amd64',allowProtocolUpgrade:true});
  if(!release)throw new Error('no_stable_release');
  if(process.argv[2]&&release.tag!==process.argv[2])throw new Error('release_changed');
  process.stdout.write(JSON.stringify(release));
})().catch(()=>{console.error('正式发布验证失败，安装已停止。');process.exitCode=1;});
