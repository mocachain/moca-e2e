#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ROOT_DIR/docker-compose.generated.yml"

if [ "$ENV" != "local" ]; then
  echo "Teardown not applicable for remote environment: $ENV"
  exit 0
fi

echo "=== Tearing down local environment ==="

if [ -f "$COMPOSE_FILE" ]; then
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans --timeout 30 2>/dev/null || true
  rm -f "$COMPOSE_FILE"
  echo "Docker compose environment stopped and cleaned up."
else
  echo "No compose file found, nothing to tear down."
fi

# Clean up build artifacts
rm -rf "$ROOT_DIR/build"
rm -rf "$ROOT_DIR/test-results"

echo "=== Teardown complete ==="
