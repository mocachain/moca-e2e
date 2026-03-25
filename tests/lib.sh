#!/usr/bin/env bash
# Shared test helpers for E2E tests running against docker-compose.

# --- Config ---
CHAIN_ID="${CHAIN_ID:-moca_5151-1}"
DENOM="${DENOM:-amoca}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-5151}"
RPC="${RPC:-http://localhost:26657}"
REST="${REST:-http://localhost:1317}"
EVM_RPC="${EVM_RPC:-http://localhost:8545}"
FEES="${FEES:-200000000000000amoca}"
VALIDATOR_CONTAINER="${VALIDATOR_CONTAINER:-validator-0}"

# --- Docker exec into validator ---
exec_mocad() {
  docker exec "$VALIDATOR_CONTAINER" mocad "$@" --home /root/.mocad 2>/dev/null
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
  exec_mocad query staking validators --node tcp://localhost:26657 --output json 2>/dev/null
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

# --- Transaction helpers ---
cosmos_tx() {
  exec_mocad tx "$@" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node tcp://localhost:26657 \
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
