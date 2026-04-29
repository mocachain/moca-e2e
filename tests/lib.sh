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

sha256_file() {
  local path="${1:?path required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  shasum -a 256 "$path" | awk '{print $1}'
}

sha256_file_docker_aware() {
  local path="${1:?path required}"
  local target
  if [ -r "$path" ]; then
    sha256_file "$path"
    return 0
  fi

  target="$(resolve_moca_cmd 2>/dev/null || true)"
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" sh -lc '
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk "{print \$1}"
      else
        shasum -a 256 "$1" | awk "{print \$1}"
      fi
    ' sh "$path" 2>/dev/null
    return $?
  fi

  return 1
}

remove_file_docker_aware() {
  local path="${1:?path required}"
  local target
  rm -f "$path" >/dev/null 2>&1 || true

  target="$(resolve_moca_cmd 2>/dev/null || true)"
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" rm -f "$path" >/dev/null 2>&1 || true
    rm -f "$path" >/dev/null 2>&1 || true
  fi
}

timed_object_get() {
  local timeout_seconds="${1:?timeout seconds required}"
  shift
  local target

  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" sh -lc '
      timeout="$1"
      shift
      exec timeout "$timeout" moca-cmd -p /root/.moca-cmd/password.txt "$@"
    ' sh "$timeout_seconds" "$@" 2>/dev/null
    return $?
  fi

  exec_moca_cmd_signed "$@"
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

sp_container_name_for_index() {
  local index="${1:?sp index required}"
  echo "sp-${index}"
}

exec_sp_cmd() {
  local container="${1:?sp container required}"
  shift
  docker exec "$container" moca-sp "$@"
}

get_sp_status_by_operator() {
  local operator="${1:?operator required}"
  exec_mocad query sp storage-provider-by-operator-address "$operator" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.storage_provider.status // .storageProvider.status // empty' 2>/dev/null || true
}

wait_for_sp_status() {
  local operator="${1:?operator required}"
  local expected_status="${2:?expected status required}"
  local timeout="${3:-120}"
  local deadline now status

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    status="$(get_sp_status_by_operator "$operator")"
    if [ "$status" = "$expected_status" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_sp_status: timeout after ${timeout}s; last status: ${status:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

sp_appears_as_secondary_somewhere() {
  local sp_id="${1:?sp id required}"
  local family_id

  for family_id in $(exec_mocad query virtualgroup global-virtual-group-families 100 \
    --node "$TM_RPC" --output json 2>/dev/null | jq -r '.gvg_families[]?.id' 2>/dev/null); do
    if exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
      --node "$TM_RPC" --output json 2>/dev/null \
      | jq -e --argjson sid "$sp_id" '[.global_virtual_groups[]?.secondary_sp_ids[]?] | index($sid) != null' >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

current_family_count() {
  exec_mocad query virtualgroup global-virtual-group-families 100 \
    --node "$TM_RPC" --output json 2>/dev/null | jq -r '.gvg_families | length // 0' 2>/dev/null || echo "0"
}

select_target_sp_index() {
  local requested="${E2E_SP_EXIT_INDEX:-}"
  local candidate_id candidate_idx family_count seen_first

  if [ -n "$requested" ] && [ "$requested" -ge 0 ] 2>/dev/null && [ "$requested" -lt "${NUM_SPS:-0}" ] 2>/dev/null; then
    printf '%s\n' "$requested"
    return 0
  fi

  family_count="$(current_family_count)"
  if [ "$family_count" = "0" ]; then
    seen_first=0
    for candidate_id in $(printf '%s\n' "${SP_JSON:-}" \
      | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .id' 2>/dev/null | sort -nr); do
      [ -n "$candidate_id" ] || continue
      candidate_idx=$((candidate_id - 1))
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^sp-${candidate_idx}$"; then
        continue
      fi
      if [ "$seen_first" = "0" ]; then
        seen_first=1
        continue
      fi
      printf '%s\n' "$candidate_idx"
      return 0
    done
  fi

  for candidate_id in $(printf '%s\n' "${SP_JSON:-}" \
    | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .id' 2>/dev/null | sort -nr); do
    [ -n "$candidate_id" ] || continue
    candidate_idx=$((candidate_id - 1))
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^sp-${candidate_idx}$" \
      && sp_appears_as_secondary_somewhere "$candidate_id"; then
      printf '%s\n' "$candidate_idx"
      return 0
    fi
  done

  return 1
}

gvg_primary_sp_id_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].primary_sp_id // empty' 2>/dev/null || true
}

wait_for_gvg_primary_sp_change() {
  local family_id="${1:?family id required}"
  local old_sp_id="${2:?old primary sp id required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_primary_sp_id_by_family "$family_id")"
    if [ -n "$current" ] && [ "$current" != "$old_sp_id" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_primary_sp_change: timeout after ${timeout}s; last primary SP ID: ${current:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

secondary_sp_ids_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -c '[.global_virtual_groups[]?.secondary_sp_ids[]?] | unique' 2>/dev/null || echo "[]"
}

gvg_stats_json_by_sp() {
  local sp_id="${1:?sp id required}"
  exec_mocad query virtualgroup gvg-statistics-within-sp "$sp_id" \
    --node "$TM_RPC" --output json 2>/dev/null || echo '{}'
}

gvg_statistics_query_supported() {
  exec_mocad query virtualgroup --help 2>/dev/null | grep -q "gvg-statistics-within-sp"
}

gvg_family_json_by_id() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-family "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null || echo '{}'
}

gvg_family_primary_sp_id() {
  local family_id="${1:?family id required}"
  gvg_family_json_by_id "$family_id" \
    | jq -r '.global_virtual_group_family.primary_sp_id // .globalVirtualGroupFamily.primarySpId // empty' 2>/dev/null || true
}

gvg_family_gvg_count() {
  local family_id="${1:?family id required}"
  gvg_family_json_by_id "$family_id" \
    | jq -r '(.global_virtual_group_family.global_virtual_group_ids // .globalVirtualGroupFamily.globalVirtualGroupIds // []) | length' 2>/dev/null || echo "0"
}

gvg_stored_size_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].stored_size // .global_virtual_groups[0].store_size // empty' 2>/dev/null || true
}

wait_for_gvg_stored_size() {
  local family_id="${1:?family id required}"
  local expected="${2:?expected value required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_stored_size_by_family "$family_id")"
    if [ -n "$current" ] && [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_stored_size: timeout after ${timeout}s; stored_size=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_gvg_family_gvg_count() {
  local family_id="${1:?family id required}"
  local expected="${2:?expected value required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_family_gvg_count "$family_id")"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_family_gvg_count: timeout after ${timeout}s; gvg_count=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

gvg_stat_value() {
  local sp_id="${1:?sp id required}"
  local field="${2:?field required}"
  local json

  json="$(gvg_stats_json_by_sp "$sp_id")"
  case "$field" in
    primary_count)
      printf '%s\n' "$json" | jq -r '.gvg_statistics.primary_count // .gvgStatistics.primaryCount // 0' 2>/dev/null || echo "0"
      ;;
    secondary_count)
      printf '%s\n' "$json" | jq -r '.gvg_statistics.secondary_count // .gvgStatistics.secondaryCount // 0' 2>/dev/null || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

wait_for_gvg_stat_value() {
  local sp_id="${1:?sp id required}"
  local field="${2:?field required}"
  local expected="${3:?expected value required}"
  local timeout="${4:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_stat_value "$sp_id" "$field")"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_stat_value: timeout after ${timeout}s; ${field}=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_sp_removed_from_list() {
  local operator="${1:?operator required}"
  local timeout="${2:-180}"
  local deadline now sp_json

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    sp_json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
    if ! printf '%s\n' "$sp_json" | jq -e --arg op "$operator" '.sps[] | select(.operator_address == $op)' >/dev/null 2>&1; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_sp_removed_from_list: timeout after ${timeout}s; operator still present: ${operator}" >&2
      return 1
    fi
    sleep 3
  done
}

create_bucket_with_target_as_secondary() {
  local target_sp_id="${1:?target sp id required}"
  local sp_json="${2:-${SP_JSON:-}}"
  local candidate_operators candidate bucket_name bucket_url bucket_out bucket_head family_id secondary_ids attempt

  candidate_operators="$(printf '%s\n' "$sp_json" | jq -r --arg sid "$target_sp_id" \
    '.sps[] | select((.id|tostring) != $sid and (.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0")) | .operator_address' 2>/dev/null || true)"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    for attempt in 1 2 3; do
      bucket_name="e2e-sp-exit-secondary-${target_sp_id}-$(date +%s)-${RANDOM}"
      bucket_url="moca://${bucket_name}"
      bucket_out="$(moca_cmd_tx bucket create --primarySP "$candidate" "$bucket_url" || true)"
      if ! echo "$bucket_out" | grep -q "$bucket_name"; then
        echo "$bucket_out"
        echo "FAIL: auxiliary bucket create did not succeed on candidate primary SP ${candidate}"
        return 1
      fi

      bucket_head="$(exec_moca_cmd bucket head "$bucket_url" 2>&1 || true)"
      family_id="$(printf '%s\n' "$bucket_head" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
      if [ -z "$family_id" ]; then
        echo "$bucket_head"
        echo "FAIL: could not resolve auxiliary bucket family ID"
        return 1
      fi

      secondary_ids="$(secondary_sp_ids_by_family "$family_id")"
      echo "  auxiliary bucket attempt=${attempt} candidate_primary=${candidate} family_id=${family_id} secondary_sp_ids=${secondary_ids}"
      if printf '%s\n' "$secondary_ids" | jq -e --argjson sid "$target_sp_id" 'index($sid) != null' >/dev/null 2>&1; then
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_URL="$bucket_url"
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_FAMILY_ID="$family_id"
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_SECONDARY_IDS="$secondary_ids"
        return 0
      fi

      exec_moca_cmd bucket rm "$bucket_url" >/dev/null 2>&1 || true
    done
  done <<EOF
$candidate_operators
EOF

  echo "FAIL: could not create an auxiliary bucket whose GVG uses target SP ${target_sp_id} as secondary"
  return 1
}
