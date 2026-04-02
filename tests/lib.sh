#!/usr/bin/env bash
# Shared test helpers for E2E tests running against docker-compose.

# --- Config ---
CHAIN_ID="${CHAIN_ID:-moca_5151-1}"
DENOM="${DENOM:-amoca}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-5151}"
RPC="${RPC:-http://localhost:26657}"
REST="${REST:-http://localhost:1317}"
EVM_RPC="${EVM_RPC:-http://localhost:8545}"
TM_RPC="${TM_RPC:-$RPC}"
FEES="${FEES:-200000000000000amoca}"
VALIDATOR_CONTAINER="${VALIDATOR_CONTAINER:-validator-0}"

# Test key: for local use testaccount (created in genesis), for devnet/testnet use DEVNET_TEST_KEY
if [ "${ENV:-local}" = "local" ]; then
  TEST_KEY="${TEST_KEY:-testaccount}"
  SENDER_KEY="${SENDER_KEY:-validator-0}"
else
  TEST_KEY="${DEVNET_TEST_KEY:-${TEST_KEY:-}}"
  SENDER_KEY="${DEVNET_TEST_KEY:-${SENDER_KEY:-}}"
fi

# Cosmos CLI prefers tcp:// for local CometBFT RPC.
if [[ "$TM_RPC" == http://* ]]; then
  TM_RPC="tcp://${TM_RPC#http://}"
fi

# --- Runtime policy helpers ---
writes_allowed() {
  [ "${ENV:-local}" = "local" ] || [ "${ALLOW_WRITES:-0}" = "1" ] || [ "${E2E_ALLOW_WRITES:-0}" = "1" ]
}

require_write_enabled() {
  local test_name="${1:-write test}"
  if [ "${ENV:-}" = "mainnet" ]; then
    echo "SKIP: not safe for mainnet"
    exit 0
  fi
  if ! writes_allowed; then
    echo "SKIP: ${test_name} requires writes; set ALLOW_WRITES=1 to enable on ${ENV:-unknown}"
    exit 0
  fi
}

# --- Execute mocad either from docker validator or local PATH ---
# Set MOCAD_HOME to point mocad at the keyring with your test key.
# Example: MOCAD_HOME=~/.mocad-devnet make test ENV=devnet
MOCAD_HOME="${MOCAD_HOME:-}"

exec_mocad() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${VALIDATOR_CONTAINER}$"; then
    docker exec "$VALIDATOR_CONTAINER" mocad "$@" --home /root/.mocad 2>/dev/null
    return $?
  fi
  if command -v mocad >/dev/null 2>&1; then
    local extra_args=()
    [ -n "$MOCAD_HOME" ] && extra_args+=(--home "$MOCAD_HOME")
    # For remote envs, pass --evm-node to avoid localhost:8545 fallback
    if [ "${ENV:-local}" != "local" ] && [ -n "${EVM_RPC:-}" ]; then
      extra_args+=(--evm-node "$EVM_RPC")
    fi
    mocad "$@" "${extra_args[@]}" 2>/dev/null
    return $?
  fi
  echo "ERROR: mocad not found (no ${VALIDATOR_CONTAINER} container and no local mocad on PATH)" >&2
  return 127
}

# --- Query helpers ---
get_balance() {
  local addr="$1"
  curl -sf "${REST}/cosmos/bank/v1beta1/balances/${addr}" | \
    jq -r ".balances[] | select(.denom==\"${DENOM}\") | .amount // \"0\"" 2>/dev/null || echo "0"
}

get_block_height() {
  curl -sf "${RPC}/status" | jq -r '.result.sync_info.latest_block_height // "0"' 2>/dev/null || echo "0"
}

get_validators_json() {
  exec_mocad query staking validators --node "$TM_RPC" --output json 2>/dev/null || echo "{}"
}

get_validator_count() {
  get_validators_json | jq '.validators | length' 2>/dev/null || echo "0"
}

get_bonded_validator_count() {
  get_validators_json | jq '[.validators[] | select(.status=="BOND_STATUS_BONDED")] | length' 2>/dev/null || echo "0"
}

get_validator_operator_addrs() {
  get_validators_json | jq -r '.validators[].operator_address' 2>/dev/null
}

# --- Account helpers ---
# Resolve a key name to an address. Works with docker keyring (local) or host keyring (devnet).
get_key_address() {
  local key="$1"
  exec_mocad keys show "$key" -a --keyring-backend test 2>/dev/null || echo ""
}

require_test_key() {
  if [ -z "$TEST_KEY" ]; then
    echo "SKIP: no test key configured (set DEVNET_TEST_KEY=<keyname> for devnet)"
    exit 0
  fi
  local addr
  addr=$(get_key_address "$TEST_KEY")
  if [ -z "$addr" ]; then
    echo "SKIP: test key '$TEST_KEY' not found in keyring"
    exit 0
  fi
}

# --- Transaction helpers ---
cosmos_tx() {
  exec_mocad tx "$@" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --fees "$FEES" \
    -y 2>/dev/null
  sleep 3
}

wait_for_tx() {
  local seconds="${1:-5}"
  sleep "$seconds"
}

# --- Assertion helpers ---
assert_gt() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" -gt "$expected" ] 2>/dev/null; then
    echo "  OK: $msg ($actual > $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected > $expected)"
    return 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  OK: $msg ($actual == $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected $expected)"
    return 1
  fi
}

