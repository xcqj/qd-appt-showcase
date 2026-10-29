#!/usr/bin/env bash
# 号源 QueueDepth · 统一部署入口（S16.1）
#
# 一份脚本同时服务「本地手工部署」与「GitHub Actions 发布」：本地怎么跑，CI 就怎么跑，
# 不存在"CI 里另有一套逻辑"这种漂移。
#
# 与 demo.sh 的分工：
#   demo.sh    从源码构建四枚镜像起一套给人看（会带 compose.build.yml）
#   deploy.sh  只拉**已发布镜像**起一套可回滚的（**永远不带** compose.build.yml）
#
# 用法：
#   ./deploy.sh <wsl|cloud> up --tag v0.1.0 [--no-pull]
#   ./deploy.sh <wsl|cloud> adopt --tag latest  # 首次：把已在跑的栈接管为 current（回滚落点）
#   ./deploy.sh <wsl|cloud> rollback            # 回到 .state/previous
#   ./deploy.sh <wsl|cloud> status              # 容器状态 + 当前/上一版本 + 业务探活
#   ./deploy.sh <wsl|cloud> backup [--keep N]   # mysqldump + MinIO 打包
#   ./deploy.sh <wsl|cloud> restore <file.sql.gz>
#   ./deploy.sh <wsl|cloud> down | logs
#
# 约定（改动前先读）：
#   ① 目标只由第一个参数决定（wsl / cloud），不存在第二个开关；
#   ② 配置来自 deploy/.env 与可选的 deploy/.env.<target>（后者覆盖前者）；
#      **不 source**：JDBC 串里有 `&`，source 会被 shell 解释（demo.sh 的教训）；
#   ③ 镜像 tag 必须不可变（v0.1.0 / sha-xxxxxxx），**latest 一律拒绝**——回滚依赖 tag 不可变；
#   ④ 回滚只回应用，**不回 schema**：本次发布若含 DDL，脚本只告警不阻断（人工判断）。
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.env"
STATE_DIR="$DEPLOY_DIR/.state"
BACKUP_DIR="$ROOT_DIR/backup"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
say()  { printf "\n${C_CYAN}%s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}  ✓${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}  ! %s${C_RESET}\n" "$*"; }
die()  { printf "\n${C_RED}✗ %s${C_RESET}\n" "$*" >&2; exit 1; }

usage() {
  sed -n "2,/^set -Eeuo pipefail/{/^set -Eeuo pipefail/d;s/^# \{0,1\}//;p;}" "$0"
}

# ---------------------------------------------------------------- 参数
TARGET="${1:-}"
shift || true
[ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$TARGET" in wsl|cloud) ;; *) printf "未知目标：%s（可用：wsl / cloud）\n\n" "$TARGET" >&2; usage >&2; exit 2 ;; esac

CMD="${1:-status}"
shift || true

TAG_ARG=""; NO_PULL=0; KEEP_ARG=""; RESTORE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag)        TAG_ARG="${2:-}"; [ -n "$TAG_ARG" ] || die "--tag 缺少参数"; shift 2 ;;
    --no-pull)    NO_PULL=1; shift ;;
    --keep)       KEEP_ARG="${2:-}"; [ -n "$KEEP_ARG" ] || die "--keep 缺少参数"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "未知选项：$1" ;;
    *)            RESTORE_FILE="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------- 配置
# 不 source：逐行取值。shell 环境变量优先，其次 .env.<target>，最后 .env。
env_raw() {
  local key="$1" def="${2:-}" f line v
  if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
  for f in "$DEPLOY_DIR/.env.$TARGET" "$ENV_FILE"; do
    [ -f "$f" ] || continue
    line="$(grep -E "^[[:space:]]*${key}=" "$f" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$line" ]; then
      v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
  done
  printf '%s' "$def"
}

# compose 插值只认 shell 环境与 deploy/.env，这里把两者统一成环境变量
COMPOSE_KEYS=(
  APPT_REGISTRY APPT_CONTAINER_PREFIX APPT_DATA_DIR
  APPT_API_PORT APPT_ADMIN_PORT APPT_H5_PORT
  APPT_MYSQL_PORT APPT_REDIS_PUBLISH_PORT APPT_MINIO_PORT APPT_MINIO_CONSOLE_PORT
  APPT_SNAILJOB_PORT APPT_SNAILJOB_GRPC_PORT APPT_SNAILJOB_UPSTREAM
  APPT_DB_URL APPT_DB_USERNAME APPT_DB_PASSWORD
  APPT_REDIS_HOST APPT_REDIS_PORT APPT_REDIS_PASSWORD APPT_REDIS_DATABASE
  APPT_MINIO_USER APPT_MINIO_PASSWORD
  APPT_SNAILJOB_ENABLED APPT_SNAILJOB_NAMESPACE APPT_SNAILJOB_DB_URL
  APPT_TZ APPT_PUBLIC_HOST
)
for _k in "${COMPOSE_KEYS[@]}"; do
  _v="$(env_raw "$_k" "")"
  [ -n "$_v" ] && export "${_k}=${_v}"
