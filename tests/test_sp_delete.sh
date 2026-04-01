#!/usr/bin/env bash
# E2E: SP governance delete pre-checks (devcontainer test-delete-sp parity).
# Destructive delete requires localnet/delete-sp-governance.sh and operator material.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP delete test only on local"; exit 0; fi

SP_JSON="$(exec_mocad query sp storage-providers --node tcp://localhost:26657 --output json 2>/dev/null || echo '{}')"
NUM_SPS="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$NUM_SPS" -lt 2 ]; then
  echo "SKIP: need at least 2 SPs before testing deletion scenarios"
  exit 0
fi

TARGET_INDEX="${E2E_SP_DELETE_INDEX:-$((NUM_SPS - 1))}"
OP="$(echo "$SP_JSON" | jq -r ".sps[$TARGET_INDEX].operator_address // empty" 2>/dev/null || true)"
if [ -z "$OP" ]; then
  echo "SKIP: cannot resolve target operator"
  exit 0
fi

echo "Testing SP governance delete pre-checks (operator=$OP)..."

PRE="$(exec_mocad query sp storage-provider-by-operator-address "$OP" --node tcp://localhost:26657 --output json 2>/dev/null || echo "")"
if [ -z "$PRE" ] || [ "$PRE" = "null" ]; then
  echo "FAIL: SP not found on chain"
  exit 1
fi
echo "  SP present on chain before delete simulation"

GOV="$(exec_mocad query gov proposals --node tcp://localhost:26657 --output json 2>/dev/null || echo "")"
GNUM=$(echo "$GOV" | jq -r '.proposals | length' 2>/dev/null || echo "0")
echo "  governance proposals count: $GNUM"

if [ "${E2E_RUN_SP_DELETE_TX:-}" = "1" ]; then
  echo "FAIL: E2E_RUN_SP_DELETE_TX=1 requires bundled delete-sp-governance workflow (not in moca-e2e)"
  exit 1
fi

echo "PASS: SP delete governance pre-checks (no destructive tx run)"
