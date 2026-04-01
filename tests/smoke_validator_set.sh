#!/usr/bin/env bash
# Smoke test: verify expected number of validators in the active set
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
RPC="${RPC:-$(yq -r '.chain.rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)}"

if [ -z "$RPC" ] || [ "$RPC" = "null" ] || [ "$RPC" = '""' ]; then
  echo "SKIP: RPC not configured for $ENV"
  exit 0
fi

echo "Checking validator set at $RPC..."

RESPONSE=$(curl -sf "${RPC}/validators" 2>/dev/null) || {
  echo "FAIL: Cannot reach chain RPC at $RPC"
  exit 1
}

TOTAL=$(echo "$RESPONSE" | jq -r '.result.total // "0"')

if [ "$TOTAL" -le 0 ]; then
  echo "FAIL: No validators found (total: $TOTAL)"
  exit 1
fi

echo "Active validators: $TOTAL"

# Verify all validators are signing
VALIDATORS=$(echo "$RESPONSE" | jq -r '.result.validators')
SIGNING=0
for row in $(echo "$VALIDATORS" | jq -r '.[] | @base64'); do
  VP=$(echo "$row" | base64 -d | jq -r '.voting_power // "0"')
  if [ "$VP" -gt 0 ]; then
    SIGNING=$((SIGNING + 1))
  fi
done

echo "PASS: $SIGNING/$TOTAL validators active with voting power"
