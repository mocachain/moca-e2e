#!/usr/bin/env bash
# Smoke test: verify chain is reachable and producing blocks
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
RPC="${RPC:-$(yq -r '.chain.rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)}"

if [ -z "$RPC" ] || [ "$RPC" = "null" ] || [ "$RPC" = '""' ]; then
  echo "SKIP: RPC not configured for $ENV"
  exit 0
fi

echo "Checking chain status at $RPC..."

RESPONSE=$(curl -sf "${RPC}/status" 2>/dev/null) || {
  echo "FAIL: Cannot reach chain RPC at $RPC"
  exit 1
}

LATEST_HEIGHT=$(echo "$RESPONSE" | jq -r '.result.sync_info.latest_block_height // empty')

if [ -z "$LATEST_HEIGHT" ]; then
  echo "FAIL: Could not parse latest_block_height"
  exit 1
fi

if [ "$LATEST_HEIGHT" -le 0 ]; then
  echo "FAIL: Block height is $LATEST_HEIGHT (expected > 0)"
  exit 1
fi

echo "PASS: Chain is producing blocks (height: $LATEST_HEIGHT)"
