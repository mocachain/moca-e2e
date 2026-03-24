#!/usr/bin/env bash
set -euo pipefail

# Sets up the local docker-compose environment.
# Builds images from cloned repos and starts all services.

ENV="${1:-local}"
STACK_FILE="${2:-stack.yaml}"
TOPOLOGY="${3:-topology/default.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$ENV" != "local" ]; then
  echo "Setup not needed for remote environment: $ENV"
  exit 0
fi

echo "=== Setting up local environment ==="

# Check prerequisites
for cmd in docker yq jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed."
    exit 1
  fi
done

# Check docker compose (v2)
if ! docker compose version &>/dev/null; then
  echo "Error: docker compose v2 is required."
  exit 1
fi

COMPOSE_FILE="$ROOT_DIR/docker-compose.generated.yml"

# Generate compose file if not already done
if [ ! -f "$COMPOSE_FILE" ]; then
  "$SCRIPT_DIR/generate-compose.sh" "$TOPOLOGY" "$COMPOSE_FILE"
fi

# Build all images
echo ""
echo "=== Building Docker images ==="
"$SCRIPT_DIR/build.sh" "$ENV"

# Start services
echo ""
echo "=== Starting services ==="
docker compose -f "$COMPOSE_FILE" up -d --wait --timeout 180

echo ""
echo "=== Local environment ready ==="
docker compose -f "$COMPOSE_FILE" ps
