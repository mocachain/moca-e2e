#!/usr/bin/env bash
# E2E test: deploy a contract and interact with it (Store: set/get)
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"

require_write_enabled "ERC20 test"

if ! command -v cast &>/dev/null; then
  echo "SKIP: cast (Foundry) not installed"
  exit 0
fi

echo "Testing EVM contract deploy and interaction..."

# Get test private key
PRIVKEY=$(docker exec "$VALIDATOR_CONTAINER" cat /shared/metadata.json 2>/dev/null | jq -r '.test_account.evm_privkey // empty' 2>/dev/null || echo "")

if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  echo "SKIP: No test account private key"
  exit 0
fi

SENDER=$(cast wallet address "0x${PRIVKEY}" 2>/dev/null)
echo "  Deployer: $SENDER"

# Store contract, solc 0.8.26, optimizer runs=200, cbor_metadata=false,
# bytecode_hash=none (deterministic, no metadata tail):
#   contract Store {
#       uint256 private value;
#       function set(uint256 v) public { value = v; }
#       function get() public view returns (uint256) { return value; }
#   }
STORE_BYTECODE="0x6080604052348015600e575f80fd5b50606f80601a5f395ff3fe6080604052348015600e575f80fd5b50600436106030575f3560e01c806360fe47b11460345780636d4ce63c146045575b5f80fd5b6043603f3660046059565b5f55565b005b5f5460405190815260200160405180910390f35b5f602082840312156068575f80fd5b503591905056"

# Deploy contract. Flags must precede --create: cast parses everything after
# the bytecode as constructor SIG/ARGS.
echo "  Deploying storage contract..."
DEPLOY_OUTPUT=$(cast send --private-key "0x${PRIVKEY}" --rpc-url "$EVM_RPC" \
  --chain-id "$EVM_CHAIN_ID" --json \
  --create "$STORE_BYTECODE" 2>&1) || {
  echo "  FAIL: contract deployment failed: $DEPLOY_OUTPUT"
  exit 1
}

TX_HASH=$(echo "$DEPLOY_OUTPUT" | jq -r '.transactionHash // empty' 2>/dev/null)
if [ -z "$TX_HASH" ]; then
  echo "  FAIL: no tx hash from deployment: $DEPLOY_OUTPUT"
  exit 1
fi

wait_for_evm_tx "$TX_HASH" 10 || {
  echo "  FAIL: deploy tx $TX_HASH did not mine within 10s"
  exit 1
}

# Get contract address from receipt
RECEIPT=$(cast receipt "$TX_HASH" --rpc-url "$EVM_RPC" --json 2>/dev/null)
CONTRACT=$(echo "$RECEIPT" | jq -r '.contractAddress // empty' 2>/dev/null)

if [ -z "$CONTRACT" ] || [ "$CONTRACT" = "null" ]; then
  echo "  FAIL: no contract address in receipt: $RECEIPT"
  exit 1
fi

echo "  Contract deployed at: $CONTRACT"

# Verify code exists at address
CODE=$(cast code "$CONTRACT" --rpc-url "$EVM_RPC" 2>/dev/null || echo "0x")
if [ "$CODE" = "0x" ] || [ -z "$CODE" ]; then
  echo "  FAIL: No code at contract address"
  exit 1
fi
echo "  Contract code verified (${#CODE} chars)"

# Call set(42)
echo "  Calling set(42)..."
SET_OUT=$(cast send "$CONTRACT" "set(uint256)" 42 \
  --private-key "0x${PRIVKEY}" --rpc-url "$EVM_RPC" \
  --chain-id "$EVM_CHAIN_ID" --json 2>&1) || {
  echo "  FAIL: set(42) broadcast failed: $SET_OUT"
  exit 1
}
SET_HASH=$(echo "$SET_OUT" | jq -r '.transactionHash // empty' 2>/dev/null)
if [ -z "$SET_HASH" ]; then
  echo "  FAIL: set(42) returned no tx hash: $SET_OUT"
  exit 1
fi
wait_for_evm_tx "$SET_HASH" 10 || {
  echo "  FAIL: set tx $SET_HASH not mined within 10s"
  exit 1
}

# Call get() and verify
VALUE=$(cast call "$CONTRACT" "get()(uint256)" --rpc-url "$EVM_RPC" 2>/dev/null || echo "")
echo "  get() returned: $VALUE"

if [ "$VALUE" != "42" ]; then
  echo "  FAIL: get() returned '$VALUE' (expected 42)"
  exit 1
fi
echo "PASS: EVM contract deploy + interact successful"
