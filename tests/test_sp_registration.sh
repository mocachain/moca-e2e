#!/usr/bin/env bash
# E2E test: verify storage providers are registered and in service.
# Local topology: every SP is IN_SERVICE or exiting and at most the two sp-exit targets are out of
# service; a live network needs one SP serving (other statuses warn).
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi

echo "Testing SP registration..."

# Query storage providers from chain
SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")

echo "  Registered SPs on chain: $NUM_SPS"

if [ "$NUM_SPS" -le 0 ]; then
  echo "  FAIL: no SPs registered on chain"
  exit 1
fi

# Check each SP's status
IN_SERVICE=0
EXITING=0
FAILED=0
for i in $(seq 0 $((NUM_SPS - 1))); do
  SP_ADDR=$(echo "$SP_JSON" | jq -r ".sps[$i].operator_address" 2>/dev/null)
  SP_STATUS=$(echo "$SP_JSON" | jq -r ".sps[$i].status" 2>/dev/null)
  SP_ENDPOINT=$(echo "$SP_JSON" | jq -r ".sps[$i].endpoint" 2>/dev/null)

  echo "  SP $i: addr=$SP_ADDR status=$SP_STATUS endpoint=$SP_ENDPOINT"

  if [ -z "$SP_ADDR" ] || [ "$SP_ADDR" = "null" ] || [ -z "$SP_ENDPOINT" ] || [ "$SP_ENDPOINT" = "null" ]; then
    echo "    FAIL: SP $i has no operator address or endpoint"
    FAILED=$((FAILED + 1))
  fi

  case "$SP_STATUS" in
    STATUS_IN_SERVICE | 0) IN_SERVICE=$((IN_SERVICE + 1)) ;;
    STATUS_GRACEFUL_EXITING | STATUS_FORCED_EXITING)
      EXITING=$((EXITING + 1))
      echo "    NOTE: SP $i is exiting (status: $SP_STATUS)"
      ;;
    *)
      if [ "$ENV" = "local" ]; then
        echo "    FAIL: SP $i is neither in service nor exiting (status: $SP_STATUS)"
        FAILED=$((FAILED + 1))
      else
        echo "    WARN: SP $i not in service (status: $SP_STATUS)"
      fi
      ;;
  esac
done

# Local: each sp-N container is an SP and only the two sp-exit tests take one out of service.
MIN_IN_SERVICE=1
if [ "$ENV" = "local" ]; then
  SP_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ec '^sp-[0-9]+$' || true)
  if [ "${SP_CONTAINERS:-0}" -gt 2 ]; then
    MIN_IN_SERVICE=$((SP_CONTAINERS - 2))
  fi
fi
echo "  In service: $IN_SERVICE, exiting: $EXITING (need >= $MIN_IN_SERVICE in service)"
if [ "$IN_SERVICE" -lt "$MIN_IN_SERVICE" ]; then
  echo "  FAIL: only $IN_SERVICE storage provider(s) in service, expected at least $MIN_IN_SERVICE"
  FAILED=$((FAILED + 1))
fi
if [ "$FAILED" -gt 0 ]; then
  echo "  FAIL: SP registration checks reported $FAILED failure(s)"
  exit 1
fi

# Query SP params
SP_PARAMS=$(exec_mocad query sp params --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
DEPOSIT_DENOM=$(echo "$SP_PARAMS" | jq -r '.params.deposit_denom // empty' 2>/dev/null)
echo "  SP deposit denom: ${DEPOSIT_DENOM:-unknown}"

echo "PASS: $NUM_SPS storage providers registered"
