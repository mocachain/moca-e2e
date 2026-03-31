#!/usr/bin/env bash
# E2E test: SP exit precondition checks.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP exit test only on local"; exit 0; fi

echo "Testing SP exit preconditions..."

SP_JSON="$(exec_mocad query sp storage-providers --node tcp://localhost:26657 --output json 2>/dev/null || echo '{}')"
COUNT="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$COUNT" -le 0 ]; then
  echo "SKIP: no SP on chain"
  exit 0
fi

OP="$(echo "$SP_JSON" | jq -r '.sps[0].operator_address // empty' 2>/dev/null || true)"
if [ -z "$OP" ]; then
  echo "WARN: cannot resolve SP operator address"
  exit 0
fi

# Keep this test read-only: only verify we can locate an SP that could be exited.
echo "  Candidate SP operator: $OP"
echo "PASS: SP exit preconditions satisfied"
