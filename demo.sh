#!/usr/bin/env bash
# 号源 QueueDepth · 一键演示（S14；S16.1 改为复用五件套编排）
#
# 前提：本机只装 Docker（含 compose v2.20+），五个仓同级 clone：
#   qd-appt/{backend,admin,app,docs,showcase}
#
# 做的事（每步都有健康检查与失败提示）：
#   ① 检查 Docker / compose / 仓库布局 / 端口占用
#   ② 准备镜像：先尝试 ghcr，拉不到则本地构建（构建放在起依赖之前，避免数据卷属主阻断 build context）
#   ③ 起依赖：MySQL 3307 · Redis 6380 · MinIO 9010-9011（deploy/compose.deps.yml，依赖只绑 127.0.0.1）
#   ④ 建库 + 全量导入演示数据（backend/deploy/init-db.sh --full，含 SnailJob 表与任务种子）
#   ⑤ 建 MinIO bucket（失败只告警：封面/头像是外链占位图）
#   ⑥ 起 SnailJob 服务端（必须排在建库之后：它启动即查 sj_* 表）
#   ⑦ 起三端并逐端探活，打印访问地址与演示账号
#
# 编排（S16.1 起拆成五件套，本脚本带前四份；部署走 deploy/deploy.sh，**不带** build 那份）：
#   compose.yml + compose.deps.yml + compose.wsl.yml + compose.build.yml
#
# 用法：
#   ./demo.sh              # 起全栈（默认）
#   ./demo.sh down         # 停止容器，保留数据
#   ./demo.sh reset        # 停止并删数据卷（二次确认；bind mount 目录需手工清，脚本会提示）
#   ./demo.sh logs         # 跟随三端日志
#   ./demo.sh --help
#
# 可调参数：deploy/.env（从 deploy/.env.example 复制），或同名环境变量。
# --- demo.sh 头部说明到此（usage 依赖此行，勿删，也勿在其上方插入非注释行）
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
DEPLOY_DIR="$ROOT_DIR/deploy"
COMPOSE_BASE="$DEPLOY_DIR/compose.yml"
COMPOSE_DEPS="$DEPLOY_DIR/compose.deps.yml"
COMPOSE_TARGET="$DEPLOY_DIR/compose.wsl.yml"
COMPOSE_BUILD="$DEPLOY_DIR/compose.build.yml"
ENV_FILE="$DEPLOY_DIR/.env"
INIT_DB="$PARENT_DIR/backend/deploy/init-db.sh"
DATA_DIR="$ROOT_DIR/data"                                  # demo 数据卷（与开发机的 backend/deploy/data 隔离）
BUILD_CONTEXT_DATA="$PARENT_DIR/backend/deploy/data"       # 开发机既有数据卷：构建上下文会遍历到
SQL_DIR="$PARENT_DIR/backend/script/sql"
COMPOSE=(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_DEPS" -f "$COMPOSE_TARGET")
# 给 init-db.sh 用：它按冒号分隔解析多份编排（单路径仍兼容）
COMPOSE_FILES_SERIAL="$COMPOSE_BASE:$COMPOSE_DEPS:$COMPOSE_TARGET"
# 报错提示里可直接复制的命令前缀（提示要能"复制就跑"，因此带 cd）
COMPOSE_HINT="cd $DEPLOY_DIR && docker compose -f compose.yml -f compose.deps.yml -f compose.wsl.yml"

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-qd-appt-demo}"
# 容器名前缀必须跟项目名一致：否则同名容器会跨项目相撞（compose 的 container_name 是全局的）
export APPT_CONTAINER_PREFIX="${APPT_CONTAINER_PREFIX:-$COMPOSE_PROJECT_NAME}"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
CURRENT_STEP="初始化"
FIX_HINT=""

say()  { printf "\n${C_CYAN}%s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}  ✓${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}  ! %s${C_RESET}\n" "$*"; }
die()  {
  printf "\n${C_RED}✗ %s${C_RESET}\n" "$*" >&2
  [ -n "$FIX_HINT" ] && printf "  修复：%s\n" "$FIX_HINT" >&2
  printf "  查看日志：%s logs --tail=80\n" "$COMPOSE_HINT" >&2
  exit 1
}

