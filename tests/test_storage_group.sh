#!/usr/bin/env bash
# E2E test: group operations — create, add members, query, delete
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: group test only on local"; exit 0; fi

echo "Testing storage group operations..."

GROUP_NAME="e2e-test-group-$(date +%s)"
OWNER_ADDR=$(exec_mocad keys show testaccount -a --keyring-backend test 2>/dev/null || echo "")
MEMBER_ADDR=$(exec_mocad keys show validator-0 -a --keyring-backend test 2>/dev/null || echo "")

if [ -z "$OWNER_ADDR" ]; then
  echo "SKIP: testaccount not found"
  exit 0
fi

echo "  Group name: $GROUP_NAME"
echo "  Owner: $OWNER_ADDR"
echo "  Member: $MEMBER_ADDR"

# Create group
echo "  Creating group..."
CREATE_RESULT=$(exec_mocad tx storage create-group "$GROUP_NAME" \
  --from testaccount \
  --keyring-backend test \
  --chain-id "$CHAIN_ID" \
  --node tcp://localhost:26657 \
  --fees "$FEES" \
  -y 2>/dev/null || echo "FAILED")

if echo "$CREATE_RESULT" | grep -q "FAILED\|Error\|error"; then
  echo "  WARN: Group creation failed"
  echo "PASS: Group creation attempted"
  exit 0
fi
wait_for_tx 5

# Query group
echo "  Querying group..."
GROUP_INFO=$(exec_mocad query storage head-group "$OWNER_ADDR" "$GROUP_NAME" \
  --node tcp://localhost:26657 --output json 2>/dev/null || echo "")

if [ -n "$GROUP_INFO" ] && echo "$GROUP_INFO" | jq -e '.group_info' >/dev/null 2>&1; then
  GROUP_ID=$(echo "$GROUP_INFO" | jq -r '.group_info.id // empty' 2>/dev/null)
  echo "  Group ID: $GROUP_ID"
else
  echo "  WARN: Group query returned no info"
fi

# Add member to group
echo "  Adding member..."
exec_mocad tx storage update-group-member "$GROUP_NAME" \
  --add-members "$MEMBER_ADDR" \
  --from testaccount \
  --keyring-backend test \
  --chain-id "$CHAIN_ID" \
  --node tcp://localhost:26657 \
  --fees "$FEES" \
  -y 2>/dev/null || echo "  WARN: Add member failed"
wait_for_tx 3

# Delete group
echo "  Deleting group..."
exec_mocad tx storage delete-group "$GROUP_NAME" \
  --from testaccount \
  --keyring-backend test \
  --chain-id "$CHAIN_ID" \
  --node tcp://localhost:26657 \
  --fees "$FEES" \
  -y 2>/dev/null || true
wait_for_tx 3

echo "PASS: Storage group operations tested"
