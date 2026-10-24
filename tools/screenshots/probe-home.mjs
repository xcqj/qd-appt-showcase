/**
 * 诊断：为什么首页落到 offline 兜底页
 *
 * 只做取证，不改业务：
 * - 记录所有 api 请求的 URL / 状态码
 * - 记录 requestfailed（网络层失败）
 * - 记录 console error 与页面异常
 * - 分两个场景对比：登录后自然回首页 vs 直接 goto 首页 URL
 */
import { launch, newContext } from './lib/browser.mjs';
import { URLS } from './lib/env.mjs';
import { loginPatient } from './lib/login.mjs';

const browser = await launch();
const ctx = await newContext(browser, 'h5');
const page = await ctx.newPage();

const log = [];
page.on('requestfailed', (r) => log.push(`FAILED ${r.method()} ${r.url()} :: ${r.failure()?.errorText}`));
page.on('response', async (r) => {
  const u = r.url();
  if (u.includes('/dev-api/')) log.push(`${r.status()} ${u.replace(URLS.h5, '')}`);
});
page.on('console', (m) => {
  if (m.type() === 'error') log.push(`CONSOLE ${m.text().slice(0, 200)}`);
});
page.on('pageerror', (e) => log.push(`PAGEERROR ${e.message.slice(0, 200)}`));

console.log('场景 A：登录后自然回首页');
await loginPatient(page);
await page.waitForTimeout(3000);
console.log('  hash =', await page.evaluate(() => location.hash));
console.log('  文本 =', (await page.evaluate(() => document.body.innerText)).slice(0, 60).replace(/\n/g, ' | '));

console.log('\n场景 B：直接 goto 首页 URL（冷启动）');
log.length = 0;
await page.goto(`${URLS.h5}/#/pages/index/index`, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(4000);
console.log('  hash =', await page.evaluate(() => location.hash));
console.log('  文本 =', (await page.evaluate(() => document.body.innerText)).slice(0, 60).replace(/\n/g, ' | '));

console.log('\n场景 B 期间的网络/控制台记录：');
for (const line of log.slice(0, 20)) console.log('  -', line);

await browser.close();
