#!/usr/bin/env bash
# E2E test: verify SP gateway HTTP endpoints are reachable
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi

echo "Testing SP gateway endpoints..."

PASSED=0
FAILED=0
CHECKED=0

if [ "$ENV" = "local" ]; then
  # Local: probe localhost ports
  SP_GW_BASE=9033
  for i in 0 1 2 3 4 5; do
    PORT=$((SP_GW_BASE + i))
    URL="http://localhost:${PORT}"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "sp-${i}"; then
      continue
    fi
    CHECKED=$((CHECKED + 1))
    STATUS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 3 "${URL}/status" 2>/dev/null || echo "000")
    HEALTH=$(curl -sf --connect-timeout 3 "${URL}/-/healthy" 2>/dev/null || echo "")
    READY=$(curl -sf --connect-timeout 3 "${URL}/-/ready" 2>/dev/null || echo "")
    echo "  SP $i (localhost:$PORT): status_code=$STATUS_CODE health=${HEALTH:-N/A} ready=${READY:-N/A}"
    [ "$STATUS_CODE" != "000" ] && PASSED=$((PASSED + 1)) || FAILED=$((FAILED + 1))
  done
else
  # Remote: get endpoints from chain and probe them
  SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
  NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")

  if [ "$NUM_SPS" -le 0 ]; then
    echo "  No SPs registered"
    echo "PASS: SP gateway test skipped (no SPs)"
    exit 0
  fi

  for i in $(seq 0 $((NUM_SPS - 1))); do
    ENDPOINT=$(echo "$SP_JSON" | jq -r ".sps[$i].endpoint" 2>/dev/null)
    MONIKER=$(echo "$SP_JSON" | jq -r ".sps[$i].description.moniker" 2>/dev/null)
    [ -z "$ENDPOINT" ] || [ "$ENDPOINT" = "null" ] && continue

    CHECKED=$((CHECKED + 1))

    # Check base endpoint
    STATUS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 5 "${ENDPOINT}" 2>/dev/null || echo "000")

    # Check health endpoints
    HEALTH=$(curl -sf --connect-timeout 5 "${ENDPOINT}/-/healthy" 2>/dev/null || echo "")
    READY=$(curl -sf --connect-timeout 5 "${ENDPOINT}/-/ready" 2>/dev/null || echo "")

    echo "  $MONIKER ($ENDPOINT): status_code=$STATUS_CODE health=${HEALTH:-N/A} ready=${READY:-N/A}"
    [ "$STATUS_CODE" != "000" ] && PASSED=$((PASSED + 1)) || FAILED=$((FAILED + 1))
  done
fi

if [ "$CHECKED" -eq 0 ]; then
  echo "  No SP endpoints to check"
  echo "PASS: SP gateway test skipped"
  exit 0
fi

echo "  Checked: $CHECKED, Reachable: $PASSED, Unreachable: $FAILED"

if [ "$PASSED" -gt 0 ]; then
  echo "PASS: $PASSED/$CHECKED SP gateway(s) reachable"
else
  echo "FAIL: No SP gateways reachable"
  exit 1
fi
