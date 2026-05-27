#!/usr/bin/env bash
set -euo pipefail

# Reads a topology YAML and generates docker-compose.generated.yml
# Usage: ./generate-compose.sh [topology-file] [output-file]

TOPOLOGY="${1:-topology/default.yaml}"
OUTPUT="${2:-docker-compose.generated.yml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required. Install: brew install yq"
  exit 1
fi

echo "=== Generating docker-compose from $TOPOLOGY ==="

# Read chain config
CHAIN_ID=$(yq '.chain.chain_id' "$TOPOLOGY")
DENOM=$(yq '.chain.denom' "$TOPOLOGY")
GENESIS_INIT_IMAGE=$(yq -r '.images.genesis_init // .images.validator' "$TOPOLOGY")
VALIDATOR_IMAGE=$(yq -r '.images.validator' "$TOPOLOGY")
COSMOVISOR_IMAGE=$(yq -r '.images.cosmovisor // .images.validator' "$TOPOLOGY")
SP_IMAGE=$(yq -r '.images.storage_provider' "$TOPOLOGY")
MOCA_CMD_IMAGE=$(yq -r '.images.moca_cmd // ""' "$TOPOLOGY")

# Read port bases
RPC_BASE="${RPC_BASE_OVERRIDE:-$(yq '.ports.rpc_base' "$TOPOLOGY")}"
GRPC_BASE="${GRPC_BASE_OVERRIDE:-$(yq '.ports.grpc_base' "$TOPOLOGY")}"
REST_BASE="${REST_BASE_OVERRIDE:-$(yq '.ports.rest_base' "$TOPOLOGY")}"
EVM_RPC_BASE="${EVM_RPC_BASE_OVERRIDE:-$(yq '.ports.evm_rpc_base' "$TOPOLOGY")}"
EVM_WS_BASE="${EVM_WS_BASE_OVERRIDE:-$(yq '.ports.evm_ws_base' "$TOPOLOGY")}"
P2P_BASE="${P2P_BASE_OVERRIDE:-$(yq '.ports.p2p_base' "$TOPOLOGY")}"
SP_GW_BASE="${SP_GW_BASE_OVERRIDE:-$(yq '.ports.sp_gateway_base' "$TOPOLOGY")}"
SP_P2P_BASE="${SP_P2P_BASE_OVERRIDE:-$(yq '.ports.sp_p2p_base' "$TOPOLOGY")}"

# Count validators and SPs
NUM_VALIDATORS=$(yq '.validators | length' "$TOPOLOGY")
NUM_SPS=$(yq '.storage_providers | length' "$TOPOLOGY")
MYSQL_IMAGE=$(yq '.services.mysql.image' "$TOPOLOGY")

cat > "$OUTPUT" <<HEADER
# Auto-generated from $TOPOLOGY — do not edit manually.
# Regenerate with: ./scripts/generate-compose.sh $TOPOLOGY

networks:
  moca-e2e:
    driver: bridge

volumes:
  shared-init:
  mysql-data:

services:

  # === Genesis init (runs once, exits) ===
  genesis-init:
    image: ${GENESIS_INIT_IMAGE}
    volumes:
      - shared-init:/output
      - ${ROOT_DIR}/scripts/init-genesis.sh:/init-genesis.sh:ro
    environment:
      - CHAIN_ID=${CHAIN_ID}
      - DENOM=${DENOM}
      - NUM_VALIDATORS=${NUM_VALIDATORS}
      - NUM_SPS=${NUM_SPS}
      - OUTPUT_DIR=/output
$(for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  MODE=$(yq ".validators[$i].mode" "$TOPOLOGY")
  echo "      - VALIDATOR_${i}_MODE=${MODE}"
done)
$(for key in genesis_account_balance staking_bond_amount sp_min_deposit gov_min_deposit gov_voting_period block_time; do
  VAL=$(yq ".chain.${key}" "$TOPOLOGY")
  echo "      - $(echo "$key" | tr '[:lower:]' '[:upper:]')=${VAL}"
done)
    networks:
      - moca-e2e
    entrypoint: ["/bin/bash", "/init-genesis.sh"]

  # === MySQL (for storage providers) ===
  mysql:
    image: ${MYSQL_IMAGE}
    environment:
      MYSQL_ROOT_PASSWORD: moca
    volumes:
      - mysql-data:/var/lib/mysql
    ports:
      - "3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-pmoca"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks:
      - moca-e2e

HEADER

