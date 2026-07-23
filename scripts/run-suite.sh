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
SKIPPED=0
FAILED=0
ERRORS=""
SKIPS=""

# Map each test to a shard group so parallel CI jobs can run disjoint subsets:
#   chain — consensus / bank / staking / EVM (no SP dependency)
#   sp    — SP registration, config, lifecycle (incl. sp-exit)
#   flows — storage / payment / virtualgroup / object-failover (also any new test)
group_of() {
  case "$1" in
    smoke_sp_status.sh|test_sp_*) echo sp ;;
    smoke_chain_status.sh|smoke_validator_set.sh|test_bank_*|test_block_*|test_cross_*|test_staking*|test_validator_*|test_evm_*) echo chain ;;
    *) echo flows ;;
  esac
}

for test_file in "$TESTS_DIR"/$TEST_PATTERN; do
  [ -f "$test_file" ] || continue
  test_name=$(basename "$test_file")
  # Skip helper libraries
  [ "$test_name" = "lib.sh" ] && continue
  # Shard filter: when TEST_GROUP is set, run only that group's tests (parallel CI).
  if [ -n "${TEST_GROUP:-}" ] && [ "$(group_of "$test_name")" != "$TEST_GROUP" ]; then
    continue
  fi
  echo ""
  echo "--- Running: $test_name"

  # Capture output to classify a skip, while still streaming it to the log via tee.
  out_file="$(mktemp)"
  set +e
  bash "$test_file" "$ENV" "$CONFIG_FILE" 2>&1 | tee "$out_file"
  rc=${PIPESTATUS[0]}
  set -e
  # Last non-blank line, leading whitespace stripped — used for the SKIP marker.
  last_line="$(grep -vE '^[[:space:]]*$' "$out_file" | tail -n 1 | sed 's/^[[:space:]]*//')"
  rm -f "$out_file"

  # SKIPPED = the reserved skip code 77 (from skip()), or exit 0 whose final line is
  # a `SKIP:` marker (legacy inline skips). A skip is never counted as a pass.
  if [ "$rc" -eq 77 ] || { [ "$rc" -eq 0 ] && [ "${last_line#SKIP:}" != "$last_line" ]; }; then
    echo "  SKIP: $test_name"
    SKIPPED=$((SKIPPED + 1))
    SKIPS="$SKIPS\n  - $test_name"
  elif [ "$rc" -eq 0 ]; then
    echo "  PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $test_name"
    FAILED=$((FAILED + 1))
    ERRORS="$ERRORS\n  - $test_name"
  fi
done

echo ""
echo "=== Results: $PASSED passed, $SKIPPED skipped, $FAILED failed ==="
[ "$SKIPPED" -gt 0 ] && echo -e "Skipped tests:$SKIPS"

if [ "$FAILED" -gt 0 ]; then
  echo -e "Failed tests:$ERRORS"
  exit 1
fi

# A shard that matched no tests is a misconfiguration (bad/renamed TEST_GROUP),
# not a pass — otherwise an empty shard would go green having run nothing.
if [ $((PASSED + SKIPPED)) -eq 0 ]; then
  if [ -n "${TEST_GROUP:-}" ]; then
    echo "Error: shard TEST_GROUP='$TEST_GROUP' matched no tests"
    exit 1
  fi
  echo "Warning: no tests found matching pattern '$TEST_PATTERN' in $TESTS_DIR"
  exit 0
fi

# Strict mode (CI shards): a skip means a precondition that should hold in the
# controlled cluster didn't, so fail loudly instead of passing green with a gap.
if [ "${STRICT_SKIPS:-0}" = "1" ] && [ "$SKIPPED" -gt 0 ]; then
  echo "Error: STRICT_SKIPS=1 and $SKIPPED test(s) skipped:$SKIPS"
  exit 1
fi
