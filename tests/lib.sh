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
  # On remote envs, check the account has enough funds (~3 MOCA minimum for full suite)
  if [ "${ENV:-local}" != "local" ]; then
    local bal
    bal=$(get_balance "$addr")
    # 3 MOCA = 3000000000000000000 amoca
    if [ -n "$bal" ] && [ "$bal" != "0" ] && [ ${#bal} -lt 19 ]; then
      echo "WARN: $TEST_KEY balance is low ($bal $DENOM). Full write suite needs ~3 MOCA."
      echo "      Fund $addr with at least 3000000000000000000 amoca before running."
    fi
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

# _evm_rpc: one-shot JSON-RPC call. Prints .result as JSON (or empty on error).
_evm_rpc() {
  local method="$1" params="${2:-[]}" rpc="${EVM_RPC:-http://localhost:8545}"
  curl -sf -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "$rpc" 2>/dev/null | jq -c '.result // empty' 2>/dev/null
}

# wait_for_evm_tx: wait until the sender's mempool has fully drained — i.e. the
# next signed call from this account reads a nonce that matches what the chain
# expects, with no pending tx in between.
#
# Critical: moca-cmd's `bucket create --tags=…` (and similar) can submit TWO
# internal txs (CreateBucket + SetTag) and only print the first hash. Waiting
# for the first hash's `latest` nonce to advance is not enough — the second tx
# is still in mempool, and the next `object put` queries nonce N while mempool
# already has a tx at N, so chain rejects with "invalid nonce; got N, expected N+1".
#
# The correct signal is pending_count == latest_count (mempool empty for sender):
# every tx this account has submitted has been committed.
#
# Retries at 1s intervals (local block time). Gives up after `timeout` seconds.
#
# Usage: wait_for_evm_tx "$tx_hash" [timeout_seconds]
# Returns 0 once mempool is drained for the sender, 1 on timeout.
wait_for_evm_tx() {
  local hash="${1:-}" timeout="${2:-5}"
  [ -z "$hash" ] || [ "${hash#0x}" = "$hash" ] && return 1

  local tx from deadline now pending_c latest_c
  deadline=$(( $(date +%s) + timeout ))

  while :; do
    tx=$(_evm_rpc eth_getTransactionByHash "[\"$hash\"]")
    if [ -n "$tx" ] && [ "$tx" != "null" ]; then
      from=$(echo "$tx" | jq -r '.from')
      [ -n "$from" ] && [ "$from" != "null" ] && break
    fi
    now=$(date +%s); [ "$now" -ge "$deadline" ] && return 1
    sleep 1
  done

  while :; do
    pending_c=$(_evm_rpc eth_getTransactionCount "[\"$from\",\"pending\"]")
    latest_c=$(_evm_rpc eth_getTransactionCount "[\"$from\",\"latest\"]")
    pending_c=${pending_c//\"/}; latest_c=${latest_c//\"/}
    if [ -n "$pending_c" ] && [ "$pending_c" = "$latest_c" ] && [ "$pending_c" != "null" ]; then
      return 0
    fi
    now=$(date +%s); [ "$now" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# Extract the EVM tx hash from moca-cmd output ("transaction hash:  0x...").
# Empty result means no hash was printed (query commands, errors, etc).
extract_evm_tx_hash() {
  echo "${1:-}" | grep -oE 'transaction hash:[[:space:]]+0x[0-9a-fA-F]{64}' \
    | grep -oE '0x[0-9a-fA-F]{64}' | head -1
}

# wait_for_object_sealed: poll `moca-cmd object head <path>` until status reaches
# OBJECT_STATUS_SEALED or timeout.
#
# Not needed for the default `object put` flow — moca-cmd already waits for
# SEALED internally (cmd/cmd_object.go:808, 1h timeout). This helper is for
# callers that used --bypassSeal or need to verify an existing object's state.
#
# Timeout precedence: explicit 2nd arg > SEAL_TIMEOUT_SECONDS env > default 120.
#
# Usage: wait_for_object_sealed "$bucket/$object" [timeout_seconds]
# Returns 0 on SEALED, 1 on timeout. Prints status on failure.
wait_for_object_sealed() {
  local path="${1:?object path required}"
  local timeout="${2:-${SEAL_TIMEOUT_SECONDS:-120}}"
  local status deadline now
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    status=$(exec_moca_cmd object head "$path" 2>/dev/null | grep -oE 'object_status: OBJECT_STATUS_[A-Z_]+' | head -1)
    case "$status" in
      *OBJECT_STATUS_SEALED*) return 0 ;;
    esac
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_object_sealed: timeout after ${timeout}s; last status: ${status:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
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

# --- moca-cmd helpers ---
# MOCA_CMD_HOME: keystore home for moca-cmd (separate from mocad keyring)
# MOCA_CMD_PASSWORD_FILE: password file for the keystore
MOCA_CMD_HOME="${MOCA_CMD_HOME:-}"
MOCA_CMD_PASSWORD_FILE="${MOCA_CMD_PASSWORD_FILE:-}"
MOCA_CMD_BIN="${MOCA_CMD_BIN:-}"

resolve_moca_cmd() {
  # The docker moca-cmd sidecar (see PR that adds it) is keyed to local validator-0
  # and the localnet testaccount. Never use it against remote networks — its keystore
  # + config only match ENV=local.
  if [ "${ENV:-local}" = "local" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moca-cmd$'; then
    echo "docker:moca-cmd"
    return 0
  fi
  if [ -n "$MOCA_CMD_BIN" ] && [ -x "$MOCA_CMD_BIN" ]; then
    echo "local:$MOCA_CMD_BIN"
    return 0
  fi
  if command -v moca-cmd >/dev/null 2>&1; then
    echo "local:moca-cmd"
    return 0
  fi
  return 1
}

# exec_moca_cmd: run moca-cmd with network flags (read-only queries, no signing).
# -p is safe to pass unconditionally: moca-cmd only reads the password file when
# IsQueryCmd=false (see client_moca.go NewClient); queries skip parseKeystore.
exec_moca_cmd() {
  local target bin
  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    local container="${target#docker:}"
    docker exec "$container" moca-cmd -p /root/.moca-cmd/password.txt "$@" 2>/dev/null
    return $?
  fi
  bin="${target#local:}"
  local net_args=()
  if [ "${ENV:-local}" != "local" ]; then
    [ -n "${RPC:-}" ] && net_args+=(--rpcAddr "$RPC")
    [ -n "${CHAIN_ID:-}" ] && net_args+=(--chainId "$CHAIN_ID")
    [ -n "${EVM_RPC:-}" ] && net_args+=(--evmRpcAddr "$EVM_RPC")
  fi
  [ -n "$MOCA_CMD_HOME" ] && net_args+=(--home "$MOCA_CMD_HOME")
  [ -n "$MOCA_CMD_PASSWORD_FILE" ] && net_args+=(-p "$MOCA_CMD_PASSWORD_FILE")
  "$bin" "${net_args[@]}" "$@" 2>/dev/null
}

# exec_moca_cmd_signed: run moca-cmd with network flags + keystore (for write operations)
# IMPORTANT: do NOT pass --host — moca-cmd resolves SP endpoints from chain automatically
exec_moca_cmd_signed() {
  local target bin
  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    local container="${target#docker:}"
    docker exec "$container" moca-cmd -p /root/.moca-cmd/password.txt "$@" 2>/dev/null
    return $?
  fi
  bin="${target#local:}"
  local args=()
  if [ "${ENV:-local}" != "local" ]; then
    [ -n "${RPC:-}" ] && args+=(--rpcAddr "$RPC")
    [ -n "${CHAIN_ID:-}" ] && args+=(--chainId "$CHAIN_ID")
    [ -n "${EVM_RPC:-}" ] && args+=(--evmRpcAddr "$EVM_RPC")
  fi
  [ -n "$MOCA_CMD_HOME" ] && args+=(--home "$MOCA_CMD_HOME")
  [ -n "$MOCA_CMD_PASSWORD_FILE" ] && args+=(-p "$MOCA_CMD_PASSWORD_FILE")
  "$bin" "${args[@]}" "$@" 2>/dev/null
}

# moca_cmd_tx: signed call that additionally waits for the sender's mempool
# to drain before returning. Prevents nonce-race on back-to-back signed calls
# (moca-cmd queries Cosmos auth sequence at "latest", which lags pending txs;
# some ops — like `bucket create --tags=…` — also emit an extra implicit tx
# whose hash isn't printed, so a plain-hash wait misses it).
#
# Echoes moca-cmd output to stdout, returns moca-cmd's rc. Sets rc=1 if
# mempool didn't drain in 5s (chain stuck / tx got dropped) or, when
# CHECK_TX_STATUS=1, the tx receipt shows status=0x0.
moca_cmd_tx() {
  local out rc hash status
  out=$(exec_moca_cmd_signed "$@")
  rc=$?
  hash=$(extract_evm_tx_hash "$out")
  if [ -n "$hash" ]; then
    if ! wait_for_evm_tx "$hash" 5 >/dev/null 2>&1; then
      echo "  ERROR: wait_for_evm_tx timed out waiting for mempool to drain after $hash" >&2
      rc=1
    fi
    if [ "${CHECK_TX_STATUS:-0}" = "1" ]; then
      status=$(curl -sf -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_getTransactionReceipt","params":["'"$hash"'"]}' \
        "${EVM_RPC:-http://localhost:8545}" 2>/dev/null | jq -r '.result.status // empty' 2>/dev/null)
      if [ "$status" = "0x0" ]; then
        echo "  ERROR: tx $hash REVERTED on-chain (status=0x0)" >&2
        rc=1
      fi
    fi
  fi
  printf '%s\n' "$out"
  return $rc
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
# If SP_ENDPOINT_FILTER is set (regex), prefer SPs whose endpoint matches. Useful
# on testnet where both legacy .org and new .dev SPs coexist and tests should
# target a specific cluster.
first_in_service_sp_operator() {
  local json addr
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ -n "${SP_ENDPOINT_FILTER:-}" ]; then
    addr=$(echo "$json" | jq -r --arg f "$SP_ENDPOINT_FILTER" \
      '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and (.endpoint | test($f))) | .operator_address' 2>/dev/null | head -1)
    if [ -n "$addr" ] && [ "$addr" != "null" ]; then
      echo "$addr"
      return 0
    fi
  fi
  addr=$(echo "$json" | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .operator_address' 2>/dev/null | head -1)
  if [ -n "$addr" ] && [ "$addr" != "null" ]; then
    echo "$addr"
    return 0
  fi
  echo "$json" | jq -r '.sps[0].operator_address // empty' 2>/dev/null
}

# SP endpoint URL from first IN_SERVICE SP (http/https).
# If SP_ENDPOINT_FILTER is set (regex), prefer SPs whose endpoint matches.
first_in_service_sp_endpoint() {
  local json ep
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ -n "${SP_ENDPOINT_FILTER:-}" ]; then
    ep=$(echo "$json" | jq -r --arg f "$SP_ENDPOINT_FILTER" \
      '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and (.endpoint | test($f))) | .endpoint' 2>/dev/null | head -1)
    if [ -n "$ep" ] && [ "$ep" != "null" ]; then
      echo "$ep"
      return 0
    fi
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