done
unset _k _v

# 探活与备份要用的值，给默认（与 compose.wsl.yml 对齐）
export APPT_API_PORT="${APPT_API_PORT:-18082}"
export APPT_ADMIN_PORT="${APPT_ADMIN_PORT:-18083}"
export APPT_H5_PORT="${APPT_H5_PORT:-18084}"
export APPT_DB_PASSWORD="${APPT_DB_PASSWORD:-root}"
export APPT_DB_USERNAME="${APPT_DB_USERNAME:-root}"
export APPT_MINIO_USER="${APPT_MINIO_USER:-ruoyi}"
export APPT_MINIO_PASSWORD="${APPT_MINIO_PASSWORD:-ruoyi123}"
APPT_BACKUP_KEEP="$(env_raw APPT_BACKUP_KEEP 7)"
# 非 up 的子命令（status / logs / down）不关心具体版本，但 compose 插值需要变量存在，
# 否则每行服务定义都刷一条「variable is not set」警告。
export APPT_TAG="${APPT_TAG:-latest}"

# 两个目标共用服务定义，只靠项目名与覆盖文件区分；container_name 是全局的，前缀必须跟项目名同源
if [ "$TARGET" = "wsl" ]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-qd-appt-demo}"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-qd-appt-prod}"
fi
export APPT_CONTAINER_PREFIX="${APPT_CONTAINER_PREFIX:-$COMPOSE_PROJECT_NAME}"

COMPOSE_BASE="$DEPLOY_DIR/compose.yml"
COMPOSE_DEPS="$DEPLOY_DIR/compose.deps.yml"
COMPOSE_TARGET="$DEPLOY_DIR/compose.$TARGET.yml"
COMPOSE=(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_DEPS" -f "$COMPOSE_TARGET")

# 数据目录：相对 deploy/ 解析（与 compose 的卷路径同一口径）
DATA_DIR_RAW="${APPT_DATA_DIR:-../data}"
DATA_DIR="$(cd "$DEPLOY_DIR" && cd "$DATA_DIR_RAW" 2>/dev/null && pwd || printf '%s' "$DEPLOY_DIR/$DATA_DIR_RAW")"

CURRENT="$STATE_DIR/current"
PREVIOUS="$STATE_DIR/previous"

# ---------------------------------------------------------------- 工具
state_tag() { [ -f "$1" ] && sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1 || true; }

require_tag() {
  case "$1" in
    ''|latest) die "镜像 tag 必须是不可变版本（v0.1.0 / sha-xxxxxxx），拒绝「$1」：回滚依赖 tag 不可变" ;;
  esac
}

wait_ready() {
  if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 300; then
    warn "容器未在 300s 内全部健康"
    "${COMPOSE[@]}" ps || true
    return 1
  fi
  return 0
}

probe() { # 名称 url [期望子串]
  local name="$1" url="$2" expect="${3:-}" out
  if ! out="$(curl -fsS --max-time 5 "$url" 2>/dev/null)"; then
    warn "$name 探活失败：$url"
    return 1
  fi
  if [ -n "$expect" ]; then
    case "$out" in
      *"$expect"*) ok "$name（返回含 $expect）" ;;
      *) warn "$name 返回不符合预期：$url"; return 1 ;;
    esac
  else
    ok "$name"
  fi
}

probe_all() {
  local failed=0
  # api 直连只在 wsl 目标成立（cloud 目标不发布 api 端口）
  if [ "$TARGET" = "wsl" ]; then
    probe "api 直连" "http://127.0.0.1:${APPT_API_PORT}/appt/public/campus/list" '"code":200' || failed=1
  fi
  # 经 nginx 反代：这条同时验证 APPT_API_UPSTREAM 注入正确（S14 踩过指向错返回 502）
  probe "admin 首页" "http://127.0.0.1:${APPT_ADMIN_PORT}/" || failed=1
  probe "api 经 admin 反代" "http://127.0.0.1:${APPT_ADMIN_PORT}/prod-api/appt/public/campus/list" '"code":200' || failed=1
  probe "h5 首页" "http://127.0.0.1:${APPT_H5_PORT}/" || failed=1
  probe "api 经 h5 反代" "http://127.0.0.1:${APPT_H5_PORT}/dev-api/appt/public/campus/list" '"code":200' || failed=1
  return "$failed"
}

