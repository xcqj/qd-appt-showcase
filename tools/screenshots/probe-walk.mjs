/**
 * 诊断：患者下单链路逐步骤探测（为 GIF flows 校准选择器）
 *
 * 每一步都 try/catch，打印「点之前 hash → 点之后 hash」，卡在哪一步一目了然。
 */
import { launch, newContext } from './lib/browser.mjs';
import { URLS } from './lib/env.mjs';
import { loginPatient } from './lib/login.mjs';

const browser = await launch();
const ctx = await newContext(browser, 'h5');
const page = await ctx.newPage();

async function step(label, fn) {
  const before = await page.evaluate(() => location.hash);
  try {
    await fn();
    await page.waitForTimeout(1200);
    const after = await page.evaluate(() => location.hash);
    console.log(`${label}: ${before} -> ${after}${before === after ? '  ⚠ 未跳转' : ''}`);
  } catch (e) {
    console.log(`${label}: 失败 ${e.message.split('\n')[0].slice(0, 90)}`);
  }
}

await loginPatient(page);
await step('去院区页', async () => {
  await page.evaluate(() => { location.hash = '#/pages/campus/index'; });
});
await step('选第一张院区卡', () => page.locator('.campus__card').first().click({ timeout: 3000 }));

// 科室页：类名未知，打印一下
const classes = await page.evaluate(() => [...new Set([...document.querySelectorAll('uni-view[class]')].map((e) => e.className.toString().split(' ')[0]))].slice(0, 18));
console.log('科室页类名:', JSON.stringify(classes));

await step('去科室页(直接)', async () => { await page.evaluate(() => { location.hash = '#/pages/dept/index'; }); });
await step('去医生列表(直接)', async () => { await page.evaluate(() => { location.hash = '#/pages/doctor/list'; }); });
const docClasses = await page.evaluate(() => [...new Set([...document.querySelectorAll('uni-view[class]')].map((e) => e.className.toString().split(' ')[0]))].slice(0, 18));
console.log('医生页类名:', JSON.stringify(docClasses));
await step('点第一张医生卡', () => page.locator('.doctor-card').first().click({ timeout: 3000 }));
await step('查看排班', () => page.getByText('查看排班').first().click({ timeout: 3000 }));

const schClasses = await page.evaluate(() => [...new Set([...document.querySelectorAll('uni-view[class]')].map((e) => e.className.toString().split(' ')[0]))].slice(0, 20));
console.log('排班页类名:', JSON.stringify(schClasses));

await browser.close();
