import { useEffect, useState } from 'react';
import { NavLink, Routes, Route, Navigate } from 'react-router';
import { LayoutDashboard, Laptop, Smartphone, Users, CircleUserRound, Settings2, ScrollText, Download, LogOut, Moon, Sun, Monitor, Check, Terminal } from 'lucide-react';
import { api, setCSRF, type Row } from './api';
import { Activation } from './activation';
import { Entry, Overview, Listing, Profile, Settings, Updates } from './pages';
import { Notice, Loading, Badge, Action, PageTitle, useData } from './components/shared';
import { Button } from './components/ui/button';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from './components/ui/dropdown-menu';
const pages=[{path:'',title:'工作台',icon:LayoutDashboard},{path:'devices',title:'开发设备',icon:Laptop},{path:'phones',title:'手机授权',icon:Smartphone},{path:'accounts',title:'账号审核',icon:Users,admin:true},{path:'profile',title:'个人中心',icon:CircleUserRound},{path:'settings',title:'系统设置',icon:Settings2,admin:true},{path:'audit',title:'安全审计',icon:ScrollText,admin:true},{path:'updates',title:'更新与备份',icon:Download,admin:true}];
export function App(){
  const [revision,setRevision]=useState(0),[identity,setIdentity]=useState<Row|null>(null),[ready,setReady]=useState(false),[error,setError]=useState(''),[theme,setTheme]=useState(()=>localStorage.getItem('remodex.theme')||'system');
  const status=useData('status',revision),reload=()=>setRevision(v=>v+1);
  useEffect(()=>{const media=matchMedia('(prefers-color-scheme: dark)');const apply=()=>document.documentElement.classList.toggle('dark',theme==='dark'||theme==='system'&&media.matches);apply();media.addEventListener('change',apply);localStorage.setItem('remodex.theme',theme);return()=>media.removeEventListener('change',apply);},[theme]);
  useEffect(()=>{const controller=new AbortController();setError('');api('me',undefined,controller.signal).then(value=>{if(!controller.signal.aborted){setCSRF(value.csrf);setIdentity(value);}}).catch(e=>{if(controller.signal.aborted)return;setIdentity(null);setCSRF('');if(!['login_required','account_disabled'].includes(e.code))setError(e.message);}).finally(()=>{if(!controller.signal.aborted)setReady(true);});return()=>controller.abort();},[revision]);
  if(status.error||error)return <main className="entry"><Notice text={status.error||error}/><Button onClick={reload}>重试连接</Button></main>;
  if(!status.data||!ready)return <main className="entry"><Loading/></main>;
  if(!identity)return <Entry status={status.data} reload={reload}/>;
  const user=identity.user;
  if(!status.data.complete)return <main className="entry"><h1>最后一步：绑定管理员 GitHub</h1><p>请使用你自己的 GitHub 身份完成绑定。</p><Button asChild><a href="/v1/control/github/start">验证并完成初始化</a></Button></main>;
  return <div className="shell"><aside className="sidebar"><div className="brand"><div className="rounded-xl bg-primary p-2.5 text-primary-foreground"><Terminal className="h-6 w-6"/></div><span>Remodex<small>PRIVATE WORKSPACE</small></span></div>
    <nav aria-label="主要导航">{pages.filter(p=>user.status==='enabled'&&(!p.admin||user.role==='admin')).map(({path,title,icon:Icon})=><NavLink end key={path} to={`/admin${path?'/'+path:''}`}><Icon className="h-[18px] w-[18px] shrink-0" aria-hidden="true"/>{title}</NavLink>)}</nav>
    <div className="sidebar-bottom"><div className="flex items-center gap-3"><CircleUserRound className="h-8 w-8 text-muted-foreground"/><div><strong>{user.login}</strong><div className="mt-1"><Badge value={user.status}/></div></div></div>
      <DropdownMenu><DropdownMenuTrigger asChild><Button variant="outline" aria-label="显示主题"><Monitor className="mr-2 h-4 w-4"/>显示主题</Button></DropdownMenuTrigger><DropdownMenuContent align="start"><DropdownMenuLabel>外观</DropdownMenuLabel><DropdownMenuSeparator/>{[{value:'system',text:'跟随系统',icon:Monitor},{value:'light',text:'浅色',icon:Sun},{value:'dark',text:'深色',icon:Moon}].map(({value,text,icon:Icon})=><DropdownMenuItem key={value} onSelect={()=>setTheme(value)}><Icon className="mr-2 h-4 w-4"/>{text}{theme===value&&<Check className="ml-4 h-4 w-4"/>}</DropdownMenuItem>)}</DropdownMenuContent></DropdownMenu>
      <Action run={async()=>{await api('logout',{});setIdentity(null);setCSRF('');sessionStorage.removeItem('remodex.activation');reload();}}><LogOut className="mr-2 h-4 w-4"/>退出登录</Action></div></aside>
    <main className="workspace">{user.status!=='enabled'?<><PageTitle title="申请已提交" description="管理员审核通过后即可激活设备。"/><Badge value={user.status}/><Button onClick={reload}>刷新审核状态</Button></>:<><Activation/><Routes><Route path="/" element={<Overview/>}/><Route path="/admin" element={<Overview/>}/><Route path="/admin/devices" element={<Listing key="devices" kind="devices"/>}/><Route path="/admin/phones" element={<Listing key="phones" kind="phones"/>}/><Route path="/admin/profile" element={<Profile user={user} reload={reload}/>}/>{user.role==='admin'&&<><Route path="/admin/accounts" element={<Listing key="accounts" kind="accounts"/>}/><Route path="/admin/audit" element={<Listing key="audit" kind="audit"/>}/><Route path="/admin/settings" element={<Settings/>}/><Route path="/admin/updates" element={<Updates/>}/></>}<Route path="*" element={<Navigate to="/admin" replace/>}/></Routes></>}</main></div>;
}
