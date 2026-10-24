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
  'h5-home': { kind: 'h5', role: 'patient', path: '/pages/index/index', wait: '.home__campus, .home__grid' },
  'h5-campus': { kind: 'h5', role: 'patient', path: '/pages/campus/index', wait: '.campus__card' },
  'admin-dashboard': { kind: 'admin', role: 'admin', path: '/index', wait: '.board__metric, .el-card' },
  'admin-registration': { kind: 'admin', role: 'admin', path: '/appt/registration', wait: '.el-table' },
  'admin-suspend': { kind: 'admin', role: 'admin', path: '/appt/suspend', wait: '.el-table' },
};

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
      await page.waitForSelector(cfg.wait, { timeout: 20000 });
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
      await page.waitForSelector(cfg.wait, { timeout: 20000 });
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
      await page.goto(`${URLS.admin}${cfg.path}`, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector(cfg.wait, { timeout: 20000 });
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
