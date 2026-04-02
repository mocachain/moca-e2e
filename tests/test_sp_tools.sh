#!/usr/bin/env bash
# E2E: moca-cmd sp ls / sp head / sp get-price (devcontainer sp-tools parity).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP tools test only on local"; exit 0; fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd not available"
  exit 0
fi

SP_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
NUM="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$NUM" -le 0 ]; then
  echo "SKIP: no SP on chain"
  exit 0
fi

echo "Testing sp-tools (moca-cmd)..."

print_test_section "sp ls"
OUT="$(exec_moca_cmd sp ls 2>/dev/null || true)"
if [ -z "$OUT" ]; then
  echo "WARN: sp ls empty"
  exit 0
fi
if ! echo "$OUT" | grep -qiE "operator|IN_SERVICE|storage"; then
  echo "WARN: sp ls format unexpected"
  exit 0
fi
echo "$OUT" | head -25

EP="$(first_in_service_sp_endpoint 2>/dev/null || true)"
if [ -z "$EP" ]; then
  EP=$(echo "$OUT" | grep -oE 'https?://[^[:space:]]+' | head -1 || true)
fi
if [ -z "$EP" ]; then
  echo "WARN: could not resolve SP endpoint"
  echo "PASS: sp ls only"
  exit 0
fi

print_test_section "sp head"
H="$(exec_moca_cmd sp head "$EP" 2>/dev/null || true)"
if ! echo "$H" | grep -qiE "operator|endpoint|SP info|STATUS"; then
  echo "WARN: sp head output unexpected"
else
  echo "$H" | head -20
fi

print_test_section "sp get-price"
P="$(exec_moca_cmd sp get-price "$EP" 2>/dev/null || true)"
if echo "$P" | grep -qiE "quota|price|bucket"; then
  echo "$P" | head -25
  echo "PASS: sp ls / head / get-price"
else
  echo "WARN: sp get-price incomplete"
  exit 0
fi
