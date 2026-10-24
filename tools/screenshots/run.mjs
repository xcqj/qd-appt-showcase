/**
 * 截图入口
 *
 *   node run.mjs --shots            只跑单页静帧
 *   node run.mjs --all              单页 + 流程（含 GIF）
 *   node run.mjs --only=home,admin-dashboard
 *
 * 顺序约束（DESIGN 与限购）：先造数（flows/patient-order）→ 再截分诊与后台看板。
 */
import { launch, newContext } from './lib/browser.mjs';
import { preflight, URLS } from './lib/env.mjs';
import { loginAdmin, loginPatient, loginTriage } from './lib/login.mjs';
import { shoot } from './lib/shot.mjs';

const args = process.argv.slice(2);
const onlyArg = args.find((a) => a.startsWith('--only='));
const only = onlyArg ? onlyArg.slice('--only='.length).split(',') : null;
const runAll = args.includes('--all');

const SHOTS = {
  // 等待条件优先用「页面上一定会出现的文案」，比类名稳（类名会随样式重构变）
  'h5-home': { kind: 'h5', role: 'patient', path: '/pages/index/index', text: '选择就诊院区' },
  'h5-campus': { kind: 'h5', role: 'patient', path: '/pages/campus/index', text: '选择就诊院区' },
  'h5-dept': { kind: 'h5', role: 'patient', path: '/pages/dept/index', text: '去选择院区' },
  'h5-registration-list': { kind: 'h5', role: 'patient', path: '/pages/registration/index', selector: '.record__body' },
  'h5-notice': { kind: 'h5', role: 'patient', path: '/pages/notice/index', selector: '.notice__tab' },
  'triage-sign': { kind: 'h5', role: 'triage', path: '/pages/triage/sign/index', text: '分诊签到' },
  'triage-list': { kind: 'h5', role: 'triage', path: '/pages/triage/list', selector: '.appt-content' },
  'admin-dashboard': { kind: 'admin', role: 'admin', text: '今日预约' },
  'admin-registration': { kind: 'admin', role: 'admin', parents: ['挂号业务', '预约管理'], menu: '挂号单', selector: '.el-table' },
  'admin-suspend': { kind: 'admin', role: 'admin', parents: ['挂号业务'], menu: '停诊登记', selector: '.el-table' },
};

async function waitReady(page, cfg) {
  if (cfg.selector) {
    await page.waitForSelector(cfg.selector, { timeout: 20000 });
    return;
  }
  await page.getByText(cfg.text, { exact: false }).first().waitFor({ state: 'visible', timeout: 20000 });
}

function picked(name) {
  return !only || only.includes(name);
}

async function openPage(browser, kind, hash) {
  const ctx = await newContext(browser, kind);
  const page = await ctx.newPage();
  return { ctx, page, hash };
}

async function main() {
  await preflight();
  const browser = await launch();

  // 患者：一次登录，复用同一 context 截多页
  if (Object.entries(SHOTS).some(([k, v]) => v.role === 'patient' && picked(k))) {
    const ctx = await newContext(browser, 'h5');
    const page = await ctx.newPage();
    await loginPatient(page);
    for (const [name, cfg] of Object.entries(SHOTS)) {
      if (cfg.role !== 'patient' || !picked(name)) continue;
      await page.goto(`${URLS.h5}/#${cfg.path}`, { waitUntil: 'domcontentloaded' });
      await waitReady(page, cfg);
      await shoot(page, name, { kind: 'h5' });
    }
    await ctx.close();
  }

  // 分诊：独立 context（角色不同）
  if (Object.entries(SHOTS).some(([k, v]) => v.role === 'triage' && picked(k))) {
    const ctx = await newContext(browser, 'h5');
    const page = await ctx.newPage();
    await loginTriage(page);
    for (const [name, cfg] of Object.entries(SHOTS)) {
      if (cfg.role !== 'triage' || !picked(name)) continue;
      await page.goto(`${URLS.h5}/#${cfg.path}`, { waitUntil: 'domcontentloaded' });
      await waitReady(page, cfg);
      await shoot(page, name, { kind: 'h5' });
    }
    await ctx.close();
  }

  // 后台
  if (Object.entries(SHOTS).some(([k, v]) => v.role === 'admin' && picked(k))) {
    const ctx = await newContext(browser, 'admin');
    const page = await ctx.newPage();
    await loginAdmin(page);
    for (const [name, cfg] of Object.entries(SHOTS)) {
      if (cfg.role !== 'admin' || !picked(name)) continue;
      if (cfg.menu) {
        // 用 DOM click 导航：Element 折叠子菜单里的项 Playwright 判定「不可见」，但 DOM 上可点，
        // 且整页 goto 会丢登录态（后台 token 不在持久存储里）
        await page.evaluate((titles) => {
          for (const t of titles) {
            const sub = [...document.querySelectorAll('.el-sub-menu__title')].find((e) => e.innerText.trim() === t);
            sub?.click();
          }
        }, cfg.parents ?? []);
        await page.waitForTimeout(400);
        await page.evaluate((menu) => {
          const item = [...document.querySelectorAll('.el-menu-item')].find((e) => e.innerText.trim() === menu);
          item?.click();
        }, cfg.menu);
        await page.waitForTimeout(700);
      }
      await waitReady(page, cfg);
      await shoot(page, name, { kind: 'admin' });
    }
    await ctx.close();
  }

  await browser.close();
  if (!runAll) console.log('\n单页截图结束（--all 才会跑流程与 GIF）');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
