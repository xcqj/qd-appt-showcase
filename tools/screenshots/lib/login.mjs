/**
 * 三角色登录（选择器全部来自 probe 实测，不是猜的）
 *
 * - 后台：`input[placeholder=用户名/密码/验证码]` + `.submit-button`（文案是带空格的「登 录」）
 * - H5  ：输入框没有 placeholder（标签在 `.field__label` 里），按 `.field input` 顺序取
 *         0=账号 1=密码 2=验证码；提交按钮是 `.wd-button.is-primary`
 */
import { URLS } from './env.mjs';

async function typeInto(page, locator, value) {
  await locator.waitFor({ state: 'visible' });
  await locator.fill('');
  await locator.type(value, { delay: 12 });
}

/** H5 患者登录，成功后落在首页 tab */
export async function loginPatient(page, { username = 'admin', password = 'admin123' } = {}) {
  await page.goto(`${URLS.h5}/#/pages/login/index`, { waitUntil: 'domcontentloaded' });
  const inputs = page.locator('.field input');
  await inputs.nth(0).waitFor({ state: 'visible' });
  await typeInto(page, inputs.nth(0), username);
  await typeInto(page, inputs.nth(1), password);
  // 验证码已由 screenshot profile 关闭，仍留一个字符以防前端校验
  await typeInto(page, inputs.nth(2), '0');
  await page.locator('.wd-button.is-primary').click();
  await page.waitForFunction(() => !location.hash.includes('/pages/login/index'), null, { timeout: 20000 });
}

/** H5 分诊登录：先清登录态再登分诊账号 */
export async function loginTriage(page) {
  await page.goto(`${URLS.h5}/#/pages/login/index`, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'domcontentloaded' });
  const inputs = page.locator('.field input');
  await inputs.nth(0).waitFor({ state: 'visible' });
  await typeInto(page, inputs.nth(0), 'appt_triage');
  await typeInto(page, inputs.nth(1), 'admin123');
  await typeInto(page, inputs.nth(2), '0');
  await page.locator('.wd-button.is-primary').click();
  // 分诊账号登录后 reLaunch 到分诊签到页
  await page.waitForFunction(() => location.hash.includes('/pages/triage/'), null, { timeout: 20000 });
}

/** 后台登录，成功后进入工作台 */
export async function loginAdmin(page, { username = 'admin', password = 'admin123' } = {}) {
  await page.goto(`${URLS.admin}/`, { waitUntil: 'domcontentloaded' });
  const user = page.locator('input[placeholder="用户名"]');
  if (await user.count()) {
    await typeInto(page, user, username);
    await typeInto(page, page.locator('input[placeholder="密码"]'), password);
    const code = page.locator('input[placeholder="验证码"]');
    if (await code.count()) await typeInto(page, code, '0');
    await page.locator('.submit-button').click();
  }
  await page.waitForURL(/\/index/, { timeout: 20000 });
}
