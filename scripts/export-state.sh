#!/usr/bin/env bash
set -euo pipefail

# Exports app hash at multiple block heights for cross-architecture comparison.
# The app hash is a merkle root of the entire app state — if two architectures
# produce the same app hash at the same height, the state machine is deterministic.
#
# Strategy:
#   1. Wait for chain to reach target height (empty blocks, no txs)
#   2. Export app hash at each checkpoint height
#   3. Also export the full validator set hash and last block hash
#   4. Write results to a JSON file for comparison
#
# Usage: ./export-state.sh [rpc-url] [output-file] [target-height]

RPC_URL="${1:-http://localhost:26657}"
OUTPUT_FILE="${2:-state-hashes.json}"
TARGET_HEIGHT="${3:-100}"

# Checkpoint heights to compare (must all be before target)
CHECKPOINTS="10 25 50 75 ${TARGET_HEIGHT}"

echo "=== Exporting state hashes ==="
echo "  RPC: $RPC_URL"
echo "  Target height: $TARGET_HEIGHT"
echo "  Checkpoints: $CHECKPOINTS"
echo ""

# Wait for target height
echo "Waiting for chain to reach height $TARGET_HEIGHT..."
for attempt in $(seq 1 600); do
  CURRENT=$(curl -sf "$RPC_URL/status" | jq -r '.result.sync_info.latest_block_height // "0"')
  if [ "$CURRENT" -ge "$TARGET_HEIGHT" ] 2>/dev/null; then
    echo "Chain at height $CURRENT (target: $TARGET_HEIGHT)"
    break
  fi
  if [ "$attempt" -eq 600 ]; then
    echo "Error: chain did not reach height $TARGET_HEIGHT after 600s (current: $CURRENT)"
    exit 1
  fi
  if [ $((attempt % 30)) -eq 0 ]; then
    echo "  Waiting... current height: $CURRENT"
  fi
  sleep 1
done

# Collect state hashes at each checkpoint
echo ""
echo "Collecting state hashes at checkpoints..."

RESULTS="[]"

for HEIGHT in $CHECKPOINTS; do
  echo -n "  Height $HEIGHT: "

  # Get block at specific height
  BLOCK=$(curl -sf "$RPC_URL/block?height=$HEIGHT")

  if [ -z "$BLOCK" ]; then
    echo "FAILED (could not fetch block)"
    continue
  fi

  APP_HASH=$(echo "$BLOCK" | jq -r '.result.block.header.app_hash // empty')
  BLOCK_HASH=$(echo "$BLOCK" | jq -r '.result.block_id.hash // empty')
  VALIDATORS_HASH=$(echo "$BLOCK" | jq -r '.result.block.header.validators_hash // empty')
  CONSENSUS_HASH=$(echo "$BLOCK" | jq -r '.result.block.header.consensus_hash // empty')
  DATA_HASH=$(echo "$BLOCK" | jq -r '.result.block.header.data_hash // empty')
  LAST_RESULTS_HASH=$(echo "$BLOCK" | jq -r '.result.block.header.last_results_hash // empty')
  NUM_TXS=$(echo "$BLOCK" | jq -r '.result.block.data.txs | length // 0')

  echo "app_hash=$APP_HASH txs=$NUM_TXS"

  ENTRY=$(jq -n \
    --argjson height "$HEIGHT" \
    --arg app_hash "$APP_HASH" \
    --arg block_hash "$BLOCK_HASH" \
    --arg validators_hash "$VALIDATORS_HASH" \
    --arg consensus_hash "$CONSENSUS_HASH" \
    --arg data_hash "$DATA_HASH" \
    --arg last_results_hash "$LAST_RESULTS_HASH" \
    --argjson num_txs "$NUM_TXS" \
    '{
      height: $height,
      app_hash: $app_hash,
      block_hash: $block_hash,
      validators_hash: $validators_hash,
      consensus_hash: $consensus_hash,
      data_hash: $data_hash,
      last_results_hash: $last_results_hash,
      num_txs: $num_txs
    }')

  RESULTS=$(echo "$RESULTS" | jq --argjson entry "$ENTRY" '. + [$entry]')
done

# Get node info for metadata
NODE_INFO=$(curl -sf "$RPC_URL/status")
MONIKER=$(echo "$NODE_INFO" | jq -r '.result.node_info.moniker // "unknown"')
NETWORK=$(echo "$NODE_INFO" | jq -r '.result.node_info.network // "unknown"')

# Get architecture from the first validator (the one we're querying)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
esac

# Write output
jq -n \
  --arg arch "$ARCH" \
  --arg network "$NETWORK" \
  --arg moniker "$MONIKER" \
  --arg rpc "$RPC_URL" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson checkpoints "$RESULTS" \
  '{
    metadata: {
      architecture: $arch,
      network: $network,
      moniker: $moniker,
      rpc: $rpc,
      exported_at: $timestamp
    },
    checkpoints: $checkpoints
  }' > "$OUTPUT_FILE"

echo ""
echo "=== State hashes exported to $OUTPUT_FILE ==="
cat "$OUTPUT_FILE" | jq .
