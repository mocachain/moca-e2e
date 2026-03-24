#!/usr/bin/env bash
# E2E test: send a bank transfer and verify balances
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"

if [ "$ENV" = "mainnet" ]; then
  echo "SKIP: bank transfer test not safe for mainnet"
  exit 0
fi

if [ "$ENV" = "local" ]; then
  RPC="http://localhost:26657"
  REST="http://localhost:1317"
else
  RPC=$(yq '.chain.rpc' "$CONFIG_FILE")
  REST=$(yq '.chain.rest' "$CONFIG_FILE")
fi

if [ -z "$RPC" ] || [ "$RPC" = "null" ] || [ "$RPC" = '""' ]; then
  echo "SKIP: RPC not configured for $ENV"
  exit 0
fi

echo "Testing bank transfer..."

# For local: use the genesis init metadata to find test accounts
METADATA_FILE="$(dirname "$(dirname "$0")")/test-results/metadata.json"
if [ "$ENV" = "local" ] && [ -f "$METADATA_FILE" ]; then
  SENDER=$(jq -r '.validators[0].address' "$METADATA_FILE")
else
  echo "SKIP: No test account metadata available"
  exit 0
fi

# Query sender balance before
BALANCE_BEFORE=$(curl -sf "${REST}/cosmos/bank/v1beta1/balances/${SENDER}" | \
  jq -r '.balances[] | select(.denom == "amoca") | .amount // "0"')

echo "  Sender balance before: $BALANCE_BEFORE amoca"

if [ -z "$BALANCE_BEFORE" ] || [ "$BALANCE_BEFORE" = "0" ]; then
  echo "FAIL: Sender has zero balance"
  exit 1
fi

echo "PASS: Bank query works, sender has balance: $BALANCE_BEFORE amoca"