on_error() {
  local code=$?
  trap - ERR
  printf "\n${C_RED}✗ 失败于步骤「%s」（退出码 %s）${C_RESET}\n" "$CURRENT_STEP" "$code" >&2
  [ -n "$FIX_HINT" ] && printf "  修复：%s\n" "$FIX_HINT" >&2
  printf "  查看日志：%s logs --tail=80\n" "$COMPOSE_HINT" >&2
  exit "$code"
}
trap on_error ERR

usage() {
  # 以头部哨兵注释为界，避免以后加删注释行导致行号错位
  sed -n "2,/^# --- demo.sh 头部说明到此/{/^# --- demo.sh 头部说明到此/d;s/^# \{0,1\}//;p;}" "$0"
}

# 从 deploy/.env 读一个键（不 source，避免 URL 里的 & 被 shell 解释）
env_get() {
  local key="$1" def="${2:-}" line v
  # 同名 shell 环境变量优先（例如 APPT_API_PORT=18082 ./demo.sh）
  if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
  if [ -f "$ENV_FILE" ]; then
    line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$line" ]; then
      v="${line#*=}"
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
  fi
  printf '%s' "$def"
}

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

# 只认本演示项目的容器（qd-appt-demo-*）：开发机的 qd-appt-redis 等占着的端口不算「自己的」
port_is_ours() {
  docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null \
    | grep -F ":$1->" | cut -d'|' -f1 | grep -q '^qd-appt-demo' || return 1
}

# 某个键是否被「显式指定」过（shell 环境变量或 deploy/.env）——显式指定就不自动改，避免猜错用户意图
env_has() {
  local key="$1"
  [ -n "${!key:-}" ] && return 0
  [ -f "$ENV_FILE" ] && grep -qE "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null
}

# 端口自动避让：默认端口被别的进程占用时，按 APPT_PORT_OFFSET（默认 +10000）换一个空闲端口，
# 并打印实际使用的端口；若端口是用户显式指定的，则不擅自更换，直接报错给出两种解法。
# 注意：提示必须走 stderr，本函数在 $(...) 里调用。
resolve_port() {
  local name="$1" def="$2" var="$3" port i
  port="$def"
  if port_in_use "$port" && ! port_is_ours "$port"; then
    if env_has "$var"; then
      FIX_HINT="改 $ENV_FILE 里的 $var，或释放端口：lsof -i :$port"
      die "$name端口 $port 已被占用（该端口是你显式指定的，不自动更换）"
    fi
    port=$((def + PORT_OFFSET))
    for i in $(seq 1 100); do
      # 空闲、或已被本项目的上一次运行占用（复跑时应沿用同一端口）
      if ! port_in_use "$port" || port_is_ours "$port"; then break; fi
      port=$((port + 1))
    done
    printf "%s 端口 %s 被占用 → 自动改用 %s（想固定下来就写进 %s 的 %s）\n" \
      "$name" "$def" "$port" "$ENV_FILE" "$var" >&2
  fi
  printf '%s' "$port"
}

check_compose() {
  local v major minor
  v="$(docker compose version --short 2>/dev/null | sed 's/^v//')" || die "docker compose 不可用（需要 compose v2 插件）"
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  case "$major$minor" in *[!0-9]*) die "无法识别 compose 版本：$v" ;; esac
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 20 ]; }; then
    FIX_HINT="升级 Docker Compose 到 2.20+（本编排用 include）"
    die "compose 版本过低：$v"
  fi
}

# BuildKit 会把构建上下文整棵树走一遍；MySQL/Redis 容器写出的目录常是 root/999 属主，
# 一旦不可读，build 直接报 `error from sender: open ...: permission denied`。
# 这里用一次性 root 容器放开只读权限（只用 Docker，不需要宿主机 sudo）。
ensure_build_context_readable() {
  [ -d "$BUILD_CONTEXT_DATA" ] || return 0
  if ls -R "$BUILD_CONTEXT_DATA" >/dev/null 2>&1; then
    return 0
  fi
  warn "build context 内有不可读目录（$BUILD_CONTEXT_DATA，容器属主），用一次性容器放开读权限"
  docker run --rm -v "$BUILD_CONTEXT_DATA:/data" alpine:3.20 sh -c 'chmod -R o+rX /data' >/dev/null 2>&1 || {
    warn "放开权限失败：构建可能报 permission denied；可手工执行 rm -rf $BUILD_CONTEXT_DATA 后重试"
  }
}

