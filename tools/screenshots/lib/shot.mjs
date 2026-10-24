/**
 * 截图落盘（固定路径 + 画面卫生）
 *
 * - 输出固定为 `assets/screenshots/<name>.png`，重跑覆盖，不产生时间戳垃圾；
 * - 截图前注入样式隐藏滚动条、禁用光标闪烁（AGENTS §3 画面卫生）；
 * - 后台页面额外等 Element 的 `v-loading` 蒙层消失。
 */
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const OUT_DIR = join(HERE, '../../assets/screenshots');

const HYGIENE_CSS = `
  ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
  * { caret-color: transparent !important; }
`;

export async function shoot(page, name, { kind = 'h5' } = {}) {
  mkdirSync(OUT_DIR, { recursive: true });
  await page.addStyleTag({ content: HYGIENE_CSS });

  if (kind === 'admin') {
    // Element 的 loading 蒙层：等到页面里没有 .el-loading-mask 再截
    await page.waitForFunction(() => !document.querySelector('.el-loading-mask'), null, { timeout: 15000 }).catch(() => {});
  }

  // 动效时长 120–180ms，额外等 260ms 让过渡收尾（AGENTS §2.1 唯一允许的固定等待）
  await page.waitForTimeout(260);
  const file = join(OUT_DIR, `${name}.png`);
  await page.screenshot({ path: file, fullPage: false });
  console.log(`  ✓ ${name}.png`);
  return file;
}
