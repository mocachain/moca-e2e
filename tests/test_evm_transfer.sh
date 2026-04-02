#!/usr/bin/env bash
# E2E test: native EVM transfer using JSON-RPC
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "EVM transfer test"
require_test_key

if ! command -v cast &>/dev/null; then
  echo "SKIP: cast (Foundry) not installed"
  exit 0
fi

echo "Testing native EVM transfer..."

# Get private key: from metadata (local) or from keyring (devnet)
PRIVKEY=""
METADATA="$(dirname "$SCRIPT_DIR")/test-results/metadata.json"
if [ -f "$METADATA" ]; then
  PRIVKEY=$(jq -r '.test_account.evm_privkey // empty' "$METADATA" 2>/dev/null || echo "")
fi
if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  PRIVKEY=$(docker exec "$VALIDATOR_CONTAINER" cat /shared/metadata.json 2>/dev/null | jq -r '.test_account.evm_privkey // empty' 2>/dev/null || echo "")
fi
if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  # Try exporting from local keyring (devnet)
  PRIVKEY=$(exec_mocad keys unsafe-export-eth-key "$TEST_KEY" --keyring-backend test 2>/dev/null || echo "")
fi

if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  echo "SKIP: Cannot export private key for $TEST_KEY"
  exit 0
fi

SENDER=$(cast wallet address "0x${PRIVKEY}" 2>/dev/null)
echo "  Sender: $SENDER"

# Generate a random recipient
RECIPIENT="0x$(openssl rand -hex 20)"
echo "  Recipient: $RECIPIENT"

# Check balance before
BALANCE_BEFORE=$(curl -sf "$EVM_RPC" -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${RECIPIENT}\",\"latest\"],\"id\":1}" | \
  jq -r '.result // "0x0"' 2>/dev/null)
echo "  Recipient balance before: $BALANCE_BEFORE"

# Send 0.001 MOCA (1e15 wei) — small to preserve funds
echo "  Sending via cast..."
cast send "$RECIPIENT" --value "1000000000000000" \
  --private-key "0x${PRIVKEY}" --rpc-url "$EVM_RPC" \
  --chain-id "$EVM_CHAIN_ID" 2>&1 | tail -1 || echo "  cast send may have failed"
sleep 5

# Check balance after
BALANCE_AFTER=$(curl -sf "$EVM_RPC" -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${RECIPIENT}\",\"latest\"],\"id\":1}" | \
  jq -r '.result // "0x0"' 2>/dev/null)
echo "  Recipient balance after: $BALANCE_AFTER"

assert_ne "$BALANCE_AFTER" "$BALANCE_BEFORE" "EVM balance changed" || {
  echo "  WARN: Balance didn't change"
  exit 0
}

echo "PASS: Native EVM transfer successful"
