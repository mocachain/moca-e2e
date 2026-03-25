#!/usr/bin/env bash
set -euo pipefail

SP_NAME="${SP_NAME:?SP_NAME required}"
SHARED_DIR="${SHARED_DIR:-/shared}"
SP_HOME="${SP_HOME:-/root/.moca-sp}"
MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-moca}"

echo "=== Starting storage provider: $SP_NAME ==="

# Wait for MySQL
echo "Waiting for MySQL at $MYSQL_HOST:$MYSQL_PORT..."
for i in $(seq 1 60); do
  if mysqladmin ping -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null; then
    echo "MySQL is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Error: MySQL not ready after 60s"
    exit 1
  fi
  sleep 1
done

# Create SP database if not exists
SP_INDEX=$(echo "$SP_NAME" | grep -o '[0-9]*$')
DB_NAME="sp_${SP_INDEX}"
mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" 2>/dev/null

# Wait for chain RPC
RPC_HOST="${RPC_HOST:-validator-0}"
RPC_PORT="${RPC_PORT:-26657}"
echo "Waiting for chain RPC at $RPC_HOST:$RPC_PORT..."
for i in $(seq 1 120); do
  if curl -sf "http://${RPC_HOST}:${RPC_PORT}/status" >/dev/null 2>&1; then
    echo "Chain RPC is ready."
    break
  fi
  if [ "$i" -eq 120 ]; then
    echo "Error: Chain RPC not ready after 120s"
    exit 1
  fi
  sleep 1
done

# Copy SP config from shared volume
if [ -d "$SHARED_DIR/$SP_NAME" ]; then
  mkdir -p "$SP_HOME"
  cp -r "$SHARED_DIR/$SP_NAME/"* "$SP_HOME/" 2>/dev/null || true
else
  echo "Error: shared config not found at $SHARED_DIR/$SP_NAME"
  exit 1
fi

# Update config with actual MySQL connection
if [ -f "$SP_HOME/config.toml" ]; then
  sed -i "s|MYSQL_HOST|${MYSQL_HOST}|g" "$SP_HOME/config.toml"
  sed -i "s|MYSQL_PORT|${MYSQL_PORT}|g" "$SP_HOME/config.toml"
  sed -i "s|MYSQL_PASSWORD|${MYSQL_PASSWORD}|g" "$SP_HOME/config.toml"
  sed -i "s|DB_NAME|${DB_NAME}|g" "$SP_HOME/config.toml"
fi

echo "Starting storage provider..."
exec moca-sp \
  --config "$SP_HOME/config.toml" \
  "$@"
