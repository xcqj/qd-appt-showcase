# 号源 QueueDepth · 门面与物料

> 医院门诊预约挂号系统的对外门面仓：截图、演示剧本索引与接口文档入口。
> 代码在四个独立仓（`qd-appt-app` / `qd-appt-admin` / `qd-appt-backend` / `qd-appt-docs`），本仓只放跨仓物料。

## 状态

脚手架阶段（S13 进行中）：目录与脚本骨架已建，截图与 README 正文随 S13 收口补齐。

- `assets/screenshots/` — 由 `tools/screenshots` 脚本产出，禁止手工截图
- `assets/demo.gif` — 15 秒主流程
- `tools/screenshots/` — Playwright 驱动（自带 `package.json`）

## 快速开始

见 `tools/screenshots/README.md`（前置：后端 `8082` 以 `screenshot` profile 启动、后台 `8083`、H5 `8084`）。
