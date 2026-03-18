#!/usr/bin/env bash
set -euo pipefail

STACK_FILE="${1:-stack.yaml}"

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required. Install: brew install yq"
  exit 1
fi

echo "=== Validating stack refs ==="

ERRORS=0
for component in $(yq '.components | keys | .[]' "$STACK_FILE"); do
  repo=$(yq ".components.${component}.repo" "$STACK_FILE")
  ref=$(yq ".components.${component}.ref" "$STACK_FILE")

  echo -n "  $component ($repo @ $ref): "
  if git ls-remote "https://github.com/${repo}.git" "$ref" &>/dev/null; then
    echo "OK"
  else
    echo "FAILED (ref not found or repo inaccessible)"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ $ERRORS -gt 0 ]; then
  echo "=== Validation failed: $ERRORS errors ==="
  exit 1
fi

echo "=== All refs valid ==="
