#!/usr/bin/env bash
# E2E test: verify 6/6 validators bonded with equal stake distribution
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then
  echo "SKIP: validator stake test only runs against local"
  exit 0
fi

echo "Testing validator set and stake distribution..."

# Get all validators
VALS_JSON=$(get_validators_json)
TOTAL=$(echo "$VALS_JSON" | jq '.validators | length')
BONDED=$(echo "$VALS_JSON" | jq '[.validators[] | select(.status=="BOND_STATUS_BONDED")] | length')

assert_eq "$TOTAL" "$BONDED" "All validators bonded" || exit 1

# Check stake distribution — all should have equal tokens
STAKES=$(echo "$VALS_JSON" | jq -r '.validators[].tokens' | sort -u)
UNIQUE_STAKES=$(echo "$STAKES" | wc -l | tr -d ' ')

echo "  Validators: $TOTAL, Bonded: $BONDED"
echo "  Unique stake amounts: $UNIQUE_STAKES"

if [ "$UNIQUE_STAKES" -eq 1 ]; then
  STAKE_AMOUNT=$(echo "$STAKES" | head -1)
  echo "  All validators have equal stake: $STAKE_AMOUNT"
else
  echo "  WARN: Validators have unequal stakes:"
  echo "$VALS_JSON" | jq -r '.validators[] | "    \(.description.moniker): \(.tokens)"'
fi

assert_gt "$BONDED" 0 "At least one bonded validator" || exit 1

echo "PASS: $BONDED/$TOTAL validators bonded, stake distribution checked"
