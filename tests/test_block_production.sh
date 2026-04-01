#!/usr/bin/env bash
# E2E test: verify chain produces blocks over time (not stuck)
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
RPC="${RPC:-$(yq -r '.chain.rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)}"

if [ -z "$RPC" ] || [ "$RPC" = "null" ] || [ "$RPC" = '""' ]; then
  echo "SKIP: RPC not configured for $ENV"
  exit 0
fi

echo "Testing block production rate..."

# Sample height twice with a gap
HEIGHT_1=$(curl -sf "$RPC/status" | jq -r '.result.sync_info.latest_block_height')
echo "  Height at T=0: $HEIGHT_1"

sleep 10

HEIGHT_2=$(curl -sf "$RPC/status" | jq -r '.result.sync_info.latest_block_height')
echo "  Height at T=10s: $HEIGHT_2"

BLOCKS=$((HEIGHT_2 - HEIGHT_1))

if [ "$BLOCKS" -le 0 ]; then
  echo "FAIL: Chain is not producing blocks ($BLOCKS blocks in 10s)"
  exit 1
fi

RATE=$(echo "scale=1; $BLOCKS / 10" | bc 2>/dev/null || echo "$BLOCKS/10")
echo "PASS: Chain produced $BLOCKS blocks in 10s (~${RATE} blocks/sec)"
