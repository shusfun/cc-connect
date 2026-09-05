import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import { KeyRound, LoaderCircle, ShieldCheck } from 'lucide-react';
import { api, label } from './api';
import { Notice, Loading } from './components/shared';
import { Button } from './components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from './components/ui/card';

const pendingKey='remodex.activation', completedKey='remodex.activation.completed';
function completed():string[]{try{const value=JSON.parse(sessionStorage.getItem(completedKey)||'[]');return Array.isArray(value)?value.filter(v=>typeof v==='string'):[];}catch{return [];}}
export function rememberActivationFromURL(){const id=new URLSearchParams(location.search).get('activation');if(id&&!completed().includes(id))sessionStorage.setItem(pendingKey,id);}
export type ActivationRecord={id:string;status:'pending'|'approved'|'redeemed'|'expired'|'revoked';platform:string;systemName:string;code:string;publicKey:string;expiresAt:number;serverTime:number};
export function Activation(){
  const location=useLocation(),navigate=useNavigate();
  const proposed=new URLSearchParams(location.search).get('activation')||sessionStorage.getItem(pendingKey);
  const id=proposed&&!completed().includes(proposed)?proposed:null;
  const [record,setRecord]=useState<ActivationRecord|null>(null),[error,setError]=useState(''),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[now,setNow]=useState(Date.now());
  const [revision,setRevision]=useState(0);
  const controller=useRef<AbortController|null>(null),operation=useRef(''),lock=useRef(false),offset=useRef(0);
  function finish(status:string,signal:AbortSignal){if(signal.aborted||!id||completed().includes(id))return;sessionStorage.setItem(completedKey,JSON.stringify([...completed().filter(v=>v!==id),id].slice(-20)));if(sessionStorage.getItem(pendingKey)===id)sessionStorage.removeItem(pendingKey);
    navigate('/admin/devices',{replace:true,state:{activationNotice:status==='redeemed'?'电脑已接收凭据，设备激活完成。':'设备已批准，等待电脑接收凭据。请回到电脑查看激活状态。'}});
  }
  useEffect(()=>{const current=new AbortController();controller.current=current;operation.current=crypto.randomUUID();lock.current=false;setRecord(null);setError('');setLoading(!!id);setBusy(false);
    if(!id)return()=>current.abort();
    let polling:ReturnType<typeof setTimeout>|undefined;
    const load=async()=>{try{const value:ActivationRecord=await api(`activation?id=${encodeURIComponent(id)}`,undefined,current.signal,undefined,operation.current);if(current.signal.aborted)return;
      offset.current=value.serverTime-Date.now();setNow(value.serverTime);setRecord(value);setError('');
      if(value.status==='approved'||value.status==='redeemed'){finish(value.status,current.signal);return;}
      if(value.status==='pending')polling=setTimeout(load,5000);
    }catch(e){if(!current.signal.aborted)setError((e as Error).message);}finally{if(!current.signal.aborted)setLoading(false);}};
    void load();const clock=setInterval(()=>setNow(Date.now()+offset.current),1000);
    return()=>{current.abort();clearTimeout(polling);clearInterval(clock);};
  },[id,revision]);
  if(!id)return null;
  const expired=record?.status==='expired'||record?.status==='revoked'||(record?.status==='pending'&&now>=record.expiresAt);
  const approve=async()=>{const signal=controller.current?.signal;if(!signal||signal.aborted||lock.current||expired)return;lock.current=true;setBusy(true);setError('');
    try{await api('activation/approve',{id},signal,undefined,operation.current);finish('approved',signal);}
    catch(e){if(signal.aborted)return;const failure=e as Error&{code?:string};
      if(['request_consumed','request_timeout','network_failed','internal_error'].includes(failure.code||'')){
        try{const authoritative:ActivationRecord=await api(`activation?id=${encodeURIComponent(id)}`,undefined,signal,undefined,operation.current);if(signal.aborted)return;setRecord(authoritative);if(['approved','redeemed'].includes(authoritative.status)){finish(authoritative.status,signal);return;}}
        catch(checkError){if(!signal.aborted)setError((checkError as Error).message);return;}
      }
      setError(failure.message);
    }finally{if(!signal.aborted){lock.current=false;setBusy(false);}}
  };
  return <Card className="mb-6 border-primary/30"><CardHeader><CardTitle className="flex items-center gap-2"><ShieldCheck className="h-5 w-5"/>确认激活设备</CardTitle></CardHeader><CardContent className="grid gap-4"><Notice text={error}/>{error&&<Button variant="outline" className="w-fit" disabled={busy} onClick={()=>setRevision(v=>v+1)}>重新检查状态</Button>}{loading?<Loading/>:record&&<><p>{record.systemName} · {label(record.platform)}</p>
    {expired?<Notice text={record.status==='revoked'?'这台设备的授权已撤销，请回到电脑重新发起激活。':'激活申请已过期，请回到电脑重新发起。不会自动重新批准。'}/>:<><div className="code">{record.code}</div><p>请核对电脑显示的核对码和设备公钥。有效期剩余 {Math.max(0,Math.ceil((record.expiresAt-now)/1000))} 秒。</p><div className="flex gap-2 break-all rounded-lg bg-muted p-3 font-mono text-xs"><KeyRound className="h-4 w-4 shrink-0"/>{record.publicKey}</div>{record.status==='pending'&&<Button className="w-fit" disabled={busy} onClick={()=>void approve()}>{busy&&<LoaderCircle className="mr-2 h-4 w-4 animate-spin"/>}{busy?'正在批准…':'批准这台设备'}</Button>}</>}
  </>}</CardContent></Card>;
}
