#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$ROOT_DIR/tests"

echo "=== E2E Test Suite: $ENV ==="

# Export per-environment endpoints for all test scripts.
if [ -f "$CONFIG_FILE" ]; then
  CHAIN_ID_VALUE="$(yq -r '.chain.chain_id // ""' "$CONFIG_FILE" 2>/dev/null || true)"
  RPC_VALUE="$(yq -r '.chain.rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)"
  REST_VALUE="$(yq -r '.chain.rest // .chain.api // ""' "$CONFIG_FILE" 2>/dev/null || true)"
  EVM_RPC_VALUE="$(yq -r '.chain.evm_rpc // ""' "$CONFIG_FILE" 2>/dev/null || true)"

  [ -n "$CHAIN_ID_VALUE" ] && [ "$CHAIN_ID_VALUE" != "null" ] && export CHAIN_ID="$CHAIN_ID_VALUE"
  [ -n "$RPC_VALUE" ] && [ "$RPC_VALUE" != "null" ] && export RPC="$RPC_VALUE"
  [ -n "$REST_VALUE" ] && [ "$REST_VALUE" != "null" ] && export REST="$REST_VALUE"
  [ -n "$EVM_RPC_VALUE" ] && [ "$EVM_RPC_VALUE" != "null" ] && export EVM_RPC="$EVM_RPC_VALUE"
fi

echo "  CHAIN_ID=${CHAIN_ID:-<default>}"
echo "  RPC=${RPC:-<default>}"
echo "  REST=${REST:-<default>}"
echo "  EVM_RPC=${EVM_RPC:-<default>}"
if [ "${ALLOW_WRITES:-0}" = "1" ] || [ "${E2E_ALLOW_WRITES:-0}" = "1" ]; then
  echo "  Writes: enabled (ALLOW_WRITES=1)"
else
  echo "  Writes: disabled for non-local envs (set ALLOW_WRITES=1 to override)"
fi

# Determine which test suites to run based on environment
if [ "$ENV" = "mainnet" ]; then
  echo "Mainnet: running smoke tests only (readonly)"
  TEST_PATTERN="smoke_*.sh"
else
  TEST_PATTERN="*.sh"
fi

PASSED=0
FAILED=0
ERRORS=""

for test_file in "$TESTS_DIR"/$TEST_PATTERN; do
  [ -f "$test_file" ] || continue
  test_name=$(basename "$test_file")
  # Skip helper libraries
  [ "$test_name" = "lib.sh" ] && continue
  echo ""
  echo "--- Running: $test_name"

  if bash "$test_file" "$ENV" "$CONFIG_FILE"; then
    echo "  PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $test_name"
    FAILED=$((FAILED + 1))
    ERRORS="$ERRORS\n  - $test_name"
  fi
done

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ $FAILED -gt 0 ]; then
  echo -e "Failed tests:$ERRORS"
  exit 1
fi

if [ $PASSED -eq 0 ]; then
  echo "Warning: no tests found matching pattern '$TEST_PATTERN' in $TESTS_DIR"
  exit 0
fi