assert_ne() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" != "$expected" ]; then
    echo "  OK: $msg ($actual != $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected != $expected)"
    return 1
  fi
}

# --- moca-cmd helpers (optional, best-effort) ---
resolve_moca_cmd() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moca-cmd$'; then
    echo "docker:moca-cmd"
    return 0
  fi
  if command -v moca-cmd >/dev/null 2>&1; then
    echo "local:moca-cmd"
    return 0
  fi
  return 1
}

exec_moca_cmd() {
  local target
  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    local container="${target#docker:}"
    docker exec "$container" moca-cmd "$@" 2>/dev/null
    return $?
  fi
  moca-cmd "$@" 2>/dev/null
}

# --- Storage test helpers (aligned with devcontainer storage_utils) ---
generate_bucket_name() {
  local prefix="${1:-e2e-bucket}"
  echo "${prefix}-$(date +%s)-${RANDOM}"
}

generate_group_name() {
  local prefix="${1:-e2e-group}"
  echo "${prefix}-$(date +%s)-$$"
}

generate_object_name() {
  local prefix="${1:-obj}"
  local ext="${2:-.txt}"
  echo "${prefix}-$(date +%s)${ext}"
}

create_test_file() {
  local path="${1:-/tmp/e2e-test-$(date +%s).txt}"
  local content="${2:-e2e test content $(date)}"
  echo "$content" > "$path"
  echo "$path"
}

get_default_tags() {
  echo '[{"key":"key1","value":"value1"},{"key":"key2","value":"value2"}]'
}

get_updated_tags() {
  echo '[{"key":"key3","value":"value3"}]'
}

print_test_section() {
  echo ""
  echo "=== $* ==="
}

print_success() {
  echo "  OK: $*"
}

wait_for_block() {
  local seconds="${1:-3}"
  sleep "$seconds"
}

# First IN_SERVICE SP operator from chain JSON (not moca-cmd output).
first_in_service_sp_operator() {
  local json addr
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  addr=$(echo "$json" | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .operator_address' 2>/dev/null | head -1)
  if [ -n "$addr" ] && [ "$addr" != "null" ]; then
    echo "$addr"
    return 0
  fi
  echo "$json" | jq -r '.sps[0].operator_address // empty' 2>/dev/null
}

# SP endpoint URL from first IN_SERVICE SP (http/https).
first_in_service_sp_endpoint() {
  local json ep
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  ep=$(echo "$json" | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .endpoint' 2>/dev/null | head -1)
  if [ -n "$ep" ] && [ "$ep" != "null" ]; then
    echo "$ep"
    return 0
  fi
  echo "$json" | jq -r '.sps[0].endpoint // empty' 2>/dev/null
}

extract_tx_hash() {
  local output="$1"
  local h
  h=$(echo "$output" | grep -oE 'transaction hash:[[:space:]]+0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1)
  [ -n "$h" ] && echo "$h" && return 0
  h=$(echo "$output" | grep -oE 'txHash[=:][[:space:]]*0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1)
  [ -n "$h" ] && echo "$h" && return 0
  echo "$output" | grep -oE 'txn hash:[[:space:]]*0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1
}

list_sp_container_names() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$' | sort -V || true
}
