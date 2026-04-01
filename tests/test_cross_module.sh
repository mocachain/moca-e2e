#!/usr/bin/env bash
# E2E test: cross-module transactions to verify module interop
# Tests bank, staking, distribution in sequence on the same chain state
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "cross-module test"

echo "Testing cross-module transactions..."

VALS_JSON=$(get_validators_json)
NUM_VALS=$(echo "$VALS_JSON" | jq '.validators | length')
if [ "$NUM_VALS" -lt 2 ]; then
  echo "SKIP: need at least 2 validators"
  exit 0
fi

VAL0_OPER=$(echo "$VALS_JSON" | jq -r '.validators[0].operator_address')
VAL1_OPER=$(echo "$VALS_JSON" | jq -r '.validators[1].operator_address')
HEIGHT_BEFORE=$(get_block_height)

# --- 1. Bank: multi-hop transfer ---
echo "  [bank] Multi-hop transfer: validator-0 → testaccount"
RECEIVER=$(exec_mocad keys show testaccount -a --keyring-backend test 2>/dev/null || echo "")
if [ -z "$RECEIVER" ]; then
  echo "  SKIP: testaccount not in keyring"
  exit 0
fi

cosmos_tx bank send validator-0 "$RECEIVER" "500000000000000000${DENOM}" --from validator-0
wait_for_tx 3

# --- 2. Staking: delegate from testaccount to validator-1 ---
echo "  [staking] Delegate testaccount → validator-1"
cosmos_tx staking delegate "$VAL1_OPER" "100000000000000000${DENOM}" --from testaccount
wait_for_tx 3

# --- 3. Distribution: withdraw rewards from validator-0 ---
echo "  [distribution] Withdraw rewards for validator-0"
cosmos_tx distribution withdraw-rewards "$VAL0_OPER" --from validator-0
wait_for_tx 3

# --- 4. Staking: unbond from validator-1 ---
echo "  [staking] Unbond testaccount from validator-1"
cosmos_tx staking unbond "$VAL1_OPER" "50000000000000000${DENOM}" --from testaccount
wait_for_tx 3

# --- 5. Bank: send back ---
echo "  [bank] Transfer testaccount → validator-0"
VALIDATOR0_ADDR=$(exec_mocad keys show validator-0 -a --keyring-backend test)
cosmos_tx bank send testaccount "$VALIDATOR0_ADDR" "100000000000000000${DENOM}" --from testaccount
wait_for_tx 3

# --- Verify chain is still healthy ---
HEIGHT_AFTER=$(get_block_height)
BONDED=$(get_bonded_validator_count)

echo ""
echo "  Height before: $HEIGHT_BEFORE, after: $HEIGHT_AFTER"
echo "  Bonded validators: $BONDED"

assert_gt "$HEIGHT_AFTER" "$HEIGHT_BEFORE" "Chain advanced during cross-module txs" || exit 1
assert_gt "$BONDED" 0 "Validators still bonded after cross-module txs" || exit 1

echo "PASS: Cross-module transactions (bank → staking → distribution → staking → bank) successful"
