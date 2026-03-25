#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$ROOT_DIR/tests"

echo "=== E2E Test Suite: $ENV ==="

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
