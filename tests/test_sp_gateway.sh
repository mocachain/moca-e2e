#!/usr/bin/env bash
# E2E test: verify SP gateway HTTP endpoints are reachable
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi

echo "Testing SP gateway endpoints..."

PASSED=0
FAILED=0
CHECKED=0

if [ "$ENV" = "local" ]; then
  # Local: probe every sp-N container the stack defines (docker ps -a, so a
  # stopped SP fails instead of shrinking the denominator). curl -w prints 000
  # itself on connect failure, so a ||-appended fallback would yield "000000"
  # and count dead gateways as reachable. Health/ready live on the probe
  # server (container port 9402, host SP_PROBE_BASE+i), not the gater; both
  # return empty bodies, so assert HTTP codes. Bases match topology defaults.
  SP_GW_BASE=9033
  SP_PROBE_BASE=9502
  ALL_SPS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$' | sort -t- -k2 -n)
  for name in $ALL_SPS; do
    i=${name#sp-}
    PORT=$((SP_GW_BASE + i))
    PROBE=$((SP_PROBE_BASE + i))
    CHECKED=$((CHECKED + 1))
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      echo "  SP $i (localhost:$PORT): container not running"
      FAILED=$((FAILED + 1))
      continue
    fi
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:${PORT}/status" 2>/dev/null || true)
    STATUS_CODE="${STATUS_CODE:-000}"
    HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:${PROBE}/-/healthy" 2>/dev/null || true)
    HEALTH_CODE="${HEALTH_CODE:-000}"
    READY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:${PROBE}/-/ready" 2>/dev/null || true)
    READY_CODE="${READY_CODE:-000}"
    echo "  SP $i (gw localhost:$PORT probe localhost:$PROBE): status_code=$STATUS_CODE healthy=$HEALTH_CODE ready=$READY_CODE"
    # Unauthenticated /status must be rejected: 400 (unsigned request) or 401
    # (not in StatusAllowedAccounts). 200 means the endpoint is serving anyone
    # again; 000/5xx means the gater is down.
    if { [ "$STATUS_CODE" = "400" ] || [ "$STATUS_CODE" = "401" ]; } && [ "$HEALTH_CODE" = "200" ] && [ "$READY_CODE" = "200" ]; then
      PASSED=$((PASSED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  done
else
  # Remote: get endpoints from chain and probe them
  SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
  NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")

  if [ "$NUM_SPS" -le 0 ]; then
    echo "FAIL: no SPs registered on chain"
    exit 1
  fi

  for i in $(seq 0 $((NUM_SPS - 1))); do
    ENDPOINT=$(echo "$SP_JSON" | jq -r ".sps[$i].endpoint" 2>/dev/null)
    MONIKER=$(echo "$SP_JSON" | jq -r ".sps[$i].description.moniker" 2>/dev/null)
    [ -z "$ENDPOINT" ] || [ "$ENDPOINT" = "null" ] && continue

    CHECKED=$((CHECKED + 1))

    # Check base endpoint
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${ENDPOINT}" 2>/dev/null || true)
    STATUS_CODE="${STATUS_CODE:-000}"

    # Check health endpoints
    HEALTH=$(curl -sf --connect-timeout 5 "${ENDPOINT}/-/healthy" 2>/dev/null || echo "")
    READY=$(curl -sf --connect-timeout 5 "${ENDPOINT}/-/ready" 2>/dev/null || echo "")

    echo "  $MONIKER ($ENDPOINT): status_code=$STATUS_CODE health=${HEALTH:-N/A} ready=${READY:-N/A}"
    [ "$STATUS_CODE" != "000" ] && PASSED=$((PASSED + 1)) || FAILED=$((FAILED + 1))
  done
fi

if [ "$CHECKED" -eq 0 ]; then
  echo "FAIL: no SP endpoints to check"
  exit 1
fi

echo "  Checked: $CHECKED, Reachable: $PASSED, Unreachable: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  echo "FAIL: $FAILED/$CHECKED SP gateway(s) unreachable"
  exit 1
fi
echo "PASS: $PASSED/$CHECKED SP gateway(s) reachable"
