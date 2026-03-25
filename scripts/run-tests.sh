#!/usr/bin/env bash
set -euo pipefail

# Main entry point for E2E tests.
# Usage: ./run-tests.sh [env] [stack-file] [topology]
#
# For local: spins up docker-compose, runs tests, tears down
# For remote: runs tests against live endpoints

ENV="${1:-local}"
STACK_FILE="${2:-stack.yaml}"
TOPOLOGY="${3:-topology/default.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$ROOT_DIR/config/${ENV}.yaml"

if [ "$ENV" != "local" ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config file not found: $CONFIG_FILE"
  exit 1
fi

echo "=== moca-e2e ==="
echo "  Environment: $ENV"
echo "  Stack: $STACK_FILE"
echo "  Topology: $TOPOLOGY"
echo ""

TEST_EXIT=0

if [ "$ENV" = "local" ]; then
  # --- Local: full docker-compose lifecycle ---

  # 1. Clone repos at stack.yaml refs
  "$SCRIPT_DIR/clone-repos.sh" "$STACK_FILE"

  # 2. Generate docker-compose from topology
  COMPOSE_FILE="$ROOT_DIR/docker-compose.generated.yml"
  "$SCRIPT_DIR/generate-compose.sh" "$TOPOLOGY" "$COMPOSE_FILE"

  # 3. Build images and start
  "$SCRIPT_DIR/setup-env.sh" local "$STACK_FILE" "$TOPOLOGY"

  # 4. Wait for chain
  "$SCRIPT_DIR/wait-for-chain.sh" "http://localhost:26657" 5 120

  # 5. Run tests
  echo ""
  echo "=== Running E2E test suite ==="
  "$SCRIPT_DIR/run-suite.sh" "$ENV" "$CONFIG_FILE" || TEST_EXIT=$?

  # 6. Collect logs on failure (kept for debugging)
  if [ $TEST_EXIT -ne 0 ]; then
    echo ""
    echo "=== Collecting logs ==="
    mkdir -p "$ROOT_DIR/test-results/logs"
    docker compose -f "$COMPOSE_FILE" logs > "$ROOT_DIR/test-results/logs/all.log" 2>&1 || true
  fi

  # 8. Teardown (unless SKIP_TEARDOWN is set)
  if [ "${SKIP_TEARDOWN:-}" != "true" ]; then
    "$SCRIPT_DIR/teardown.sh" local
  fi

else
  # --- Remote: just run tests against live endpoints ---
  echo "=== Running tests against $ENV ==="
  "$SCRIPT_DIR/run-suite.sh" "$ENV" "$CONFIG_FILE" || TEST_EXIT=$?
fi

echo ""
if [ $TEST_EXIT -eq 0 ]; then
  echo "=== All E2E tests passed ==="
else
  echo "=== E2E tests FAILED (exit code: $TEST_EXIT) ==="
fi

exit $TEST_EXIT