wait_http() {
  local name="$1" url="$2" tries="${3:-45}" i
  for i in $(seq 1 "$tries"); do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 5 "$url" >/dev/null 2>&1 && { ok "$name 已就绪（$url）"; return 0; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 5 -O /dev/null "$url" >/dev/null 2>&1 && { ok "$name 已就绪（$url）"; return 0; }
    else
      warn "本机没有 curl/wget，跳过 HTTP 探活：$name"
      return 0
    fi
    sleep 2
  done
  FIX_HINT="$COMPOSE_HINT logs --tail=120"
  die "$name 在 $((tries * 2))s 内未响应"
}

wait_api() {
  local i body
  for i in $(seq 1 60); do
    if command -v curl >/dev/null 2>&1; then
      body="$(curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/appt/public/campus/list" 2>/dev/null || true)"
      case "$body" in
        *'"code":200'*) ok "后端已就绪（匿名院区接口返回 200）"; return 0 ;;
      esac
    elif port_in_use "$API_PORT"; then
      ok "后端端口 $API_PORT 已监听（未装 curl，仅做端口探活）"
      return 0
    fi
    sleep 2
  done
  FIX_HINT="$COMPOSE_HINT logs --tail=120 api"
  die "后端 120s 内未就绪"
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

prepare_images() {
  say "== ② 准备镜像（$REGISTRY/appt-*:${TAG}）=="
  local pull_ok=0
  if [ "$(env_get APPT_PULL 1)" = "1" ]; then
    if "${COMPOSE[@]}" pull api admin h5 snailjob; then
      pull_ok=1
      ok "已拉取四个镜像"
    else
      warn "$REGISTRY 拉取失败（未发布 / 未登录 / 网络不通），改用本地构建"
    fi
  fi
  [ "$pull_ok" = "1" ] && return 0

  if image_exists "$REGISTRY/appt-api:${TAG}" \
    && image_exists "$REGISTRY/appt-admin:${TAG}" \
    && image_exists "$REGISTRY/appt-h5:${TAG}" \
    && image_exists "$REGISTRY/appt-snailjob:${TAG}"; then
    ok "本地已有四个镜像（跳过构建）"
    return 0
  fi

  say "== ② 本地构建四个镜像（首次 5–15 分钟）=="
  ensure_build_context_readable
  # build 段在 compose.build.yml：只有 demo 带它，部署链路不带
  if ! "${COMPOSE[@]}" -f "$COMPOSE_BUILD" build api admin h5 snailjob; then
    FIX_HINT="单看后端：cd $DEPLOY_DIR && docker compose -f compose.yml -f compose.deps.yml -f compose.wsl.yml -f compose.build.yml build api；若报 permission denied，先 rm -rf $DATA_DIR"
    die "镜像构建失败"
  fi
  ok "三个镜像构建完成"
}