write_state() { # 目标文件 tag
  local file="$1" tag="$2" svc cname image id images=""
  mkdir -p "$STATE_DIR"
  # 用 docker inspect 而不是 compose images 的 --format：不同 compose 版本对模板支持不一致
  for svc in api admin h5 snailjob; do
    cname="${APPT_CONTAINER_PREFIX}-${svc}"
    image="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true)"
    id="$(docker inspect -f '{{.Image}}' "$cname" 2>/dev/null | cut -c1-19 || true)"
    [ -n "$image" ] || continue
    images="${images:+$images,}\"${svc}\":{\"image\":\"${image}\",\"digest\":\"${id}\"}"
  done
  # 单行 JSON：state_tag 用 sed 取 tag，任何多层格式都容易踩空
  printf '{"tag":"%s","target":"%s","deployed_at":"%s","images":{%s}}\n' \
    "$tag" "$TARGET" "$(date -Iseconds)" "$images" > "$file"
}

# ---------------------------------------------------------------- 子命令
cmd_up() {
  local tag="${TAG_ARG:-}"
  require_tag "$tag"

  say "== 发布 $tag → $TARGET =="
  echo "  项目：$COMPOSE_PROJECT_NAME   目录：$DEPLOY_DIR"

  # 含 SQL 变更时只告警：镜像能回滚，schema 不一定（方案 §5.4）
  if git -C "$ROOT_DIR" log --oneline -1 --name-only 2>/dev/null | grep -q '^backend/script/sql/'; then
    warn "本次提交含 backend/script/sql 变更：镜像可回滚，schema 不一定，失败时请人工判断"
  fi

  export APPT_TAG="$tag"

  # 数据目录守卫：已有部署记录、目录里却没有 mysql 数据 → 说明 APPT_DATA_DIR 被改过或换了机器。
  # 空库起来后 api 会因缺表 crash loop（2026-10-30 实测：从 ~/qd-appt-deploy 起栈时
  # `../data` 解析成了 ~/data，白白初始化出一个空库）。宁可停下来问人，也不要静默换库。
  if [ -f "$CURRENT" ] && [ ! -d "$DATA_DIR/mysql" ]; then
    die "数据目录不对：$DATA_DIR/mysql 不存在（APPT_DATA_DIR=${DATA_DIR_RAW}）。
     已存在部署记录却没有数据，拒绝启动空库。确认 APPT_DATA_DIR 指向真实数据后再试。"
  fi

  if [ "$NO_PULL" = "1" ]; then
    warn "--no-pull：使用本地已有镜像（离线演练）"
  else
    say "-- 拉镜像 --"
    "${COMPOSE[@]}" pull || die "镜像拉取失败：确认 $APPT_REGISTRY 可访问、tag 存在（私有包需 docker login ghcr.io）"
  fi

  # 记上一版：前滚前先落盘，中途失败才有的可回
  if [ -f "$CURRENT" ]; then
    cp "$CURRENT" "$PREVIOUS"
    ok "上一版记为 $(state_tag "$PREVIOUS")"
  fi

  say "-- 起栈（up -d --wait）--"
  wait_ready || { warn "起栈失败，未改动 .state/current"; exit 1; }

  say "-- 业务探活 --"
  if ! probe_all; then
    warn "探活未通过 → 自动回滚一次"
    cmd_rollback || die "回滚也失败，请人工介入：$DEPLOY_DIR"
    die "发布失败，已回滚到 $(state_tag "$CURRENT")"
  fi

  write_state "$CURRENT" "$tag"
  ok "已记录 .state/current = $tag"
  echo
  echo "  患者端 H5    http://${APPT_PUBLIC_HOST:-localhost}:${APPT_H5_PORT}"
  echo "  管理后台      http://${APPT_PUBLIC_HOST:-localhost}:${APPT_ADMIN_PORT}"
  echo "  回滚          ./deploy/deploy.sh $TARGET rollback"
}

cmd_rollback() {
  local tag; tag="$(state_tag "$PREVIOUS")"
  # 注意：这里**不**套 require_tag —— 回滚必须能回到"当时真的在跑的那一版"，
  # 包括首次发布前接管的 latest。
  [ -n "$tag" ] || die "没有 .state/previous，无法回滚（首次发布前先用 adopt 接管现有栈）"

  say "== 回滚到 $tag（$TARGET）=="
  export APPT_TAG="$tag"
  "${COMPOSE[@]}" pull || die "上一版镜像拉取失败：$APPT_REGISTRY/appt-*:$tag"
  wait_ready || die "回滚起栈失败，请人工介入"
  probe_all || die "回滚后探活仍失败，请人工介入"

  # 成功：current ↔ previous 互换，保证「回滚」本身也可撤销
  local old_current; old_current="$(state_tag "$CURRENT")"
  write_state "$CURRENT" "$tag"
  if [ -n "$old_current" ]; then write_state "$PREVIOUS" "$old_current"; fi
  ok "已回滚到 $tag（可用 --tag $old_current 前滚回去）"
}

