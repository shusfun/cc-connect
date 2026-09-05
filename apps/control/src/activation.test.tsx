import React from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation, useNavigate } from 'react-router';
import { Activation } from './activation';
import { api } from './api';
vi.mock('./api', () => ({ api: vi.fn(), label: (s: string) => s }));
const record={id:'test-activation',status:'pending',platform:'macos',systemName:'测试电脑',code:'1234ABCD',publicKey:'public-only',expiresAt:Date.now()+300000,serverTime:Date.now()};
function Devices(){const location=useLocation();return <h1>{location.state?.activationNotice||'开发设备'}</h1>;}
function mount(){return render(<MemoryRouter initialEntries={['/?activation=test-activation']}><Activation/><Routes><Route path="/" element={<div/>}/><Route path="/admin/devices" element={<Devices/>}/></Routes></MemoryRouter>);}
beforeEach(()=>{sessionStorage.clear();vi.mocked(api).mockReset();});afterEach(cleanup);
describe('activation feedback',()=>{
 it('successful approval removes the card and storage via router navigation',async()=>{
  sessionStorage.setItem('remodex.activation','test-activation');vi.mocked(api).mockImplementation(async(path,body)=>body?{}:record);
  mount();fireEvent.click(await screen.findByRole('button',{name:'批准这台设备'}));
  await screen.findByRole('heading',{name:/设备已批准/});expect(screen.queryByRole('button',{name:'批准这台设备'})).toBeNull();expect(sessionStorage.getItem('remodex.activation')).toBeNull();
 });
 it('blocks rapid double click while approval is pending',async()=>{
  let finish!:()=>void;vi.mocked(api).mockImplementation(async(_p,body)=>body?new Promise(resolve=>{finish=()=>resolve({});}):record);
  mount();const button=await screen.findByRole('button',{name:'批准这台设备'});fireEvent.click(button);fireEvent.click(button);
  expect(vi.mocked(api).mock.calls.filter(([,body])=>body).length).toBe(1);finish();await screen.findByRole('heading',{name:/设备已批准/});
 });
 it.each(['request_consumed','network_failed','request_timeout'])('reconciles %s without approving twice',async code=>{
  let reads=0;vi.mocked(api).mockImplementation(async(_p,body)=>{if(body)throw Object.assign(new Error(code),{code});return ++reads===1?record:{...record,status:'redeemed'};});
  mount();fireEvent.click(await screen.findByRole('button',{name:'批准这台设备'}));await screen.findByRole('heading',{name:/电脑已接收/});expect(vi.mocked(api).mock.calls.filter(([,body])=>body).length).toBe(1);
 });
 it('does not display success when reconciliation is forbidden',async()=>{
  let reads=0;vi.mocked(api).mockImplementation(async(_p,body)=>{if(body)throw Object.assign(new Error('consumed'),{code:'request_consumed'});if(++reads>1)throw new Error('你无权管理此设备。');return record;});
  mount();fireEvent.click(await screen.findByRole('button',{name:'批准这台设备'}));await screen.findByText('你无权管理此设备。');expect(screen.queryByRole('heading',{name:/电脑已接收/})).toBeNull();
 });
 it('expires without a submit button',async()=>{vi.mocked(api).mockResolvedValue({...record,status:'expired'});mount();await screen.findByText(/激活申请已过期/);expect(screen.queryByRole('button',{name:'批准这台设备'})).toBeNull();});
 it('ignores late approval response after unmount',async()=>{
  let finish!:()=>void;vi.mocked(api).mockImplementation(async(_p,body)=>body?new Promise(resolve=>{finish=()=>resolve({});}):record);
  const view=mount();fireEvent.click(await screen.findByRole('button',{name:'批准这台设备'}));view.unmount();finish();await new Promise(r=>setTimeout(r,0));expect(sessionStorage.getItem('remodex.activation.completed')).toBeNull();
 });
 it('does not resurrect a completed approval from an old URL',async()=>{sessionStorage.setItem('remodex.activation.completed',JSON.stringify(['test-activation']));mount();await waitFor(()=>expect(api).not.toHaveBeenCalled());});
 it('revoked authorization never appears as activated',async()=>{vi.mocked(api).mockResolvedValue({...record,status:'revoked'});mount();await screen.findByText(/授权已撤销/);expect(screen.queryByRole('button',{name:'批准这台设备'})).toBeNull();});
 it('old request response cannot overwrite a new activation',async()=>{
  let resolveOld!:(value:unknown)=>void;
  vi.mocked(api).mockImplementation(async path=>path.includes('test-activation')?new Promise(resolve=>{resolveOld=resolve;}):{...record,id:'second',systemName:'第二台电脑'});
  function Switch(){const navigate=useNavigate();return <button onClick={()=>navigate('/?activation=second')}>切换申请</button>;}
  render(<MemoryRouter initialEntries={['/?activation=test-activation']}><Switch/><Activation/></MemoryRouter>);
  fireEvent.click(screen.getByRole('button',{name:'切换申请'}));await screen.findByText(/第二台电脑/);
  resolveOld({...record,status:'redeemed'});await new Promise(r=>setTimeout(r,0));expect(screen.queryByText(/测试电脑/)).toBeNull();expect(sessionStorage.getItem('remodex.activation.completed')).toBeNull();
 });
});
