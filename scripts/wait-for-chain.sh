#!/usr/bin/env bash
set -euo pipefail

# Wait for the chain to start producing blocks.
# Usage: ./wait-for-chain.sh [rpc-url] [min-height] [timeout-seconds]

RPC_URL="${1:-http://localhost:26657}"
MIN_HEIGHT="${2:-3}"
TIMEOUT="${3:-120}"

echo "Waiting for chain at $RPC_URL to reach height $MIN_HEIGHT (timeout: ${TIMEOUT}s)..."

for i in $(seq 1 "$TIMEOUT"); do
  RESPONSE=$(curl -sf "$RPC_URL/status" 2>/dev/null) || true

  if [ -n "$RESPONSE" ]; then
    HEIGHT=$(echo "$RESPONSE" | jq -r '.result.sync_info.latest_block_height // "0"')
    CATCHING_UP=$(echo "$RESPONSE" | jq -r '.result.sync_info.catching_up')

    if [ "$HEIGHT" -ge "$MIN_HEIGHT" ] 2>/dev/null; then
      echo "Chain is ready. Height: $HEIGHT"
      exit 0
    fi

    if [ $((i % 10)) -eq 0 ]; then
      echo "  Height: $HEIGHT, Catching up: $CATCHING_UP"
    fi
  fi

  sleep 1
done

echo "Error: chain did not become ready after ${TIMEOUT}s"
exit 1
