#!/usr/bin/env bash
# E2E test: delegate and undelegate tokens
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/assertions.sh
source "$SCRIPT_DIR/libs/assertions.sh"

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

# Amount $TEST_KEY has delegated to the validator ("0" when it has no delegation).
DELEGATOR=$(get_key_address "$TEST_KEY")
delegated_amount() {
  local amount
  amount=$(exec_mocad query staking delegation "$DELEGATOR" "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null |
    jq -r '.delegation_response.balance.amount // empty' 2>/dev/null || true)
  echo "${amount:-0}"
}
# Unbonding entries $TEST_KEY has open with the validator.
unbonding_entries() {
  local n
  n=$(exec_mocad query staking unbonding-delegation "$DELEGATOR" "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null |
    jq -r '.unbond.entries | length' 2>/dev/null || true)
  echo "${n:-0}"
}
last_unbonding_balance() {
  exec_mocad query staking unbonding-delegation "$DELEGATOR" "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null |
    jq -r '.unbond.entries[-1].balance // empty' 2>/dev/null || true
}
# assert_eq_within <timeout_s> <expected> <msg> <cmd...>: poll the command's stdout until it equals <expected>, then assert.
assert_eq_within() {
  local timeout="$1" expected="$2" msg="$3" actual deadline
  shift 3
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    actual="$("$@" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 2
  done
  assert_eq "$actual" "$expected" "$msg"
}

# An earlier test delegates from the same account, so a delegation can merge: assert the amount, not the count.
DELEGATED_BEFORE=$(delegated_amount)
UNBONDING_BEFORE=$(unbonding_entries)
echo "  Delegated before: $DELEGATED_BEFORE"

# Delegate 1 MOCA
DELEGATE_AMOUNT="1000000000000000000"
echo "  Delegating ${DELEGATE_AMOUNT}${DENOM} from $TEST_KEY..."
cosmos_tx staking delegate "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY"

# bc: delegation amounts are 18-decimal integers, past what shell arithmetic holds safely.
DELEGATED_EXPECTED=$(echo "$DELEGATED_BEFORE + $DELEGATE_AMOUNT" | bc) || {
  echo "FAIL: bc is required to compute the expected delegated amount"
  exit 1
}
assert_eq_within 30 "$DELEGATED_EXPECTED" "Delegated amount grew by the delegation" delegated_amount

# Unbond same amount
echo "  Unbonding ${DELEGATE_AMOUNT}${DENOM}..."
cosmos_tx staking unbond "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY"

assert_eq_within 30 "$DELEGATED_BEFORE" "Delegated amount back to the pre-delegation amount" delegated_amount
assert_eq_within 30 "$((UNBONDING_BEFORE + 1))" "Unbonding entry created" unbonding_entries
assert_eq "$(last_unbonding_balance)" "$DELEGATE_AMOUNT" "Unbonding entry holds the unbonded amount"

echo "PASS: Staking delegation and undelegation successful"
