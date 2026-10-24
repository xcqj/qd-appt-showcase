/**
 * 录制 demo.gif：患者下单路径（首页 → 选院区 → 科室 → 医生 → 排班 → 选时间 → 确认预约页）
 *
 * 两个工程取舍：
 * 1. **先无录像登录拿 storageState，再开录像上下文**——否则 GIF 开头全是登录页，
 *    而且登录失败时的「请勿重复提交」提示会被录进去（实测踩到）。
 * 2. 录像上下文一建立就开始录，页面还在加载 → 前 2 秒是白屏，编码时按 `skipFrames` 丢掉。
 *
 * 用法：node gif.mjs
 */
import { mkdirSync, renameSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CONTEXT_DEFAULTS, launch, newContext } from './lib/browser.mjs';
import { preflight, URLS } from './lib/env.mjs';
import { videoToGif } from './lib/gif.mjs';
import { loginPatient } from './lib/login.mjs';
import { runPatientBrowse } from './flows/patient-browse.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const VIDEO_DIR = join(HERE, '.out');
const OUT = join(HERE, '../../assets/demo.gif');

const W = 540;
const H = 1170;
const FPS = 12;
const SKIP_SECONDS = 2; // 丢掉开录时的白屏

await preflight();
mkdirSync(VIDEO_DIR, { recursive: true });

const browser = await launch();

// ① 不带录像的登录，只为拿登录态
const warmup = await newContext(browser, 'h5');
const warmPage = await warmup.newPage();
await loginPatient(warmPage);
const storage = await warmup.storageState();
await warmup.close();

// ② 带录像的上下文：直接已登录状态开场
const ctx = await browser.newContext({
  ...CONTEXT_DEFAULTS,
  viewport: { width: W, height: H },
  deviceScaleFactor: 1,
  storageState: storage,
  recordVideo: { dir: VIDEO_DIR, size: { width: W, height: H } },
});
const page = await ctx.newPage();
await page.goto(`${URLS.h5}/#/`, { waitUntil: 'domcontentloaded' });
await page.locator('.home__campuses .appt-card').first().waitFor({ timeout: 20000 });

const video = page.video();
await runPatientBrowse(page, { skipHomeWait: true });

await ctx.close();
const raw = join(VIDEO_DIR, 'demo.webm');
await video.saveAs(raw);
await browser.close();

// ③ 转 GIF：超 10MB 就逐级降参
const attempts = [
  { fps: FPS, width: W, skipFrames: SKIP_SECONDS * FPS },
  { fps: 10, width: W, skipFrames: SKIP_SECONDS * 10 },
  { fps: 8, width: 480, skipFrames: SKIP_SECONDS * 8 },
];
let finalSize = 0;
for (const opt of attempts) {
  const { size, frames } = videoToGif(raw, OUT, opt);
  finalSize = size;
  console.log(`  尝试 fps=${opt.fps} width=${opt.width} → ${frames} 帧 / ${(size / 1024 / 1024).toFixed(2)} MB`);
  if (size < 10 * 1024 * 1024) break;
}

if (finalSize > 10 * 1024 * 1024) {
  console.error('GIF 仍超过 10MB，请调低 fps/宽度或缩短流程');
  process.exit(1);
}
console.log(`\n✓ assets/demo.gif  ${(finalSize / 1024).toFixed(0)} KB`);
