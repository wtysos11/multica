#!/usr/bin/env bash
# ensure-native-postgres.sh — 检查系统原生 PostgreSQL 是否就绪，并初始化 data/ 目录结构。
# 不启动任何 Docker 容器。
#
# 用法：bash scripts/ensure-native-postgres.sh [env-file]
set -euo pipefail

ENV_FILE="${1:-.env.local}"
WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$WORKSPACE_ROOT/data"

# ---------- 加载 env ----------
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

POSTGRES_DB="${POSTGRES_DB:-multica_local}"
POSTGRES_USER="${POSTGRES_USER:-multica}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-multica}"
DATABASE_URL="${DATABASE_URL:-postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:5432/$POSTGRES_DB?sslmode=disable}"

# ---------- 解析 host/port ----------
db_host="127.0.0.1"
db_port="${POSTGRES_PORT:-5432}"
db_name="$POSTGRES_DB"

parse_database_url() {
  local rest authority hostport path port_part
  rest="${DATABASE_URL#*://}"
  rest="${rest%%\?*}"
  authority="${rest%%/*}"
  path="${rest#*/}"
  [ "$authority" = "$rest" ] && path=""
  hostport="${authority##*@}"
  if [[ "$hostport" == \[* ]]; then
    db_host="${hostport#\[}"; db_host="${db_host%%]*}"
    port_part="${hostport#*\]}"; [[ "$port_part" == :* ]] && db_port="${port_part#:}"
  else
    db_host="${hostport%%:*}"
    [[ "$hostport" == *:* ]] && db_port="${hostport##*:}"
  fi
  [ -n "$path" ] && db_name="${path%%/*}"
}
parse_database_url

# ---------- 查找 psql ----------
PSQL=""
for candidate in \
    /opt/homebrew/bin/psql \
    /usr/local/bin/psql \
    /Applications/Postgres.app/Contents/Versions/latest/bin/psql \
    /usr/bin/psql \
    psql; do
  if command -v "$candidate" > /dev/null 2>&1; then
    PSQL="$candidate"
    break
  fi
done

if [ -z "$PSQL" ]; then
  echo ""
  echo "✗ psql not found. Please install PostgreSQL first:"
  echo ""
  echo "  macOS (Homebrew):  brew install postgresql@17"
  echo "                     brew services start postgresql@17"
  echo "  macOS (Postgres.app): https://postgresapp.com"
  echo ""
  exit 1
fi

# ---------- 检查 PostgreSQL 是否在运行 ----------
echo "==> Checking native PostgreSQL at $db_host:$db_port..."

if ! "$PSQL" -h "$db_host" -p "$db_port" -d postgres -c "SELECT 1" > /dev/null 2>&1; then
  echo ""
  echo "✗ Cannot connect to PostgreSQL at $db_host:$db_port."
  echo "  Ensure PostgreSQL is running. On macOS:"
  echo "    brew services start postgresql@17"
  echo ""
  exit 1
fi

echo "  PostgreSQL is running (superuser: $(whoami))."

# ---------- 确保 DB 用户存在 ----------
# 用当前系统用户（超级用户）连接，不假设存在 postgres role
SUPER_PSQL() {
  "$PSQL" -h "$db_host" -p "$db_port" -d postgres "$@"
}

user_exists="$(SUPER_PSQL -Atqc "SELECT 1 FROM pg_roles WHERE rolname = '$POSTGRES_USER'")"

if [ "$user_exists" != "1" ]; then
  echo "==> Creating role '$POSTGRES_USER'..."
  SUPER_PSQL -c "CREATE USER \"$POSTGRES_USER\" WITH PASSWORD '$POSTGRES_PASSWORD';" > /dev/null
  echo "  Role '$POSTGRES_USER' created."
else
  echo "  Role '$POSTGRES_USER' already exists."
fi

# ---------- 确保数据库存在 ----------
echo "==> Ensuring database '$POSTGRES_DB' exists..."
db_exists="$(SUPER_PSQL -Atqc "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'")"

if [ "$db_exists" != "1" ]; then
  echo "  Creating database '$POSTGRES_DB'..."
  SUPER_PSQL -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";" > /dev/null
  echo "  Database '$POSTGRES_DB' created."
else
  echo "  Database '$POSTGRES_DB' already exists."
fi

echo "✓ PostgreSQL ready (native). Database: $POSTGRES_DB"

# ---------- 创建 data/ 目录结构 ----------
echo "==> Ensuring data directories under $DATA_DIR/..."
mkdir -p "$DATA_DIR/uploads"
mkdir -p "$DATA_DIR/logs"
echo "✓ Data directories ready: $DATA_DIR/"