# === Generate validator services ===
for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  NAME=$(yq ".validators[$i].name" "$TOPOLOGY")
  MODE=$(yq ".validators[$i].mode" "$TOPOLOGY")

  # Select Dockerfile + image tag based on mode
  case "$MODE" in
    cosmovisor) VALIDATOR_SERVICE_IMAGE="${COSMOVISOR_IMAGE}" ;;
    *)          VALIDATOR_SERVICE_IMAGE="${VALIDATOR_IMAGE}" ;;
  esac

  RPC_PORT=$((RPC_BASE + i))
  GRPC_PORT=$((GRPC_BASE + i))
  REST_PORT=$((REST_BASE + i))
  EVM_RPC_PORT=$((EVM_RPC_BASE + i))
  EVM_WS_PORT=$((EVM_WS_BASE + i))
  P2P_PORT=$((P2P_BASE + i))

  cat >> "$OUTPUT" <<VALIDATOR
  # === Validator $i ($MODE) ===
  ${NAME}:
    image: ${VALIDATOR_SERVICE_IMAGE}
    container_name: ${NAME}
    volumes:
      - shared-init:/shared:ro
      - ${ROOT_DIR}/docker/entrypoint-validator.sh:/entrypoint-validator.sh:ro
    environment:
      - VALIDATOR_NAME=${NAME}
      - DENOM=${DENOM}
      - CHAIN_ID=${CHAIN_ID}
    ports:
      - "${RPC_PORT}:26657"
      - "${GRPC_PORT}:9090"
      - "${REST_PORT}:1317"
      - "${EVM_RPC_PORT}:8545"
      - "${EVM_WS_PORT}:8546"
      - "${P2P_PORT}:26656"
    depends_on:
      genesis-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:26657/status"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 60s
    restart: on-failure
    networks:
      - moca-e2e
    entrypoint: ["/bin/bash", "/entrypoint-validator.sh"]

VALIDATOR
done

# === Generate SP services ===
for i in $(seq 0 $((NUM_SPS - 1))); do
  NAME=$(yq ".storage_providers[$i].name" "$TOPOLOGY")
  GW_PORT=$((SP_GW_BASE + i))
  P2P_PORT=$((SP_P2P_BASE + i * 100))

  cat >> "$OUTPUT" <<SP
  # === Storage Provider $i ===
  ${NAME}:
    image: ${SP_IMAGE}
    container_name: ${NAME}
    volumes:
      - shared-init:/shared:ro
      - ${ROOT_DIR}/docker/entrypoint-sp.sh:/entrypoint-sp.sh:ro
    environment:
      - SP_NAME=${NAME}
      - MYSQL_HOST=mysql
      - MYSQL_PORT=3306
      - MYSQL_USER=root
      - MYSQL_PASSWORD=moca
      - RPC_HOST=validator-0
      - RPC_PORT=26657
      - CHAIN_ID=${CHAIN_ID}
      - DENOM=${DENOM}
    ports:
      - "${GW_PORT}:9033"
      - "${P2P_PORT}:9400"
    depends_on:
      mysql:
        condition: service_healthy
      validator-0:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "bash -lc 'exec 3<>/dev/tcp/127.0.0.1/9402'"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 90s
    restart: on-failure
    networks:
      - moca-e2e
    entrypoint: ["/bin/bash", "/entrypoint-sp.sh"]

SP
done

if [ -n "$MOCA_CMD_IMAGE" ] && [ "$MOCA_CMD_IMAGE" != "null" ]; then
cat >> "$OUTPUT" <<MOCACMD
  # === moca-cmd CLI sidecar ===
  moca-cmd:
    image: ${MOCA_CMD_IMAGE}
    container_name: moca-cmd
    environment:
      - RPC_HOST=validator-0
      - RPC_PORT=26657
      - EVM_RPC_PORT=8545
      - CHAIN_ID=${CHAIN_ID}
    volumes:
      # Share /tmp so the host-side test runner can drop payload files here
      # and docker-exec'd moca-cmd reads them by the same path.
      - /tmp:/tmp
    depends_on:
      validator-0:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "test", "-f", "/root/.moca-cmd/account/defaultKey"]
      interval: 2s
      timeout: 2s
      retries: 20
      start_period: 30s
    restart: on-failure
    networks:
      - moca-e2e

MOCACMD
  echo "  moca-cmd: enabled (sidecar)"
else
  echo "  moca-cmd: disabled (no image configured)"
fi

echo "=== Generated $OUTPUT ==="
echo "  Validators: $NUM_VALIDATORS"
echo "  Storage Providers: $NUM_SPS"
echo "  Chain ID: $CHAIN_ID"
