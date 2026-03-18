#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"
STACK_FILE="${2:-stack.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$ENV" != "local" ]; then
  echo "Setup not needed for remote environment: $ENV"
  exit 0
fi

echo "=== Setting up local Kind cluster ==="

# Check prerequisites
for cmd in kind kubectl docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed."
    exit 1
  fi
done

CLUSTER_NAME="moca-e2e"

# Create Kind cluster if it doesn't exist
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Kind cluster '$CLUSTER_NAME' already exists, reusing."
else
  echo "Creating Kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME" --config "$ROOT_DIR/kind-config.yaml" --wait 60s
fi

# Set kubeconfig
kind get kubeconfig --name "$CLUSTER_NAME" > "$ROOT_DIR/kubeconfig"
export KUBECONFIG="$ROOT_DIR/kubeconfig"

echo "=== Cloning and building components ==="
"$SCRIPT_DIR/clone-repos.sh" "$STACK_FILE"
"$SCRIPT_DIR/build.sh" "$ENV"

echo "=== Local environment ready ==="
