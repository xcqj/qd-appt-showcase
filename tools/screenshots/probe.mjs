/**
 * 选择器探针（一次性工具，跑完可留作诊断）
 *
 * 用途：在写死截图脚本前，把登录页与关键页的真实 DOM 结构打印出来，
 * 避免凭记忆写选择器（本仓 AGENTS §2 要求「选择器来自实测」）。
 *
 * 用法：node probe.mjs [h5|admin]
 */
import { launch, newContext } from './lib/browser.mjs';

const H5 = process.env.APPT_H5 || 'http://localhost:8084';
const ADMIN = process.env.APPT_ADMIN || 'http://localhost:8083';

const which = process.argv[2] || 'all';
const browser = await launch();

async function dump(label, url, kind) {
  const ctx = await newContext(browser, kind);
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  const info = await page.evaluate(() => {
    const brief = (el) => ({
      tag: el.tagName.toLowerCase(),
      cls: el.className?.toString().slice(0, 80),
      placeholder: el.getAttribute?.('placeholder'),
      type: el.getAttribute?.('type'),
      text: (el.innerText || '').trim().slice(0, 24),
    });
    return {
      url: location.href,
      title: document.title,
      inputs: [...document.querySelectorAll('input')].map(brief),
      clickable: [...document.querySelectorAll('[class*=btn], button, [class*=submit], [class*=login__]')]
        .slice(0, 12)
        .map(brief),
    };
  });
  console.log(`\n=== ${label} ===\n${JSON.stringify(info, null, 2)}`);
  await ctx.close();
}

if (which === 'all' || which === 'h5') await dump('H5 登录页', `${H5}/#/pages/login/index`, 'h5');
if (which === 'all' || which === 'admin') await dump('后台登录页', `${ADMIN}/`, 'admin');

await browser.close();
