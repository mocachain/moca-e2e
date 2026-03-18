#!/usr/bin/env bash
set -euo pipefail

STACK_FILE="${1:-stack.yaml}"
REPO="${2:-}"
REF="${3:-}"

if [ -z "$REPO" ] || [ -z "$REF" ]; then
  echo "Usage: $0 <stack.yaml> <component-name> <ref>"
  echo "Example: $0 stack.yaml moca abc1234"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required. Install: brew install yq"
  exit 1
fi

# Check component exists
if [ "$(yq ".components.${REPO}" "$STACK_FILE")" = "null" ]; then
  echo "Error: component '$REPO' not found in $STACK_FILE"
  exit 1
fi

OLD_REF=$(yq ".components.${REPO}.ref" "$STACK_FILE")
yq -i ".components.${REPO}.ref = \"${REF}\"" "$STACK_FILE"
echo "Updated $REPO: $OLD_REF -> $REF"
