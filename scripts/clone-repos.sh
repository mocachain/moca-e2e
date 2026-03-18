#!/usr/bin/env bash
set -euo pipefail

STACK_FILE="${1:-stack.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"

mkdir -p "$BUILD_DIR"

echo "=== Cloning repos from $STACK_FILE ==="

# Parse stack.yaml and clone each component at its ref
# Requires yq (https://github.com/mikefarah/yq)
if ! command -v yq &>/dev/null; then
  echo "Error: yq is required. Install: brew install yq"
  exit 1
fi

for component in $(yq '.components | keys | .[]' "$STACK_FILE"); do
  repo=$(yq ".components.${component}.repo" "$STACK_FILE")
  ref=$(yq ".components.${component}.ref" "$STACK_FILE")
  target_dir="$BUILD_DIR/$component"

  echo "--- $component: $repo @ $ref"

  if [ -d "$target_dir/.git" ]; then
    echo "  Already cloned, fetching and checking out $ref"
    git -C "$target_dir" fetch origin
    git -C "$target_dir" checkout "$ref" 2>/dev/null || git -C "$target_dir" checkout "origin/$ref"
  else
    echo "  Cloning..."
    git clone --depth 1 --branch "$ref" "https://github.com/${repo}.git" "$target_dir" 2>/dev/null || \
    git clone "https://github.com/${repo}.git" "$target_dir" && git -C "$target_dir" checkout "$ref"
  fi
done

echo "=== All repos cloned ==="
