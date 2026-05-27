#!/usr/bin/env bash
# E2E test: delegate and undelegate tokens
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "staking test"
require_test_key

echo "Testing staking delegation and undelegation..."

# Get a bonded validator operator address to delegate to
VALS_JSON=$(get_validators_json)
NUM_BONDED=$(echo "$VALS_JSON" | jq '[.validators[] | select(.status=="BOND_STATUS_BONDED")] | length')

if [ "$NUM_BONDED" -lt 1 ]; then
  echo "SKIP: need at least 1 bonded validator"
  exit 0
fi

# Pick first bonded validator
VAL_OPER=$(echo "$VALS_JSON" | jq -r '[.validators[] | select(.status=="BOND_STATUS_BONDED")][0].operator_address')
VAL_MONIKER=$(echo "$VALS_JSON" | jq -r '[.validators[] | select(.status=="BOND_STATUS_BONDED")][0].description.moniker')
echo "  Delegating to: $VAL_MONIKER ($VAL_OPER)"
echo "  Using key: $TEST_KEY"
DELEGATOR_ADDR=$(get_key_address "$TEST_KEY")

get_delegation_amount() {
  exec_mocad query staking delegation "$DELEGATOR_ADDR" "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null | \
    jq -r '.delegation_response.balance.amount // "0"' 2>/dev/null || echo "0"
}

decimal_gt() {
  local actual="${1:-0}" expected="${2:-0}"
  actual="${actual#"${actual%%[!0]*}"}"
  expected="${expected#"${expected%%[!0]*}"}"
  actual="${actual:-0}"
  expected="${expected:-0}"
  [ ${#actual} -gt ${#expected} ] || { [ ${#actual} -eq ${#expected} ] && [ "$actual" \> "$expected" ]; }
}

# Query this delegator's stake before
DEL_BEFORE=$(get_delegation_amount)
echo "  Delegation amount before: $DEL_BEFORE"

# Delegate 1 MOCA
DELEGATE_AMOUNT="1000000000000000000"
echo "  Delegating ${DELEGATE_AMOUNT}${DENOM} from $TEST_KEY..."
delegate_out="$(cosmos_tx staking delegate "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY")"
printf '%s\n' "$delegate_out"
delegate_code="$(get_tx_code "$delegate_out")"
[ "${delegate_code:-1}" = "0" ] || { echo "FAIL: delegate tx failed"; exit 1; }
delegate_hash="$(printf '%s\n' "$delegate_out" | sed -n 's/^txhash:[[:space:]]*//p' | tail -1)"
wait_for_tx "$delegate_hash" 20 || { echo "FAIL: delegate tx not found"; exit 1; }

# Query this delegator's stake after
DEL_AFTER=$(get_delegation_amount)
echo "  Delegation amount after: $DEL_AFTER"

if decimal_gt "$DEL_AFTER" "$DEL_BEFORE"; then
  echo "  OK: Delegation amount increased ($DEL_AFTER > $DEL_BEFORE)"
else
  echo "  FAIL: Delegation amount increased (got $DEL_AFTER, expected > $DEL_BEFORE)"
  exit 1
fi

# Unbond same amount
echo "  Unbonding ${DELEGATE_AMOUNT}${DENOM}..."
unbond_out="$(cosmos_tx staking unbond "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY")"
printf '%s\n' "$unbond_out"
unbond_code="$(get_tx_code "$unbond_out")"
[ "${unbond_code:-1}" = "0" ] || { echo "FAIL: unbond tx failed"; exit 1; }
unbond_hash="$(printf '%s\n' "$unbond_out" | sed -n 's/^txhash:[[:space:]]*//p' | tail -1)"
wait_for_tx "$unbond_hash" 20 || { echo "FAIL: unbond tx not found"; exit 1; }

# Query unbonding
UNBONDING=$(exec_mocad query staking unbonding-delegation "$DELEGATOR_ADDR" "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null | \
  jq '.unbond.entries | length' 2>/dev/null || echo "0")
echo "  Unbonding delegations: $UNBONDING"

assert_gt "$UNBONDING" 0 "Unbonding entry exists" || exit 1

echo "PASS: Staking delegation and undelegation successful"