cmd_adopt() { # 把"当前正在跑的一版"登记为 current，作为首次发布的回滚落点
  local tag="${TAG_ARG:-}"
  [ -n "$tag" ] || die "adopt 需要 --tag <当前线上版本>（例如 latest）"
  if [ -f "$CURRENT" ]; then
    die ".state/current 已存在（$(state_tag "$CURRENT")），无需 adopt"
  fi
  write_state "$CURRENT" "$tag"
  ok "已接管现有部署：current = $tag"
  warn "第一次 up 会把它记为 previous，从此回滚才有落点"
}

cmd_status() {
  say "== 部署状态（$TARGET）=="
  echo "  项目：$COMPOSE_PROJECT_NAME"
  echo "  当前版本：$(state_tag "$CURRENT")"
  echo "  上一版本：$(state_tag "$PREVIOUS")"
  echo
  "${COMPOSE[@]}" ps || true
  echo
  say "-- 业务探活 --"
  if probe_all; then ok "全部通过"; else warn "有探针未通过（见上）"; fi
  echo
  echo "  数据目录：$DATA_DIR"
  du -sh "$DATA_DIR" 2>/dev/null || true
}

cmd_backup() {
  local keep="${KEEP_ARG:-$APPT_BACKUP_KEEP}"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"

  say "== 备份（保留 $keep 份）=="
  local sql="$BACKUP_DIR/appt-${ts}.sql.gz"
  if "${COMPOSE[@]}" exec -T mysql sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" appt' 2>/dev/null | gzip > "$sql"; then
    ok "MySQL → $sql（$(du -h "$sql" | cut -f1)）"
  else
    rm -f "$sql"; die "mysqldump 失败：确认 mysql 容器在跑（./deploy.sh $TARGET status）"
  fi

  local tar="$BACKUP_DIR/minio-${ts}.tar.gz"
  if [ -d "$DATA_DIR/minio" ]; then
    if tar czf "$tar" -C "$DATA_DIR" minio 2>/dev/null; then
      ok "MinIO → $tar（$(du -h "$tar" | cut -f1)）"
    else
      warn "MinIO 打包失败（权限？容器属主 999）；跳过，不影响 SQL 备份"
    fi
  else
    warn "未找到 $DATA_DIR/minio，跳过对象存储备份"
  fi

  # 按时间倒序删旧（两类文件各自保留 keep 份）
  for pattern in 'appt-*.sql.gz' 'minio-*.tar.gz'; do
    ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
      rm -f "$old"; warn "清理旧备份：$(basename "$old")"
    done
  done
}

cmd_restore() {
  local file="${RESTORE_FILE:-$1}"
  [ -n "$file" ] || die "restore 需要一个 .sql 或 .sql.gz 文件"
  [ -f "$file" ] || die "备份文件不存在：$file"

  say "== 恢复 $file（$TARGET）=="
  warn "恢复前先停应用，避免恢复过程中有写入"
  "${COMPOSE[@]}" stop api admin h5 || true

  if case "$file" in *.gz) true;; *) false;; esac; then
    gzip -dc "$file" | "${COMPOSE[@]}" exec -T mysql mysql -uroot -p"$APPT_DB_PASSWORD" appt
  else
    "${COMPOSE[@]}" exec -T mysql mysql -uroot -p"$APPT_DB_PASSWORD" appt < "$file"
  fi || die "恢复失败"

  ok "恢复完成，重新起应用"
  "${COMPOSE[@]}" start api admin h5
  wait_ready || die "恢复后起栈失败"
  probe_all || die "恢复后探活未通过"
}

cmd_down() { "${COMPOSE[@]}" down; ok "已停止（数据保留在 $DATA_DIR，镜像保留）"; }
cmd_logs() { "${COMPOSE[@]}" logs -f --tail=100; }

case "$CMD" in
  up)       cmd_up ;;
  adopt)    cmd_adopt ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  backup)   cmd_backup ;;
  restore)  cmd_restore ;;
  down)     cmd_down ;;
  logs)     cmd_logs ;;
  -h|--help|help) usage ;;
  *) printf "未知子命令：%s（可用：up / rollback / status / backup / restore / down / logs）\n\n" "$CMD" >&2; usage >&2; exit 2 ;;
esac
