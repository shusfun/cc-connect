const http=require('node:http');
function docker(method,path,body) {
  return new Promise((resolve,reject)=>{
    const request=http.request({socketPath:'/var/run/docker.sock',path:`/v1.47${path}`,method,headers:{'content-type':'application/json'}},response=>{
      const chunks=[];let size=0;
      response.on('data',chunk=>{size+=chunk.length;if(size>8_000_000){request.destroy(new Error('docker_response_large'));return;}chunks.push(chunk);});
      response.on('end',()=>{if(response.statusCode>=400)return reject(Object.assign(new Error('docker_operation_failed'),{status:response.statusCode})); const text=Buffer.concat(chunks).toString();if(!text)return resolve(null);try{resolve(JSON.parse(text));}catch{if(text.split('\n').filter(Boolean).some(line=>{try{return !!JSON.parse(line).error;}catch{return true;}}))reject(new Error('docker_pull_failed'));else resolve(null);}});
    });
    request.setTimeout(300000,()=>request.destroy(new Error('docker_timeout'))); request.on('error',reject);request.end(body?JSON.stringify(body):undefined);
  });
}
function own(container) {
  if (!container?.Id?.match(/^[a-f0-9]{64}$/) || container.Config?.Labels?.['cn.syggu.remodex.owner']!=='remodex' || container.Config?.Labels?.['com.docker.compose.service']!=='relay')throw new Error('container_ownership_mismatch');
  const host=container.HostConfig;
  if (!host.ReadonlyRootfs || !host.CapDrop?.includes('ALL') || container.Config.User!=='10001:10001' || host.Privileged || container.Mounts.some(m=>m.Destination.includes('docker.sock')))throw new Error('container_policy_mismatch');
  const binding=host.PortBindings?.['9820/tcp'];
  if(binding?.length!==1||binding[0].HostIp!=='127.0.0.1'||binding[0].HostPort!=='9820')throw new Error('container_port_mismatch');
  return container;
}
function createSpec(container,image) {
  own(container);
  const config=container.Config,host=container.HostConfig;
  return {Image:image,User:'10001:10001',Env:config.Env,Cmd:config.Cmd,Entrypoint:config.Entrypoint,WorkingDir:config.WorkingDir,ExposedPorts:config.ExposedPorts,Labels:config.Labels,Healthcheck:config.Healthcheck,
    HostConfig:{Binds:host.Binds,Mounts:host.Mounts,PortBindings:host.PortBindings,ReadonlyRootfs:true,CapDrop:['ALL'],SecurityOpt:['no-new-privileges:true'],RestartPolicy:host.RestartPolicy,Init:true,Tmpfs:host.Tmpfs,LogConfig:host.LogConfig,NetworkMode:host.NetworkMode}};
}
module.exports={docker,own,createSpec};
