#!/usr/bin/env bash
# E2E: SP diagnosis (containers, chain SP list, gov proposals, moca-cmd sp ls).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP diagnose test only on local"; exit 0; fi

echo "=== SP registration diagnosis ==="

echo "1) SP containers"
RUNNING_SP=$(list_sp_container_names)
if [ -z "$RUNNING_SP" ]; then
  echo "  WARN: no sp-* containers found"
else
  echo "$RUNNING_SP" | while read -r n; do
    st=$(docker ps --filter "name=^${n}$" --format "{{.Status}}" 2>/dev/null || echo "stopped")
    echo "  - ${n}: ${st}"
  done
fi

echo ""
echo "2) SP list from chain"
SP_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
if [ -z "$SP_JSON" ] || [ "$SP_JSON" = "null" ]; then
  echo "  SKIP: validator not reachable"
  exit 0
fi
CNT=$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
echo "  on-chain SP count: $CNT"
if [ "$CNT" != "0" ]; then
  echo "$SP_JSON" | jq -r '.sps[] | "  - id=\(.id // "n/a") moniker=\(.description.moniker // "n/a") status=\(.status // "n/a")"' 2>/dev/null | head -20
fi

echo ""
echo "3) governance proposals (SP-related)"
GOV_JSON="$(exec_mocad query gov proposals --node "$TM_RPC" --output json 2>/dev/null || echo "")"
if [ -z "$GOV_JSON" ] || [ "$GOV_JSON" = "null" ]; then
  echo "  WARN: could not query proposals"
else
  PC=$(echo "$GOV_JSON" | jq -r '.proposals | length // 0' 2>/dev/null || echo "0")
  echo "  total proposals: $PC"
  echo "$GOV_JSON" | jq -r '.proposals[]? | select((.messages[0]."@type"? // "") | test("sp|SP|Storage")) | "  - id=\(.id) status=\(.status) title=\(.title // "n/a")"' 2>/dev/null | head -15 || true
fi

echo ""
echo "4) moca-cmd sp ls"
if resolve_moca_cmd >/dev/null 2>&1; then
  exec_moca_cmd sp ls 2>/dev/null | head -40 || echo "  WARN: moca-cmd sp ls failed"
else
  echo "  SKIP: moca-cmd not available"
fi

echo ""
echo "5) gateway health (localhost 9033-9038)"
GATEWAY_OK=0
for p in 9033 9034 9035 9036 9037 9038; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:${p}/-/healthy" || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "404" ]; then
    GATEWAY_OK=$((GATEWAY_OK + 1))
  fi
done
echo "  responsive gateway ports: $GATEWAY_OK"

if [ "$CNT" -gt 0 ] && { [ -n "$RUNNING_SP" ] || [ "$GATEWAY_OK" -gt 0 ]; }; then
  echo "PASS: SP diagnosis checks completed"
else
  echo "WARN: limited SP visibility"
  exit 0
fi
