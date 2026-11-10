# AGENTS.md — qd-appt-showcase（门面与物料仓）

> 这是**五个业务仓中的第 5 个**，与 `qd-appt-app` / `qd-appt-admin` / `qd-appt-backend` / `qd-appt-docs` 平级；
> 另有一个项目总览仓 `qd-appt-overview`（不含业务代码），与之平级但不在本仓职责内。
> 跨仓操作规范在 `../docs/AGENTS.md`（唯一权威）；红线在 `../docs/redlines.md`；排期与验收在 `../docs/ROADMAP.md`。
> 父目录 `qd-appt/AGENTS.md` 是本地便签（不入库），不要把它复制进来。

## 1. 这个仓放什么

- `README.md`：项目门面（定位、架构图、截图、启动步骤、演示账号、边界声明、接口文档入口）。
- `assets/screenshots/*.png`：**脚本产出**的关键页截图，不允许手工截图。
- `assets/demo.gif`：脚本录制的 15 秒主流程。
- `tools/screenshots/`：Playwright 脚本（自带 `package.json`，不污染其它四个仓的依赖树）。
- `demo.sh`（S14）+ `deploy/`（S16.1）：一键起全栈 / 部署的统一入口。编排拆成五件套，
  `compose.yml`（四个应用，纯镜像）+ `compose.deps.yml`（MySQL/Redis/MinIO，快照自 `../backend/deploy`）
  + `compose.wsl.yml` / `compose.cloud.yml`（目标差异：端口与暴露面）+ `compose.build.yml`（仅本地构建）。
  **部署机只 clone 本仓**（不带 build 那份、不需要兄弟目录）；运行时数据落 `data/`（已忽略），
  端口 / 镜像 tag / 口令走 `deploy/.env`。

## 2. 截图脚本纪律（硬约束）

1. **禁止 `sleep`**：等待一律 `waitForSelector` / `waitForURL` / `expect(locator).toBeVisible()`；
   唯一允许 `waitForTimeout(260)` 做动效收尾，且必须写注释说明原因。
2. **固定视口**：H5 `390×844`（`deviceScaleFactor: 2`），后台 `1440×900`（`deviceScaleFactor: 1`）；
   统一 `locale: zh-CN`、`timezoneId: Asia/Shanghai`（否则日期栏与「今日」统计会漂）。
3. **固定输出路径**：`assets/screenshots/<name>.png`，重跑覆盖，不产生带时间戳的新文件。
4. **失败要响**：任一端口不可达或 `captchaEnabled !== false` 时，以非 0 退出并打印「先启动 X」，
   不产出半成品截图。
5. **浏览器复用缓存**：`executablePath` 直指 `~/.cache/ms-playwright/chromium-*/chrome-linux/chrome`，
   安装依赖时置 `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`，不重复下载浏览器。

## 3. 产物标准

| 项 | 阈值 |
|---|---|
| 单张 PNG | ≤ 300 KB |
| `assets/demo.gif` | < 10 MB |
| 总体积 | < 15 MB |
| 画面卫生 | 无地址栏、无调试浮层、无 Element loading 蒙层、无滚动条 |

超阈值时按「`fps` 10 → 8 → 6」「宽 960 → 840」「裁切操作区」依次降级，不降低到看不清。

## 4. 数据纪律（限购）

后端口径是**同一就诊人同一就诊日 1 单**（`ApptConst` 注释，2026-10-23 起）。

- 脚本开跑先取消「今日遗留的 `WAIT_PAY` 单」，释放占位；
- 流程内走「下单 → 支付 → 退号」闭环，让占位自然释放；
- 需要给分诊/看板留数据时，最后保留**一张今日已预约单**；
- 不清库、不删历史数据——手工演示的数据不能被脚本抹掉。

## 5. 门禁

```bash
cd tools/screenshots && node run.mjs --all     # 产物齐全且可重复执行
```

一键演示（S14，静态检查，不起容器）：

```bash
cd showcase
bash -n demo.sh && bash -n deploy/deploy.sh
# 三种组合都必须能渲染，且 wsl/cloud 两套的配置里不能出现 build:
APPT_TAG=v0.1.0 docker compose -f deploy/compose.yml -f deploy/compose.deps.yml -f deploy/compose.wsl.yml config >/dev/null
APPT_TAG=v0.1.0 docker compose -f deploy/compose.yml -f deploy/compose.deps.yml -f deploy/compose.cloud.yml config >/dev/null
APPT_TAG=v0.1.0 docker compose -f deploy/compose.yml -f deploy/compose.deps.yml -f deploy/compose.wsl.yml -f deploy/compose.build.yml config | grep -q 'build:'   # demo 才带 build
```

提交前自查：`git status --short` 无 `node_modules`、`.out`、`*.webm`；产物阈值达标；README 引用的图片文件都存在。
