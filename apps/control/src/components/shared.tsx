import React, { useEffect, useRef, useState } from 'react';
import { AlertCircle, CheckCircle2, LoaderCircle } from 'lucide-react';
import { api, label, type Row } from '../api';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Badge as UIBadge } from './ui/badge';
import { Alert, AlertDescription } from './ui/alert';
import { Skeleton } from './ui/skeleton';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './ui/select';
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from './ui/alert-dialog';

export function useData(path: string | null, revision = 0) {
  const [data,setData]=useState<any>(null),[error,setError]=useState(''),[loading,setLoading]=useState(true);
  useEffect(()=>{const controller=new AbortController();setData(null);setError('');setLoading(!!path);
    if(path)api(path,undefined,controller.signal).then(value=>{if(!controller.signal.aborted)setData(value);}).catch(e=>{if(!controller.signal.aborted)setError(e.message);}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});
    return()=>controller.abort();
  },[path,revision]);return {data,error,loading};
}
export function Notice({text,success=false}:{text:string;success?:boolean}) { return text?<Alert variant={success?'default':'destructive'} className={success?'border-primary/30 bg-primary/5':''} role={success?'status':'alert'}>{success?<CheckCircle2 className="h-4 w-4"/>:<AlertCircle className="h-4 w-4"/>}<AlertDescription className="break-words">{text}</AlertDescription></Alert>:null; }
export function Badge({value}:{value:unknown}) {return <UIBadge variant={['enabled','active','ok','redeemed'].includes(String(value))?'default':'secondary'}>{label(value)}</UIBadge>;}
export function Loading(){return <div role="status" aria-label="正在加载" className="grid gap-3"><Skeleton className="h-6 w-40"/><Skeleton className="h-24 w-full"/></div>;}
export type Field={name:string;title:string;type?:string;value?:string|number;optional?:boolean;help?:string};
export function Form({fields,submit,action}:{fields:Field[];submit:string;action:(body:Row)=>Promise<void>}){
  const [busy,setBusy]=useState(false),[error,setError]=useState(''),[done,setDone]=useState('');const active=useRef(true),lock=useRef(false);
  useEffect(()=>{active.current=true;return()=>{active.current=false;};},[]);
  return <form onSubmit={async event=>{event.preventDefault();if(lock.current)return;lock.current=true;setBusy(true);setError('');setDone('');const form=event.currentTarget;
    try{await action(Object.fromEntries(new FormData(form)));if(active.current){setDone('操作已完成。');for(const field of Array.from(form.elements))if(field instanceof HTMLInputElement&&field.type==='password')field.value='';}}
    catch(e){if(active.current)setError((e as Error).message);}finally{lock.current=false;if(active.current)setBusy(false);}}}>
    {fields.map(f=><label key={f.name} className="grid gap-2 text-sm font-medium">{f.title}<Input name={f.name} type={f.type||'text'} defaultValue={f.value} required={!f.optional} autoComplete={f.type==='password'?(f.name==='newPassword'?'new-password':'current-password'):'off'}/>{f.help&&<small>{f.help}</small>}</label>)}
    <Notice text={error}/><Notice text={done} success/><Button disabled={busy}>{busy&&<LoaderCircle className="mr-2 h-4 w-4 animate-spin"/>}{busy?'正在提交…':submit}</Button></form>;
}
export function Action({children,run,danger=false,confirm}:{children:React.ReactNode;run:()=>Promise<void>;danger?:boolean;confirm?:string}){
  const [busy,setBusy]=useState(false),[error,setError]=useState(''),[open,setOpen]=useState(false);const lock=useRef(false),active=useRef(true);
  useEffect(()=>{active.current=true;return()=>{active.current=false;};},[]);
  const execute=async()=>{if(lock.current)return;lock.current=true;setBusy(true);setError('');try{await run();if(active.current)setOpen(false);}catch(e){if(active.current)setError((e as Error).message);}finally{lock.current=false;if(active.current)setBusy(false);}};
  return <div className="inline-flex flex-col items-start gap-2"><Button variant={danger?'destructive':'outline'} disabled={busy} onClick={()=>confirm?setOpen(true):void execute()}>{busy&&<LoaderCircle className="mr-2 h-4 w-4 animate-spin"/>}{busy?'处理中…':children}</Button>{!open&&<Notice text={error}/>}
    <AlertDialog open={open} onOpenChange={v=>{if(!busy)setOpen(v);}}><AlertDialogContent><AlertDialogHeader><AlertDialogTitle>确认此操作</AlertDialogTitle><AlertDialogDescription>{confirm}</AlertDialogDescription></AlertDialogHeader><Notice text={error}/><AlertDialogFooter><AlertDialogCancel disabled={busy}>取消</AlertDialogCancel><AlertDialogAction disabled={busy} onClick={e=>{e.preventDefault();void execute();}}>{busy?'处理中…':'确认继续'}</AlertDialogAction></AlertDialogFooter></AlertDialogContent></AlertDialog></div>;
}
// 保留现有表单事件契约，渲染统一的 Radix Select，而不是并存原生控件。
export function SelectField({children,value,defaultValue,onChange,...props}:React.SelectHTMLAttributes<HTMLSelectElement>){
  const options=React.Children.toArray(children).filter(React.isValidElement) as React.ReactElement<{value?:string;children:React.ReactNode}>[];
  const mapped=(v:unknown)=>String(v??'')||'__all__';
  return <Select name={props.name} value={value===undefined?undefined:mapped(value)} defaultValue={defaultValue===undefined?undefined:mapped(defaultValue)} disabled={props.disabled} onValueChange={v=>onChange?.({target:{value:v==='__all__'?'':v},currentTarget:{value:v==='__all__'?'':v}} as React.ChangeEvent<HTMLSelectElement>)}><SelectTrigger aria-label={props['aria-label']||props.name} className="w-auto min-w-40"><SelectValue/></SelectTrigger><SelectContent>{options.map((o,i)=><SelectItem key={i} value={mapped(o.props.value)}>{o.props.children}</SelectItem>)}</SelectContent></Select>;
}
export function Reauth(){return <section className="card"><h2>敏感操作 · 验证管理员身份</h2><p>验证后五分钟内可修改系统设置、安装更新或恢复备份。</p><Form fields={[{name:'password',title:'管理员密码',type:'password'}]} submit="验证身份" action={async body=>{await api('manage/reauth',body);}}/></section>;}
export function PageTitle({title,description}:{title:string;description:string}){return <header className="page-title"><small>REMODEX / CONTROL</small><h1>{title}</h1><p>{description}</p></header>;}
export function Stat({title,value}:{title:string;value:React.ReactNode}){return <div className="stat"><small>{title}</small><strong>{value}</strong></div>;}
