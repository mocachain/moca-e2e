#!/usr/bin/env bash
# Smoke test: verify storage providers are registered on chain
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
REST="${REST:-$(yq -r '.chain.rest // .chain.api // ""' "$CONFIG_FILE" 2>/dev/null || true)}"

if [ -z "$REST" ] || [ "$REST" = "null" ] || [ "$REST" = '""' ]; then
  echo "SKIP: REST not configured for $ENV"
  exit 0
fi

echo "Checking storage providers at $REST..."

# Query storage providers from the SP module
RESPONSE=$(curl -sf "${REST}/moca/storage_providers" 2>/dev/null) || {
  echo "FAIL: cannot query storage providers via REST"
  exit 1
}

NUM_SPS=$(echo "$RESPONSE" | jq '.sps | length // 0')

if [ "$NUM_SPS" -le 0 ]; then
  echo "FAIL: no storage providers found on chain"
  exit 1
fi

echo "PASS: $NUM_SPS storage providers registered on chain"
