#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"
STACK_FILE="${2:-stack.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$ROOT_DIR/config/${ENV}.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config file not found: $CONFIG_FILE"
  exit 1
fi

echo "=== moca-e2e: Running tests against $ENV ==="
echo "Stack: $STACK_FILE"
echo "Config: $CONFIG_FILE"
echo ""

# Setup environment if local
if [ "$ENV" = "local" ]; then
  "$SCRIPT_DIR/setup-env.sh" "$ENV" "$STACK_FILE"
fi

# Run tests
echo "=== Running E2E test suite ==="
"$SCRIPT_DIR/run-suite.sh" "$ENV" "$CONFIG_FILE"
TEST_EXIT=$?

# Teardown if local (and cleanup is desired)
if [ "$ENV" = "local" ]; then
  "$SCRIPT_DIR/teardown.sh" "$ENV" || true
fi

if [ $TEST_EXIT -eq 0 ]; then
  echo "=== All E2E tests passed ==="
else
  echo "=== E2E tests FAILED (exit code: $TEST_EXIT) ==="
fi

exit $TEST_EXIT
