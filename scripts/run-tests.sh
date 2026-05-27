#!/usr/bin/env bash
set -euo pipefail

# Main entry point for E2E tests.
# Usage: ./run-tests.sh [env] [stack-file] [topology]
#
# For local: generates docker-compose from image refs, runs tests, tears down
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
SHOULD_TEARDOWN=false

cleanup() {
  if [ "$SHOULD_TEARDOWN" = "true" ] && [ "${SKIP_TEARDOWN:-}" != "true" ]; then
    "$SCRIPT_DIR/teardown.sh" local || true
  fi
}

if [ "$ENV" = "local" ]; then
  # --- Local: full docker-compose lifecycle ---
  SHOULD_TEARDOWN=true
  trap cleanup EXIT

  # Clean up any prior interrupted local run before binding ports again.
  "$SCRIPT_DIR/teardown.sh" local

  # 1. Generate docker-compose from topology
  COMPOSE_FILE="$ROOT_DIR/docker-compose.generated.yml"
  "$SCRIPT_DIR/generate-compose.sh" "$TOPOLOGY" "$COMPOSE_FILE"

  # 2. Start services from prebuilt images
  "$SCRIPT_DIR/setup-env.sh" local "$STACK_FILE" "$TOPOLOGY"

  # 3. Wait for chain
  RPC_PORT="${RPC_BASE_OVERRIDE:-26657}"
  "$SCRIPT_DIR/wait-for-chain.sh" "http://localhost:${RPC_PORT}" 5 120

  # 4. Run tests
  echo ""
  echo "=== Running E2E test suite ==="
  "$SCRIPT_DIR/run-suite.sh" "$ENV" "$CONFIG_FILE" || TEST_EXIT=$?

  # 5. Collect logs on failure (kept for debugging)
  if [ $TEST_EXIT -ne 0 ]; then
    echo ""
    echo "=== Collecting logs ==="
    mkdir -p "$ROOT_DIR/test-results/logs"
    docker compose -f "$COMPOSE_FILE" logs > "$ROOT_DIR/test-results/logs/all.log" 2>&1 || true
  fi

  # 6. Teardown (unless SKIP_TEARDOWN is set)
  cleanup
  SHOULD_TEARDOWN=false

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
