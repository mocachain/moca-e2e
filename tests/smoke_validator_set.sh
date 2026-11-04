#!/usr/bin/env bash
# Smoke test: verify the active validator set — every validator has voting power and, on the
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
RPC="${RPC:-$(yq -r '.chain.rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)}"

if [ -z "$RPC" ] || [ "$RPC" = "null" ] || [ "$RPC" = '""' ]; then
  echo "SKIP: RPC not configured for $ENV"
  exit 0
fi

echo "Checking validator set at $RPC..."

RESPONSE=$(curl -sf "${RPC}/validators?per_page=100" 2>/dev/null) || {
  echo "FAIL: Cannot reach chain RPC at $RPC"
  exit 1
}

TOTAL=$(echo "$RESPONSE" | jq -r '.result.total // "0"')

if [ "$TOTAL" -le 0 ]; then
  echo "FAIL: No validators found (total: $TOTAL)"
  exit 1
fi

echo "Active validators: $TOTAL"

# per_page=100 is the RPC maximum; a larger set would be checked only in part.
LISTED=$(echo "$RESPONSE" | jq -r '.result.validators | length')
if [ "$LISTED" -ne "$TOTAL" ]; then
  echo "FAIL: validator query returned $LISTED of $TOTAL validators"
  exit 1
fi

SIGNING=$(echo "$RESPONSE" | jq -r '[.result.validators[] | select((.voting_power // "0" | tonumber) > 0)] | length')
if [ "$SIGNING" -ne "$TOTAL" ]; then
  echo "FAIL: only $SIGNING/$TOTAL validators have voting power"
  exit 1
fi

# Local topology: the set covers every validator container and each validator signed one of the last 10 commits.
if [ "$ENV" = "local" ]; then
  EXPECTED=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ec '^validator-[0-9]+$' || true)
  if [ "${EXPECTED:-0}" -gt 0 ] && [ "$TOTAL" -lt "$EXPECTED" ]; then
    echo "FAIL: $TOTAL validators in the active set, $EXPECTED validator containers running"
    exit 1
  fi

  HEIGHT=$(curl -sf "${RPC}/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height // "0"' || true)
  if [ "${HEIGHT:-0}" -lt 2 ]; then
    echo "FAIL: chain height ${HEIGHT:-unknown} is too low to check validator signatures"
    exit 1
  fi
  FROM=$((HEIGHT - 10))
  [ "$FROM" -ge 1 ] || FROM=1
  SIGNERS=""
  for h in $(seq "$FROM" $((HEIGHT - 1))); do
    SIGNERS="$SIGNERS $(curl -sf "${RPC}/commit?height=${h}" 2>/dev/null |
      jq -r '.result.signed_header.commit.signatures[]? | select(.block_id_flag == 2) | .validator_address' 2>/dev/null || true)"
  done
  SILENT=0
  for addr in $(echo "$RESPONSE" | jq -r '.result.validators[].address'); do
    if ! echo "$SIGNERS" | grep -qw "$addr"; then
      echo "FAIL: validator $addr signed none of blocks ${FROM}-$((HEIGHT - 1))"
      SILENT=$((SILENT + 1))
    fi
  done
  if [ "$SILENT" -gt 0 ]; then
    exit 1
  fi
fi

echo "PASS: $SIGNING/$TOTAL validators active with voting power"
