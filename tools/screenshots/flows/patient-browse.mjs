/**
 * 患者下单路径（录屏用，不含提交）
 *
 * 刻意在「确认预约」页停住，不点提交：
 * 1. 限购是「同一就诊人同一就诊日 1 单」，录一次就写一张单，重复录制会把额度占满；
 * 2. 演示只需要展示「路径够短、页面够清楚」，真实下单在 README 的 5 分钟剧本里由人工点。
 *
 * 选择器全部来自 probe-walk 实测；每步之间给 700–900ms 节奏，GIF 才看得清。
 */
import { URLS } from '../lib/env.mjs';

const PACE = 1500;

/**
 * @param {import('playwright').Page} page 已登录患者账号的页面
 */
export async function runPatientBrowse(page, { skipHomeWait = false } = {}) {
  // 登录成功后本来就在首页，**不要再 goto**：会与登录后的首屏请求撞上 request.ts 的
  // 「500ms 同 URL 去重」，页面直接显示「请勿重复提交」（实测踩到）。这里只等卡片。
  if (!skipHomeWait) {
    await page.locator('.home__campuses .appt-card').first().waitFor({ timeout: 12000 }).catch(async () => {
      // 万一仍进了错误态，点一次「重试」而不是刷新（刷新会重置录屏节奏）
      const retry = page.getByText('重试').first();
      if (await retry.count()) await retry.click();
    });
    await page.locator('.home__campuses .appt-card').first().waitFor({ timeout: 20000 });
  }
  await page.waitForTimeout(PACE);

  // 选院区（用接口里的真实院区名点，避免写死「东院区」）
  const campus = await (await fetch(`${URLS.h5}/dev-api/appt/public/campus/list`)).json();
  const campusName = campus.data?.[0]?.name ?? '东院区';
  await page.getByText(campusName, { exact: false }).first().click();
  await page.locator('.dept__row').first().waitFor({ timeout: 20000 });
  await page.waitForTimeout(PACE);

  // 选科室
  await page.locator('.dept__row').first().click();
  await page.locator('.doctor-card').first().waitFor({ timeout: 20000 });
  await page.waitForTimeout(PACE);

  // 选医生
  await page.locator('.doctor-card').first().click();
  await page.getByText('查看排班').first().waitFor({ timeout: 20000 });
  await page.waitForTimeout(PACE);

  // 进排班
  await page.getByText('查看排班').first().click();
  await page.locator('.date-strip__cell').first().waitFor({ timeout: 20000 });
  await page.waitForTimeout(PACE);

  // 选日期（挑一个有点的日期格）
  const dated = page.locator('.date-strip__cell:has(.date-strip__dot)').first();
  const cell = (await dated.count()) ? dated : page.locator('.date-strip__cell').nth(1);
  await cell.click();
  await page.waitForTimeout(PACE);

  // 排班页：先选午别（上午/下午），再点医生行进入选时间
  const period = page.locator('.schedule__period').first();
  if (await period.count()) {
    await period.click();
    await page.waitForTimeout(PACE);
  }
  const row = page.locator('.schedule__row').first();
  if (await row.count()) {
    await row.click();
    await page.waitForTimeout(PACE);
  }

  // 选时段（科室视角是「选医生」，医生视角直接是号源格）
  const slot = page.locator('.slot-grid__cell').first();
  if (await slot.count()) {
    await slot.click();
    await page.waitForTimeout(PACE);
    const next = page.getByText('下一步').first();
    if (await next.count()) {
      await next.click();
      await page.getByText('确认预约').first().waitFor({ timeout: 20000 }).catch(() => {});
    }
  }
  await page.waitForTimeout(1800);
}
