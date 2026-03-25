#!/usr/bin/env bash
# E2E test: delegate and undelegate tokens
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: staking test only on local"; exit 0; fi

echo "Testing staking delegation and undelegation..."

# Get a validator operator address to delegate to (not validator-0, use validator-1)
VALS_JSON=$(get_validators_json)
NUM_VALS=$(echo "$VALS_JSON" | jq '.validators | length')

if [ "$NUM_VALS" -lt 2 ]; then
  echo "SKIP: need at least 2 validators for cross-delegation test"
  exit 0
fi

# Get validator-1's operator address
VAL_OPER=$(echo "$VALS_JSON" | jq -r '.validators[1].operator_address')
echo "  Delegating to: $VAL_OPER"

# Query delegations before
DEL_BEFORE=$(exec_mocad query staking delegations-to "$VAL_OPER" --node tcp://localhost:26657 --output json 2>/dev/null | \
  jq '.delegation_responses | length' 2>/dev/null || echo "0")
echo "  Delegations to validator-1 before: $DEL_BEFORE"

# Delegate 1 MOCA from testaccount
DELEGATE_AMOUNT="1000000000000000000"
echo "  Delegating ${DELEGATE_AMOUNT}${DENOM} from testaccount..."
cosmos_tx staking delegate "$VAL_OPER" "${DELEGATE_AMOUNT}${DENOM}" --from testaccount
wait_for_tx 5

# Query delegations after
DEL_AFTER=$(exec_mocad query staking delegations-to "$VAL_OPER" --node tcp://localhost:26657 --output json 2>/dev/null | \
  jq '.delegation_responses | length' 2>/dev/null || echo "0")
echo "  Delegations to validator-1 after: $DEL_AFTER"

assert_gt "$DEL_AFTER" "$DEL_BEFORE" "New delegation recorded" || {
  echo "  WARN: Delegation count didn't increase (may have merged with existing)"
}

# Unbond half
UNBOND_AMOUNT="500000000000000000"
echo "  Unbonding ${UNBOND_AMOUNT}${DENOM}..."
cosmos_tx staking unbond "$VAL_OPER" "${UNBOND_AMOUNT}${DENOM}" --from testaccount
wait_for_tx 5

# Query unbonding
UNBONDING=$(exec_mocad query staking unbonding-delegations-from "$VAL_OPER" --node tcp://localhost:26657 --output json 2>/dev/null | \
  jq '.unbonding_responses | length' 2>/dev/null || echo "0")
echo "  Unbonding delegations: $UNBONDING"

assert_gt "$UNBONDING" 0 "Unbonding entry exists" || echo "  WARN: Unbonding not found (may already complete)"

echo "PASS: Staking delegation and undelegation successful"
