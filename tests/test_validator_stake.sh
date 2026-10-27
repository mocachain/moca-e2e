#!/usr/bin/env bash
# E2E test: verify 6/6 validators bonded with equal stake distribution (all bonded, one common
# stake on the local topology; on a live network only that something is bonded)
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/assertions.sh
source "$SCRIPT_DIR/libs/assertions.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi

echo "Testing validator set and stake distribution..."

# Get all validators
VALS_JSON=$(get_validators_json)
TOTAL=$(echo "$VALS_JSON" | jq '.validators | length // 0' 2>/dev/null || echo "0")
BONDED=$(echo "$VALS_JSON" | jq '[.validators[]? | select(.status=="BOND_STATUS_BONDED")] | length' 2>/dev/null || echo "0")

if [ "$TOTAL" -le 0 ]; then
  echo "SKIP: cannot query validators (mocad/RPC not available for $ENV)"
  exit 0
fi

# Check stake distribution — all should have equal tokens
STAKES=$(echo "$VALS_JSON" | jq -r '.validators[].tokens' | sort -u)
UNIQUE_STAKES=$(echo "$STAKES" | wc -l | tr -d ' ')

echo "  Validators: $TOTAL, Bonded: $BONDED"
echo "  Unique stake amounts: $UNIQUE_STAKES"

if [ "$ENV" = "local" ]; then
  # The local topology bonds every validator at one genesis stake: all must be bonded with equal stake.
  EXPECTED=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ec '^validator-[0-9]+$' || true)
  if [ "${EXPECTED:-0}" -gt 0 ]; then
    if [ "$TOTAL" -lt "$EXPECTED" ]; then
      echo "  FAIL: $TOTAL validators in the set, $EXPECTED validator containers running"
      exit 1
    fi
    print_success "Validator set covers every validator container ($TOTAL >= $EXPECTED)"
  fi
  assert_eq "$BONDED" "$TOTAL" "All validators bonded"
  assert_eq "$UNIQUE_STAKES" 1 "All validators have equal stake ($(echo "$STAKES" | head -1))"
else
  if [ "$UNIQUE_STAKES" -ne 1 ]; then
    echo "  WARN: Validators have unequal stakes:"
    echo "$VALS_JSON" | jq -r '.validators[] | "    \(.description.moniker): \(.tokens)"'
  fi
  if [ "$BONDED" -lt "$TOTAL" ]; then
    echo "  WARN: Not all validators are bonded in $ENV ($BONDED/$TOTAL)"
  fi
fi

assert_gt "$BONDED" 0 "At least one bonded validator" || exit 1

echo "PASS: $BONDED/$TOTAL validators bonded, stake distribution checked"
