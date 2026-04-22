#!/usr/bin/env bash
set -euo pipefail

STACK_FILE="${1:-stack.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"

mkdir -p "$BUILD_DIR"

# Configure git to use GH_TOKEN for private repos (CI)
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

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
    git -C "$target_dir" fetch --tags origin
    if git -C "$target_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      git -C "$target_dir" checkout "$ref"
    elif git -C "$target_dir" ls-remote --exit-code origin "$ref" >/dev/null 2>&1; then
      git -C "$target_dir" fetch origin "$ref"
      git -C "$target_dir" checkout "$ref" 2>/dev/null || git -C "$target_dir" checkout "origin/$ref"
    else
      git -C "$target_dir" fetch --depth 1 origin "$ref"
      git -C "$target_dir" checkout FETCH_HEAD
    fi
  else
    echo "  Cloning..."
    git clone --depth 1 --branch "$ref" "https://github.com/${repo}.git" "$target_dir" 2>/dev/null || \
    git clone "https://github.com/${repo}.git" "$target_dir" && git -C "$target_dir" checkout "$ref"
  fi
done

echo "=== All repos cloned ==="
