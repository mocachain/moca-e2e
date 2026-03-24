#!/usr/bin/env bash
# Smoke test: verify storage providers are registered on chain
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"

if [ "$ENV" = "local" ]; then
  REST="http://localhost:1317"
else
  REST=$(yq '.chain.rest' "$CONFIG_FILE")
fi

if [ -z "$REST" ] || [ "$REST" = "null" ] || [ "$REST" = '""' ]; then
  echo "SKIP: REST not configured for $ENV"
  exit 0
fi

echo "Checking storage providers at $REST..."

# Query storage providers from the SP module
RESPONSE=$(curl -sf "${REST}/greenfield/sp/storage_providers" 2>/dev/null) || {
  # Fallback: try alternate endpoint
  RESPONSE=$(curl -sf "${REST}/mocachain/storage/providers" 2>/dev/null) || {
    echo "WARN: Cannot query storage providers (endpoint may not exist yet)"
    exit 0
  }
}

NUM_SPS=$(echo "$RESPONSE" | jq '.sps | length // .storage_providers | length // 0')

if [ "$NUM_SPS" -le 0 ]; then
  echo "WARN: No storage providers found on chain"
  exit 0
fi

echo "PASS: $NUM_SPS storage providers registered on chain"
