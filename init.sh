#!/usr/bin/env bash
# 一键初始化 Javinizer 并把 API Token 写入 .env，无需打开 Web UI。
# 幂等：可重复执行，已初始化的部分会自动跳过。
set -euo pipefail
cd "$(dirname "$0")"

info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$1"; }

compose() { docker compose "$@"; }

# 读取 .env 中某个键的值（不 source，避免注释和特殊字符出问题）
env_get() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# 写入/覆盖 .env 中的键值（BSD/GNU sed 通用：重写整个文件）
env_set() {
  local key="$1" val="$2"
  if grep -qE "^$key=" .env; then
    awk -v k="$key" -v v="$val" -F= 'BEGIN{OFS="="} $1==k{print k, v; next} {print}' .env > .env.tmp
    mv .env.tmp .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

# ---------- 1. 准备 .env 和数据目录 ----------
if [ ! -f .env ]; then
  info "创建 .env"
  cp .env.example .env
  env_set PUID "$(id -u)"
  env_set PGID "$(id -g)"
fi
mkdir -p gateway-data javinizer-data

# GATEWAY_TOKEN 仍是占位符时自动生成随机值
if [ "$(env_get GATEWAY_TOKEN)" = "change-me" ] || [ -z "$(env_get GATEWAY_TOKEN)" ]; then
  info "生成随机 GATEWAY_TOKEN"
  env_set GATEWAY_TOKEN "$(openssl rand -hex 32)"
fi

# ---------- 2. 启动 Javinizer 并等待健康 ----------
info "启动 Javinizer"
compose up -d javinizer

PORT="$(env_get JAVINIZER_HOST_PORT)"; PORT="${PORT:-8765}"
info "等待 Javinizer 健康检查 (127.0.0.1:$PORT)"
for i in $(seq 1 60); do
  if curl -fsS --noproxy '*' -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null; then
    info "Javinizer 已就绪"
    break
  fi
  [ "$i" = 60 ] && { warn "等待超时，请检查 'docker compose logs javinizer'"; exit 1; }
  sleep 1
done

# ---------- 3. 非交互创建管理员 ----------
# setup 接口只信任 localhost/可信网段，宿主机经端口映射会被判为外部地址，
# 因此必须在容器内部调用 127.0.0.1。
ADMIN_USER="${JAVINIZER_ADMIN_USER:-admin}"
ADMIN_PASS="${JAVINIZER_ADMIN_PASSWORD:-}"

STATUS="$(curl -fsS --noproxy '*' "http://127.0.0.1:$PORT/api/v1/auth/status" 2>/dev/null || echo '{}')"
if printf '%s' "$STATUS" | grep -q '"initialized":true'; then
  info "管理员账号已存在，跳过创建"
else
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    GENERATED_PASS=1
  fi
  info "创建管理员账号 ($ADMIN_USER)"
  BODY="$(ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" python3 -c \
    'import json,os; print(json.dumps({"username":os.environ["ADMIN_USER"],"password":os.environ["ADMIN_PASS"]}))')"
  compose exec -T javinizer sh -c \
    "wget -q -O- --header='Content-Type: application/json' --post-data='$BODY' \
     http://127.0.0.1:8765/api/v1/auth/setup" >/dev/null \
    || { warn "管理员创建失败，请检查 'docker compose logs javinizer'"; exit 1; }
  env_set JAVINIZER_ADMIN_USER "$ADMIN_USER"
  if [ "${GENERATED_PASS:-0}" = 1 ]; then
    env_set JAVINIZER_ADMIN_PASSWORD "$ADMIN_PASS"
    warn "已生成随机管理员密码并写入 .env（JAVINIZER_ADMIN_PASSWORD），登录 Web UI 时使用"
  fi
fi

# ---------- 4. 生成 API Token ----------
# token create 直接写数据库，不依赖登录态。
if [ -n "$(env_get JAVINIZER_TOKEN)" ]; then
  info "JAVINIZER_TOKEN 已存在，跳过生成"
else
  info "生成 Javinizer API Token"
  # 该命令会把启动日志和 JSON 混在一起输出，只截取第一个 "{" 之后的部分。
  RAW="$(compose exec -T javinizer javinizer token create --name metadata-gateway --json 2>/dev/null || true)"
  TOKEN="$(printf '%s' "$RAW" | python3 -c '
import sys, json
raw = sys.stdin.read()
i = raw.find("{")
print(json.loads(raw[i:]).get("token", "") if i >= 0 else "")' 2>/dev/null || true)"
  [ -z "$TOKEN" ] && { warn "Token 生成失败"; exit 1; }
  env_set JAVINIZER_TOKEN "$TOKEN"
  info "Token 已写入 .env"
fi

# ---------- 5. 启动全部服务 ----------
info "启动全部服务"
compose up -d --build

if [ -z "$(env_get STASH_BOX_API_KEY)" ]; then
  warn "STASH_BOX_API_KEY 为空，western（欧美）刮削不可用；请按 README 获取后填入 .env 并重新执行 'docker compose up -d'"
fi

info "完成。网关地址 http://127.0.0.1:11503，GATEWAY_TOKEN 见 .env"
