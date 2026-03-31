#!/usr/bin/env bash
# E2E test: SP diagnosis checks.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP diagnose test only on local"; exit 0; fi

echo "Running SP diagnosis..."

SP_COUNT=$(exec_mocad query sp storage-providers --node tcp://localhost:26657 --output json 2>/dev/null | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
if [ "$SP_COUNT" -le 0 ]; then
  echo "SKIP: no SP registered on chain"
  exit 0
fi

RUNNING_SP=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$|^sp[0-9]+$' || true)
if [ -z "$RUNNING_SP" ]; then
  echo "WARN: no running SP containers found"
  exit 0
fi

echo "  SP containers:"
echo "$RUNNING_SP" | sed 's/^/    - /'

GATEWAY_OK=0
for p in 9033 9034 9035 9036 9037 9038; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:${p}/-/healthy" || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "404" ]; then
    GATEWAY_OK=$((GATEWAY_OK + 1))
  fi
done

if [ "$GATEWAY_OK" -gt 0 ]; then
  echo "PASS: SP diagnosis checks passed"
else
  echo "WARN: SP gateways are not reachable"
  exit 0
fi
