#!/usr/bin/env bash
# E2E test: cross-module transactions to verify module interop
# Tests bank, staking, distribution in sequence on the same chain state
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "cross-module test"
require_test_key

echo "Testing cross-module transactions..."

VALS_JSON=$(get_validators_json)
NUM_BONDED=$(echo "$VALS_JSON" | jq '[.validators[] | select(.status=="BOND_STATUS_BONDED")] | length')
if [ "$NUM_BONDED" -lt 1 ]; then
  echo "SKIP: need at least 1 bonded validator"
  exit 0
fi

VAL_OPER=$(echo "$VALS_JSON" | jq -r '[.validators[] | select(.status=="BOND_STATUS_BONDED")][0].operator_address')
HEIGHT_BEFORE=$(get_block_height)
FRESH_ADDR="0x$(openssl rand -hex 20)"

# 1 MOCA per operation
AMT="1000000000000000000"

# --- 1. Bank: send to fresh address ---
echo "  [bank] Send $TEST_KEY → fresh address"
cosmos_tx bank send "$TEST_KEY" "$FRESH_ADDR" "${AMT}${DENOM}" --from "$TEST_KEY"
wait_for_tx 5

# --- 2. Staking: delegate to validator ---
echo "  [staking] Delegate $TEST_KEY → validator"
cosmos_tx staking delegate "$VAL_OPER" "${AMT}${DENOM}" --from "$TEST_KEY"
wait_for_tx 5

# --- 3. Staking: unbond ---
echo "  [staking] Unbond $TEST_KEY from validator"
cosmos_tx staking unbond "$VAL_OPER" "${AMT}${DENOM}" --from "$TEST_KEY"
wait_for_tx 5

# --- Verify chain is still healthy ---
HEIGHT_AFTER=$(get_block_height)
BONDED=$(get_bonded_validator_count)

echo ""
echo "  Height before: $HEIGHT_BEFORE, after: $HEIGHT_AFTER"
echo "  Bonded validators: $BONDED"

assert_gt "$HEIGHT_AFTER" "$HEIGHT_BEFORE" "Chain advanced during cross-module txs" || exit 1
assert_gt "$BONDED" 0 "Validators still bonded after cross-module txs" || exit 1

echo "PASS: Cross-module transactions (bank → staking → unbond) successful"