cmd_up() {
  CURRENT_STEP="检查 Docker"
  say "== ① 环境检查 =="
  command -v docker >/dev/null 2>&1 || { FIX_HINT="安装 Docker：https://docs.docker.com/engine/install/"; die "未找到 docker"; }
  docker info >/dev/null 2>&1 || { FIX_HINT="Linux: sudo systemctl start docker；macOS: 启动 Docker Desktop"; die "Docker 守护进程未运行"; }
  check_compose
  ok "Docker 与 compose 可用"

  CURRENT_STEP="检查仓库布局"
  local repo
  for repo in backend admin app; do
    [ -d "$PARENT_DIR/$repo" ] || {
      FIX_HINT="五个仓需同级 clone：git clone git@github.com:xcqj/qd-appt-$repo.git"
      die "缺少目录 $PARENT_DIR/$repo"
    }
  done
  [ -f "$INIT_DB" ] || die "缺少 $INIT_DB（backend 仓不完整？）"
  for f in "$COMPOSE_BASE" "$COMPOSE_DEPS" "$COMPOSE_TARGET" "$COMPOSE_BUILD"; do
    [ -f "$f" ] || die "缺少 $f（deploy 五件套未就位？）"
  done
  ok "backend / admin / app 均在同级目录"

  CURRENT_STEP="分配端口"
  PORT_OFFSET="$(env_get APPT_PORT_OFFSET 10000)"
  case "$PORT_OFFSET" in ''|*[!0-9]*) PORT_OFFSET=10000 ;; esac
  # 演示态固定 18xxx（与开发态 8xxx 分开，且与 Cloudflare 隧道指向的 18083/18084 对齐）
  API_PORT="$(resolve_port "后端" "$(env_get APPT_API_PORT 18082)" APPT_API_PORT)"
  ADMIN_PORT="$(resolve_port "管理后台" "$(env_get APPT_ADMIN_PORT 18083)" APPT_ADMIN_PORT)"
  H5_PORT="$(resolve_port "H5" "$(env_get APPT_H5_PORT 18084)" APPT_H5_PORT)"
  # MySQL 必须保持 3307：init-db.sh 以「端口==3307」判定走 compose 还是直连宿主机
  MYSQL_PORT="$(resolve_port "MySQL" "$(env_get APPT_MYSQL_PORT 3307)" APPT_MYSQL_PORT)"
  REDIS_PORT="$(resolve_port "Redis" "$(env_get APPT_REDIS_PUBLISH_PORT 6380)" APPT_REDIS_PUBLISH_PORT)"
  MINIO_PORT="$(resolve_port "MinIO" "$(env_get APPT_MINIO_PORT 9010)" APPT_MINIO_PORT)"
  MINIO_CONSOLE_PORT="$(resolve_port "MinIO 控制台" "$(env_get APPT_MINIO_CONSOLE_PORT 9011)" APPT_MINIO_CONSOLE_PORT)"
  SNAILJOB_PORT="$(resolve_port "SnailJob 控制台" "$(env_get APPT_SNAILJOB_PORT 18800)" APPT_SNAILJOB_PORT)"
  # 宿主 17888 常被开发机的 SnailJob 占用，默认就放大到 27888（容器内仍是 17888）
  SNAILJOB_GRPC_PORT="$(resolve_port "SnailJob gRPC" "$(env_get APPT_SNAILJOB_GRPC_PORT 27888)" APPT_SNAILJOB_GRPC_PORT)"
  PUBLIC_HOST="$(env_get APPT_PUBLIC_HOST localhost)"
  TAG="$(env_get APPT_TAG latest)"
  REGISTRY="$(env_get APPT_REGISTRY ghcr.io/xcqj)"

  # 导出给 compose 插值：脚本读到的值与 compose 实际用的值必须一致
  export APPT_REGISTRY="$REGISTRY"
  export APPT_API_PORT="$API_PORT" APPT_ADMIN_PORT="$ADMIN_PORT" APPT_H5_PORT="$H5_PORT"
  export APPT_MYSQL_PORT="$MYSQL_PORT" APPT_REDIS_PUBLISH_PORT="$REDIS_PORT"
  export APPT_MINIO_PORT="$MINIO_PORT" APPT_MINIO_CONSOLE_PORT="$MINIO_CONSOLE_PORT"
  export APPT_SNAILJOB_PORT="$SNAILJOB_PORT" APPT_SNAILJOB_GRPC_PORT="$SNAILJOB_GRPC_PORT"
  export APPT_TAG="$TAG"

  ok "端口 ${API_PORT}/${ADMIN_PORT}/${H5_PORT}（应用）· ${MYSQL_PORT}/${REDIS_PORT}/${MINIO_PORT}/${SNAILJOB_PORT}（依赖）可用"

  CURRENT_STEP="准备镜像"
  prepare_images

  CURRENT_STEP="启动依赖"
  say "== ③ 启动依赖（MySQL / Redis / MinIO）=="
  if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 240 mysql redis minio; then
    FIX_HINT="$COMPOSE_HINT logs --tail=80 mysql redis minio"
    die "依赖启动失败或健康检查超时"
  fi
  ok "MySQL / Redis / MinIO 均已健康"

  CURRENT_STEP="初始化数据库"
  say "== ④ 建库 + 导入演示数据（--full，首次约 30–60s）=="
  COMPOSE_FILE="$COMPOSE_FILES_SERIAL" \
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
  SQL_DIR="$SQL_DIR" \
    bash "$INIT_DB" --full \
      --oss-endpoint "http://minio:9000" \
      --oss-public-url "$(env_get APPT_OSS_PUBLIC_URL "http://${PUBLIC_HOST}:${MINIO_PORT}")"
  ok "appt 库已就绪"

  CURRENT_STEP="初始化对象存储"
  say "== ⑤ 建 MinIO bucket（appt，匿名只读）=="
  # minio 镜像自带 mc：直接 exec 进容器，不额外拉 minio/mc 镜像
  if "${COMPOSE[@]}" exec -T minio sh -c '
    mc alias set local http://127.0.0.1:9000 ruoyi ruoyi123 >/dev/null 2>&1 &&
    mc mb --ignore-existing local/appt >/dev/null 2>&1 &&
    mc anonymous set download local/appt >/dev/null 2>&1
  '; then
    ok "bucket appt 就绪"
  else
    warn "bucket 初始化失败（封面/头像为外链占位图，主流程不受影响）"
  fi

  CURRENT_STEP="启动 SnailJob"
  # 必须排在建库之后：服务端启动即查 sj_* 表，先起会刷一堆 "table doesn't exist"
  say "== ⑥ 启动 SnailJob 服务端 =="
  if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 240 snailjob; then
    FIX_HINT="$COMPOSE_HINT logs --tail=80 snailjob"
    die "SnailJob 启动失败或健康检查超时"
  fi
  ok "SnailJob 已健康（控制台容器内 8800 / gRPC 17888）"

  CURRENT_STEP="启动应用"
  say "== ⑦ 启动后端 / 管理后台 / H5 =="
  if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 300 api admin h5; then
    FIX_HINT="$COMPOSE_HINT logs --tail=120 api admin h5"
    die "应用启动失败或健康检查超时"
  fi

  CURRENT_STEP="健康检查"
  say "== ⑧ 健康检查 =="
  wait_api
  wait_http "管理后台" "http://127.0.0.1:${ADMIN_PORT}/"
  wait_http "患者端 H5" "http://127.0.0.1:${H5_PORT}/"

  printf "\n${C_GREEN}全栈已就绪${C_RESET}（数据全部虚构，支付为模拟渠道，不提供真实医疗服务）\n\n"
  cat <<EOF
  患者端 H5     http://${PUBLIC_HOST}:${H5_PORT}
  管理后台      http://${PUBLIC_HOST}:${ADMIN_PORT}
  后端接口文档  http://${PUBLIC_HOST}:${API_PORT}/v3/api-docs
  MinIO 控制台  http://${PUBLIC_HOST}:${MINIO_CONSOLE_PORT}   （ruoyi / ruoyi123）
  SnailJob 控制台 http://${PUBLIC_HOST}:${SNAILJOB_PORT}/snail-job   （admin / admin）

  演示账号
    患者      admin / admin123
    分诊      appt_triage / admin123
    管理后台  admin / admin123

  常用命令
    ./demo.sh logs     跟随日志
    ./demo.sh down     停止（保留数据）
    ./demo.sh reset    停止并清数据卷（二次确认）

  首次登录若看到算术验证码，属正常（演示环境未关闭验证码）。
