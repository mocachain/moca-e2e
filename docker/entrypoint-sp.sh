#!/usr/bin/env bash
set -euo pipefail

SP_NAME="${SP_NAME:?SP_NAME required}"
SHARED_DIR="${SHARED_DIR:-/shared}"
SP_HOME="${SP_HOME:-/root/.moca-sp}"
MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-moca}"
RPC_HOST="${RPC_HOST:-validator-0}"
RPC_PORT="${RPC_PORT:-26657}"
CHAIN_ID="${CHAIN_ID:-moca_5151-1}"

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
BS_DB_NAME="bs_${SP_INDEX}"
mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME}; CREATE DATABASE IF NOT EXISTS ${BS_DB_NAME};" 2>/dev/null

# Wait for chain RPC
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

# Verify shared config exists
if [ ! -d "$SHARED_DIR/$SP_NAME" ]; then
  echo "Error: shared config not found at $SHARED_DIR/$SP_NAME"
  exit 1
fi

# Read keys from shared volume
OPERATOR_KEY=$(cat "$SHARED_DIR/$SP_NAME/operator.key" 2>/dev/null || echo "")
FUND_KEY=$(cat "$SHARED_DIR/$SP_NAME/fund.key" 2>/dev/null || echo "")
SEAL_KEY=$(cat "$SHARED_DIR/$SP_NAME/seal.key" 2>/dev/null || echo "")
APPROVAL_KEY=$(cat "$SHARED_DIR/$SP_NAME/approval.key" 2>/dev/null || echo "")
GC_KEY=$(cat "$SHARED_DIR/$SP_NAME/gc.key" 2>/dev/null || echo "")
BLS_KEY=$(cat "$SHARED_DIR/$SP_NAME/bls.key" 2>/dev/null || echo "")
SP_OPERATOR_ADDR=$(cat "$SHARED_DIR/$SP_NAME/operator.addr" 2>/dev/null || echo "")

# Generate full default config using moca-sp
mkdir -p "$SP_HOME"
cd "$SP_HOME"
moca-sp config.dump 2>&1 || true

if [ ! -f "$SP_HOME/config.toml" ]; then
  echo "Error: failed to generate config.toml"
  exit 1
fi

DSN_SPDB="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${DB_NAME}?parseTime=true&multiStatements=true&loc=Local"
DSN_BSDB="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${BS_DB_NAME}?parseTime=true&multiStatements=true&loc=Local"

# Patch config: Chain
sed -i "s|ChainID = '.*'|ChainID = '${CHAIN_ID}'|g" config.toml
sed -i "s|ChainAddress = \[.*\]|ChainAddress = ['http://${RPC_HOST}:${RPC_PORT}']|g" config.toml
sed -i "s|RpcAddress = \[.*\]|RpcAddress = ['http://${RPC_HOST}:8545']|g" config.toml

# Patch config: SpAccount
sed -i "s|SpOperatorAddress = '.*'|SpOperatorAddress = '${SP_OPERATOR_ADDR}'|g" config.toml
sed -i "s|OperatorPrivateKey = '.*'|OperatorPrivateKey = '${OPERATOR_KEY}'|g" config.toml
sed -i "s|FundingPrivateKey = '.*'|FundingPrivateKey = '${FUND_KEY}'|g" config.toml
sed -i "s|SealPrivateKey = '.*'|SealPrivateKey = '${SEAL_KEY}'|g" config.toml
sed -i "s|ApprovalPrivateKey = '.*'|ApprovalPrivateKey = '${APPROVAL_KEY}'|g" config.toml
sed -i "s|GcPrivateKey = '.*'|GcPrivateKey = '${GC_KEY}'|g" config.toml
sed -i "s|BlsPrivateKey = '.*'|BlsPrivateKey = '${BLS_KEY}'|g" config.toml

# Patch config: Gateway (HTTP endpoint)
sed -i "s|HTTPAddress = '.*'|HTTPAddress = '0.0.0.0:9033'|g" config.toml
sed -i "s|DomainName = '.*'|DomainName = '${SP_NAME}:9033'|g" config.toml

# Patch config: Monitor (metrics on 0.0.0.0 for observability)
sed -i "s|MetricsHTTPAddress = '.*'|MetricsHTTPAddress = '0.0.0.0:9400'|g" config.toml
sed -i "s|PProfHTTPAddress = '.*'|PProfHTTPAddress = '0.0.0.0:9401'|g" config.toml
sed -i "s|ProbeHTTPAddress = '.*'|ProbeHTTPAddress = '0.0.0.0:9402'|g" config.toml

# Patch config: SpDB (User, Passwd, Address, Database)
sed -i "/^\[SpDB\]/,/^\[/ { s|User = '.*'|User = '${MYSQL_USER}'|g; }" config.toml
sed -i "/^\[SpDB\]/,/^\[/ { s|Passwd = '.*'|Passwd = '${MYSQL_PASSWORD}'|g; }" config.toml
sed -i "/^\[SpDB\]/,/^\[/ { s|Address = '.*'|Address = '${MYSQL_HOST}:${MYSQL_PORT}'|g; }" config.toml
sed -i "/^\[SpDB\]/,/^\[/ { s|Database = '.*'|Database = '${DB_NAME}'|g; }" config.toml

# Patch config: BsDB
sed -i "/^\[BsDB\]/,/^\[/ { s|User = '.*'|User = '${MYSQL_USER}'|g; }" config.toml
sed -i "/^\[BsDB\]/,/^\[/ { s|Passwd = '.*'|Passwd = '${MYSQL_PASSWORD}'|g; }" config.toml
sed -i "/^\[BsDB\]/,/^\[/ { s|Address = '.*'|Address = '${MYSQL_HOST}:${MYSQL_PORT}'|g; }" config.toml
sed -i "/^\[BsDB\]/,/^\[/ { s|Database = '.*'|Database = '${BS_DB_NAME}'|g; }" config.toml

# Patch config: PieceStore
sed -i "s|Storage = '.*'|Storage = 'file'|g" config.toml
sed -i "s|BucketURL = '.*'|BucketURL = '/data/sp-storage'|g" config.toml

# Patch config: BlockSyncer modules and workers
sed -i "/\[BlockSyncer\]/,/^\[/ { s|Modules = \[.*\]|Modules = ['epoch','bucket','object','payment','group','permission','storage_provider','prefix_tree','virtual_group','sp_exit_events','object_id_map','general']|g; }" config.toml
sed -i "/\[BlockSyncer\]/,/^\[/ { s|Workers = .*|Workers = 50|g; }" config.toml

# Clear log Path so SP logs to stdout and juno gets empty RootDir
sed -i "s|Path = '.*'|Path = ''|g" config.toml

# Ensure storage directory exists
mkdir -p /data/sp-storage

echo "Starting storage provider..."
exec moca-sp \
  --config "$SP_HOME/config.toml" \
  "$@"
