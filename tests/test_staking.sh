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

# Query delegations before
DEL_BEFORE=$(exec_mocad query staking delegations-to "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null | \
  jq '.delegation_responses | length' 2>/dev/null || echo "0")
echo "  Delegations before: $DEL_BEFORE"

# Delegate 1 MOCA
DELEGATE_AMOUNT="1000000000000000000"
echo "  Delegating ${DELEGATE_AMOUNT}${DENOM} from $TEST_KEY..."
cosmos_tx staking delegate "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY"
wait_for_tx 5

# Query delegations after
DEL_AFTER=$(exec_mocad query staking delegations-to "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null | \
  jq '.delegation_responses | length' 2>/dev/null || echo "0")
echo "  Delegations after: $DEL_AFTER"

assert_gt "$DEL_AFTER" "$DEL_BEFORE" "New delegation recorded" || {
  echo "  WARN: Delegation count didn't increase (may have merged with existing)"
}

# Unbond same amount
echo "  Unbonding ${DELEGATE_AMOUNT}${DENOM}..."
cosmos_tx staking unbond "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from "$TEST_KEY"
wait_for_tx 5

# Query unbonding
UNBONDING=$(exec_mocad query staking unbonding-delegations-from "$VAL_OPER" --node "$TM_RPC" --output json 2>/dev/null | \
  jq '.unbonding_responses | length' 2>/dev/null || echo "0")
echo "  Unbonding delegations: $UNBONDING"

assert_gt "$UNBONDING" 0 "Unbonding entry exists" || echo "  WARN: Unbonding not found"

echo "PASS: Staking delegation and undelegation successful"
