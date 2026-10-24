# 截图脚本（Playwright）

产出本仓 `assets/screenshots/*.png`。**禁止手工截图**——所有图都必须能由这里重出。

## 前置（三个服务都要在跑）

| 服务 | 端口 | 启动方式 |
|---|---|---|
| 后端 | `18082`（或任意） | `--spring.profiles.active=dev,screenshot`（**只关验证码**，其余同默认） |
| 管理端 | `8083` | `VITE_PROXY_TARGET=http://127.0.0.1:18082 pnpm dev` |
| 患者端 H5 | `8084` | `VITE_PROXY_TARGET=http://127.0.0.1:18082 pnpm dev:h5` |

为什么用 `screenshot` profile：登录页有图形验证码，脚本无法 OCR；该 profile 只关 `captcha.enable`，
**接口加密保持开启**，脚本驱动的是真实 UI，链路与人工点出来的一致。默认 profile 不受影响。

为什么 dev 要指 `VITE_PROXY_TARGET`：`app`/`admin` 的代理默认指向 `8082`，而 `8082` 是带验证码的主实例；
截图实例在 `18082`。不想改端口也可以把 `8082` 直接用 `dev,screenshot` 起，脚本用 `APPT_API` 覆盖即可。

## 运行

```bash
pnpm install --ignore-scripts           # 浏览器不重复下载
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
node run.mjs --shots                    # 10 张单页静帧
node run.mjs --only=h5-home,admin-dashboard
node gif.mjs                            # 录患者下单路径 → assets/demo.gif（14s / 5MB）
node probe.mjs all                      # 诊断：打印登录页真实控件结构
node probe-home.mjs                     # 诊断：首页是否落兜底页、网络请求明细
```

环境变量：`APPT_API`（默认 `http://localhost:18082`）、`APPT_ADMIN`（`8083`）、`APPT_H5`（`8084`）。

## 本机环境是怎么解决的（免 root）

WSL 自带环境缺两样东西，脚本用「私有副本」解决，不动系统：

| 缺什么 | 解法 | 落点 |
|---|---|---|
| `libnspr4 / libnss3 / libasound2` | `apt-get download` + `dpkg -x` | `.libs/root/usr/lib/x86_64-linux-gnu`，启动前挂 `LD_LIBRARY_PATH` |
| 中文字体（否则截图全是方块） | `apt-get download fonts-wqy-zenhei` + `dpkg -x` | `.libs/fonts`，启动前设 `FONTCONFIG_FILE` |

浏览器二进制直接复用 `~/.cache/ms-playwright/chromium-*/`（目录名随版本变，两种布局都探），
避免「Playwright 版本 ↔ 浏览器 revision」不匹配时重复下载。

## GIF 为什么不走 ffmpeg 一步到位

Playwright 自带的 ffmpeg 是**精简构建**：`-muxers` 里没有 `gif`，`-filters` 里也没有
`palettegen/paletteuse`，且 `fps` 滤镜初始化会失败（用 `-r` 代替）。所以 `lib/gif.mjs` 的做法是：

1. `ffmpeg -i demo.webm -r 12 -vf scale=540:-2 frames/%04d.png`（image2 导出，精简构建支持）
2. `fast-png` 解码每帧 → `gifenc` 逐帧量化（256 色）→ 写帧
3. 编码前自动裁掉开头的纯白帧（录像一建立就开始录，页面还在加载）

## 已知约束

- 后台是 history 路由，**整页 `goto` 会丢登录态**（token 不在持久存储）；脚本改为点侧栏菜单，
  且用 DOM click 绕过 Element 折叠子菜单的可见性判定。
- H5 输入框没有 `placeholder`（标签在 `.field__label`），按 `.field input` 序位取：0 账号 / 1 密码 / 2 验证码。
- 截图前注入样式隐藏滚动条、禁用光标；后台额外等 `.el-loading-mask` 消失。
