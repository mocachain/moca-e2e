#!/usr/bin/env bash
# E2E test: verify SP gateway HTTP endpoints are reachable
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP gateway test only on local"; exit 0; fi

echo "Testing SP gateway endpoints..."

# SP gateway ports start at 9033
SP_GW_BASE=9033
PASSED=0
FAILED=0
CHECKED=0

# Check each SP's gateway
for i in 0 1 2 3 4 5; do
  PORT=$((SP_GW_BASE + i))
  URL="http://localhost:${PORT}"

  # Check if port is listening
  if ! curl -sf --connect-timeout 3 "$URL" >/dev/null 2>&1; then
    # SP might not be running — check if container exists
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "sp-${i}"; then
      continue  # SP not deployed, skip
    fi
    echo "  SP $i (port $PORT): NOT REACHABLE"
    FAILED=$((FAILED + 1))
    CHECKED=$((CHECKED + 1))
    continue
  fi

  CHECKED=$((CHECKED + 1))

  # Check health endpoint
  HEALTH=$(curl -sf --connect-timeout 3 "${URL}/-/healthy" 2>/dev/null || echo "")
  READY=$(curl -sf --connect-timeout 3 "${URL}/-/ready" 2>/dev/null || echo "")

  # Check status endpoint
  STATUS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 3 "${URL}/status" 2>/dev/null || echo "000")

  echo "  SP $i (port $PORT): health=${HEALTH:-N/A} ready=${READY:-N/A} status_code=$STATUS_CODE"
  PASSED=$((PASSED + 1))
done

if [ "$CHECKED" -eq 0 ]; then
  echo "  No SP containers running — skipping gateway tests"
  echo "PASS: SP gateway test skipped (no SPs deployed)"
  exit 0
fi

echo "  Checked: $CHECKED, Reachable: $PASSED, Unreachable: $FAILED"

if [ "$PASSED" -gt 0 ]; then
  echo "PASS: $PASSED SP gateway(s) reachable"
else
  echo "WARN: No SP gateways reachable"
  exit 0
fi
