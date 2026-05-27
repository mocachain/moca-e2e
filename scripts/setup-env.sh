#!/usr/bin/env bash
set -euo pipefail

# Sets up the local docker-compose environment.
# Pulls prebuilt images and starts all services.

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

# Pull required images
echo ""
echo "=== Pulling Docker images ==="
"$SCRIPT_DIR/build.sh" "$ENV" "$TOPOLOGY"

# Start services in phases to avoid docker compose wait races with
# one-shot genesis-init and dependent services.
echo ""
echo "=== Starting services ==="

echo "--- Running genesis init ---"
docker compose -f "$COMPOSE_FILE" up genesis-init

echo "--- Starting MySQL and validators ---"
docker compose -f "$COMPOSE_FILE" up -d --no-deps mysql \
  $(docker compose -f "$COMPOSE_FILE" config --services | grep '^validator-')

echo "--- Waiting for validator RPC ---"
"$SCRIPT_DIR/wait-for-chain.sh" "http://localhost:${RPC_BASE_OVERRIDE:-26657}" 5 180

echo "--- Starting storage providers ---"
SP_SERVICES="$(docker compose -f "$COMPOSE_FILE" config --services | grep '^sp-' | tr '\n' ' ')"
if [ -n "$SP_SERVICES" ]; then
  docker compose -f "$COMPOSE_FILE" up -d --no-deps $SP_SERVICES
fi

echo "--- Waiting for storage providers ---"
for sp in $(docker compose -f "$COMPOSE_FILE" config --services | grep '^sp-' || true); do
  echo "  Waiting for $sp..."
  timeout 180 bash -lc "
    until [ \"\$(docker inspect --format='{{.State.Health.Status}}' $sp 2>/dev/null)\" = 'healthy' ]; do
      status=\$(docker inspect --format='{{.State.Health.Status}}' $sp 2>/dev/null || echo 'unknown')
      [ \"\$status\" = 'unhealthy' ] && docker logs $sp --tail 80 >&2
      sleep 5
    done
  "
done

echo ""
echo "=== Local environment ready ==="
docker compose -f "$COMPOSE_FILE" ps