EOF
}

cmd_down() {
  "${COMPOSE[@]}" down
  ok "已停止容器（数据保留在 $DATA_DIR）"
}

cmd_reset() {
  local yes=0 arg ans
  for arg in "$@"; do [ "$arg" = "-y" ] && yes=1; done
  if [ "$yes" != "1" ]; then
    printf "将删除容器与数据卷（演示数据会丢失）。继续？[y/N] "
    read -r ans
    case "$ans" in
      y|Y) ;;
      *) echo "已取消"; return 0 ;;
    esac
  fi
  "${COMPOSE[@]}" down -v
  warn "docker 卷已删除；但 MySQL/Redis/MinIO 用的是 bind mount，目录仍在："
  warn "  $DATA_DIR"
  warn "确认没有其它演示/开发实例在用后，可手工删除：rm -rf $DATA_DIR"
}

case "${1:-up}" in
  up)     shift || true; cmd_up ;;
  down)   shift || true; cmd_down ;;
  reset)  shift || true; cmd_reset "$@" ;;
  logs)   shift || true; "${COMPOSE[@]}" logs -f --tail=100 ;;
  -h|--help|help) usage ;;
  *)
    printf "未知子命令：%s\n\n" "$1" >&2
    usage >&2
    exit 2
    ;;
esac
