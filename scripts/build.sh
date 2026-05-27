#!/usr/bin/env bash
set -euo pipefail

# Pulls prebuilt Docker images for all components referenced by the topology.

ENV="${1:-local}"
TOPOLOGY="${2:-topology/default.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required. Install: brew install yq"
  exit 1
fi

echo "=== Pulling Docker images ==="

pull_image() {
  local image="$1"
  local attempt=1
  local max_attempts="${DOCKER_PULL_RETRIES:-3}"

  while [ "$attempt" -le "$max_attempts" ]; do
    if docker pull "$image"; then
      return 0
    fi
    if [ "$attempt" -eq "$max_attempts" ]; then
      break
    fi
    echo "WARN: docker pull failed for $image; retrying ($attempt/$max_attempts)..."
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done

  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "WARN: using existing local image for $image after pull failures"
    return 0
  fi

  echo "Error: failed to pull $image and no local copy is available"
  return 1
}

images="$(
  {
    yq -r '.images.genesis_init // .images.validator // ""' "$TOPOLOGY"
    yq -r '.images.validator // ""' "$TOPOLOGY"
    yq -r '.images.cosmovisor // ""' "$TOPOLOGY"
    yq -r '.images.storage_provider // ""' "$TOPOLOGY"
    yq -r '.images.moca_cmd // ""' "$TOPOLOGY"
    yq -r '.services.mysql.image // ""' "$TOPOLOGY"
  } | sed '/^null$/d;/^$/d' | sort -u
)"

if [ -z "$images" ]; then
  echo "Error: no images configured in $TOPOLOGY"
  exit 1
fi

for image in $images; do
  echo "--- Pulling $image"
  pull_image "$image"
done

echo ""
echo "=== All images pulled ==="
