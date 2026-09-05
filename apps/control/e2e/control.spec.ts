import { test, expect, type Page } from '@playwright/test';
async function login(page: Page) { await page.goto('/login'); await page.getByLabel('管理员账号').fill('test-admin'); await page.getByLabel('管理员密码',{exact:true}).fill('TestAdmin'); await page.getByRole('button',{name:'登录',exact:true}).click(); await expect(page.getByRole('navigation',{name:'主要导航'})).toBeVisible(); }
test('real API approval leaves no stale action after navigation and reload',async({page,request})=>{
 const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
 await login(page);const activation=await(await request.post('/__test/activation')).json();
 await page.goto(activation.url);let approvals=0;page.on('request',req=>{if(req.url().endsWith('/activation/approve'))approvals++;});
 await page.getByRole('button',{name:'批准这台设备'}).click();await expect(page).toHaveURL(/\/admin\/devices$/);
 await expect(page.getByText(/设备已批准，等待电脑/)).toBeVisible();await expect(page.getByRole('button',{name:'批准这台设备'})).toHaveCount(0);
 await page.screenshot({path:'/tmp/remodex-control-devices-light.png',fullPage:true});
 await page.reload();await expect(page.getByRole('button',{name:'批准这台设备'})).toHaveCount(0);
 await page.goto(activation.url);await expect(page.getByRole('navigation')).toBeVisible();await expect(page.getByRole('button',{name:'批准这台设备'})).toHaveCount(0);
 expect(approvals).toBe(1);expect(errors).toEqual([]);
});
test('lost approval response reconciles using authoritative status',async({page,request})=>{
 await login(page);const activation=await(await request.post('/__test/activation')).json();await page.goto(activation.url);
 let approvals=0;await page.route('**/v1/control/activation/approve',async route=>{approvals++;await route.fetch();await route.abort('failed');});
 await page.getByRole('button',{name:'批准这台设备'}).click();await expect(page).toHaveURL(/\/admin\/devices$/);expect(approvals).toBe(1);
});
test('Chinese theme menu and details preserve keyboard focus in narrow layout',async({page})=>{
 const violations:string[]=[];page.on('console',msg=>{if(msg.type()==='error'&&/Content Security Policy|Refused to/.test(msg.text()))violations.push(msg.text());});
 await login(page);await page.setViewportSize({width:390,height:844});
 await page.getByRole('button',{name:'显示主题'}).click();await page.getByRole('menuitem',{name:'深色',exact:true}).click();await expect(page.locator('html')).toHaveClass(/dark/);
 await page.getByRole('link',{name:'开发设备',exact:true}).click();const trigger=page.getByRole('button',{name:'查看详情'}).first();await trigger.click();
 await expect(page.getByRole('dialog')).toBeVisible();await page.keyboard.press('Tab');
 expect(await page.evaluate(()=>!!document.activeElement?.closest('[role="dialog"]'))).toBe(true);
 await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(trigger).toBeFocused();
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);expect(violations).toEqual([]);
 await page.screenshot({path:'/tmp/remodex-control-narrow-dark.png',fullPage:true});
});
