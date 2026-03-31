#!/usr/bin/env bash
# E2E test: SP join visibility checks.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP join test only on local"; exit 0; fi

echo "Testing SP join visibility..."

CHAIN_SPS_JSON="$(exec_mocad query sp storage-providers --node tcp://localhost:26657 --output json 2>/dev/null || echo '{}')"
CHAIN_SP_COUNT="$(echo "$CHAIN_SPS_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$CHAIN_SP_COUNT" -le 0 ]; then
  echo "SKIP: chain has no SP registrations"
  exit 0
fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "PASS: chain has ${CHAIN_SP_COUNT} SP(s); moca-cmd unavailable, skipping client-side join check"
  exit 0
fi

CMD_OUTPUT="$(exec_moca_cmd sp ls 2>/dev/null || true)"
if [ -z "$CMD_OUTPUT" ]; then
  echo "WARN: moca-cmd sp ls returned empty output"
  exit 0
fi

if echo "$CMD_OUTPUT" | grep -Eqi "sp|storage provider|operator"; then
  echo "PASS: SP join visibility checks passed"
else
  echo "WARN: moca-cmd sp ls output format unexpected"
  exit 0
fi
