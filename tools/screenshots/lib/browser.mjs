/**
 * 浏览器启动与视口约定（tools/screenshots 的唯一入口）
 *
 * 两个环境坑，这里一次解决：
 * 1. **浏览器位置**：直接复用 `~/.cache/ms-playwright/chromium-*` 里已下载的二进制
 *    （目录名随版本变，`chrome-linux` / `chrome-linux64` 都探），避免「Playwright 版本 ↔
 *    浏览器 revision」不匹配时重新下载几百 MB。
 * 2. **系统库缺失**：WSL 默认没有 `libnspr4 / libnss3 / libasound2`，这里在 `.libs/` 下
 *    用 `apt-get download` + `dpkg -x` 解出私有副本（免 root），启动前挂到
 *    `LD_LIBRARY_PATH`，不动系统库、不需要 sudo。
 */
import { chromium } from 'playwright';
import { existsSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL_ROOT = join(HERE, '..');
const CACHE = join(homedir(), '.cache/ms-playwright');

/** H5（患者 / 分诊）与后台的固定视口，见 AGENTS §2.2 */
export const VIEWPORT = {
  h5: { width: 390, height: 844, deviceScaleFactor: 2 },
  admin: { width: 1440, height: 900, deviceScaleFactor: 1 },
};

export const CONTEXT_DEFAULTS = {
  locale: 'zh-CN',
  timezoneId: 'Asia/Shanghai',
};

export function chromiumPath() {
  const candidates = [];
  for (const dir of readdirSync(CACHE)) {
    if (!dir.startsWith('chromium')) continue;
    const base = join(CACHE, dir);
    for (const sub of ['chrome-linux64/chrome', 'chrome-linux/chrome', 'chrome-linux/headless_shell']) {
      candidates.push(join(base, sub));
    }
  }
  const hit = candidates.find((p) => existsSync(p));
  if (!hit) {
    throw new Error('未找到 ms-playwright 缓存中的 chromium：请先 `npx playwright install chromium`');
  }
  return hit;
}

/** 私有依赖库目录（.libs/root/usr/lib/x86_64-linux-gnu），有就挂上，无就按系统库来 */
function withLocalLibs() {
  const libDir = join(TOOL_ROOT, '.libs/root/usr/lib/x86_64-linux-gnu');
  if (!existsSync(libDir)) return;
  const prev = process.env.LD_LIBRARY_PATH;
  process.env.LD_LIBRARY_PATH = prev ? `${libDir}:${prev}` : libDir;
}

export async function launch() {
  withLocalLibs();
  return chromium.launch({
    executablePath: chromiumPath(),
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
}

/** 统一建上下文：视口 + 中文 + 上海时区 + 隐藏滚动条 */
export async function newContext(browser, kind = 'h5', extra = {}) {
  const viewport = VIEWPORT[kind] ?? VIEWPORT.h5;
  return browser.newContext({
    ...CONTEXT_DEFAULTS,
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: viewport.deviceScaleFactor,
    ...extra,
  });
}
