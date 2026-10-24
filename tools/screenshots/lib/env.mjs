/**
 * 前置检查：三端探活 + 确认验证码已关闭
 *
 * 失败即非 0 退出并给出「先启动 X」的明确指引，不产出半成品截图。
 */
export const URLS = {
  api: process.env.APPT_API || 'http://localhost:18082',
  admin: process.env.APPT_ADMIN || 'http://localhost:8083',
  h5: process.env.APPT_H5 || 'http://localhost:8084',
};

async function ping(url, timeout = 3000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

export async function preflight() {
  const problems = [];

  if (!(await ping(`${URLS.api}/v3/api-docs`))) {
    problems.push(`后端不可达：${URLS.api}（以 --spring.profiles.active=dev,screenshot --server.port=18082 启动）`);
  }
  if (!(await ping(URLS.admin))) {
    problems.push(`后台不可达：${URLS.admin}（cd admin && pnpm dev）`);
  }
  if (!(await ping(URLS.h5))) {
    problems.push(`H5 不可达：${URLS.h5}（cd app && pnpm dev:h5）`);
  }

  if (!problems.length) {
    const res = await fetch(`${URLS.api}/auth/code`);
    const body = await res.json();
    if (body?.data?.captchaEnabled !== false) {
      problems.push('验证码仍开启：请用 screenshot profile 启动后端（application-screenshot.yml 只关 captcha）');
    }
  }

  if (problems.length) {
    console.error('\n前置检查未通过：');
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
  console.log(`前置检查通过：api=${URLS.api} admin=${URLS.admin} h5=${URLS.h5}`);
}
