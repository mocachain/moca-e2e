#!/usr/bin/env bash
set -euo pipefail

# Builds Docker images for all components from cloned repos.
# The cloned repos should be in ./build/ (placed there by clone-repos.sh).

ENV="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"

echo "=== Building Docker images ==="

# Verify repos are cloned
if [ ! -d "$BUILD_DIR/moca" ]; then
  echo "Error: moca repo not cloned at $BUILD_DIR/moca"
  echo "Run: make clone"
  exit 1
fi

# --- Build mocad image (plain docker) ---
echo "--- Building mocad image ---"
docker build \
  -t mocad-local:latest \
  -f "$ROOT_DIR/docker/Dockerfile.mocad" \
  --build-arg TARGETARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
  "$ROOT_DIR"

# --- Build cosmovisor image ---
echo "--- Building cosmovisor image ---"
docker build \
  -t mocad-cosmovisor:latest \
  -f "$ROOT_DIR/docker/Dockerfile.cosmovisor" \
  --build-arg TARGETARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
  "$ROOT_DIR"

# --- Build SP image (if cloned) ---
if [ -d "$BUILD_DIR/moca-storage-provider" ]; then
  echo "--- Building storage provider image ---"
  docker build \
    -t moca-sp-local:latest \
    -f "$ROOT_DIR/docker/Dockerfile.sp" \
    --build-arg TARGETARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
    "$ROOT_DIR"
else
  echo "Warning: moca-storage-provider not cloned, skipping SP image build"
fi

# --- Build init image (reuses mocad-local as base) ---
echo "--- Building genesis-init image ---"
docker build \
  -t moca-genesis-init:latest \
  -f "$ROOT_DIR/docker/Dockerfile.init" \
  "$ROOT_DIR"

echo ""
echo "=== All images built ==="
docker images | grep -E "(mocad-local|mocad-cosmovisor|moca-sp-local|moca-genesis-init)" || true
