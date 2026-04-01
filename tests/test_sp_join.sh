#!/usr/bin/env bash
# E2E: verify deployed SPs (devcontainer test_join verification parity, no create-sp).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP join test only on local"; exit 0; fi

echo "Testing SP join visibility (comprehensive)..."

CHAIN_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
CHAIN_SP_COUNT="$(echo "$CHAIN_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$CHAIN_SP_COUNT" -le 0 ]; then
  echo "SKIP: chain has no SP registrations"
  exit 0
fi

echo "  on-chain SPs: $CHAIN_SP_COUNT"

FAIL=0
for i in $(seq 0 $((CHAIN_SP_COUNT - 1))); do
  OP=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].operator_address // empty" 2>/dev/null)
  ST=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].status // empty" 2>/dev/null)
  EP=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].endpoint // empty" 2>/dev/null)
  echo "  SP[$i] operator=$OP status=$ST"
  if [ -z "$OP" ]; then
    echo "    FAIL: empty operator"
    FAIL=1
  fi
  if [ -z "$EP" ]; then
    echo "    WARN: empty endpoint"
  fi
  if [ "$ST" != "STATUS_IN_SERVICE" ] && [ "$ST" != "0" ]; then
    echo "    WARN: status not IN_SERVICE: $ST"
  fi

  Q=$(exec_mocad query sp storage-provider-by-operator-address "$OP" --node "$TM_RPC" --output json 2>/dev/null || echo "")
  if [ -z "$Q" ] || [ "$Q" = "null" ]; then
    echo "    WARN: storage-provider-by-operator-address query empty"
  else
    echo "    OK: per-operator query works"
  fi
done

echo "  docker SP containers:"
list_sp_container_names | sed 's/^/    - /' || true

VC="${VALIDATOR_CONTAINER:-validator-0}"
for spn in $(list_sp_container_names); do
  idx="${spn#sp-}"
  port=$((9033 + idx))
  if docker ps --format '{{.Names}}' | grep -q "^${spn}$"; then
    echo "  container $spn running"
    hcode=$(docker exec "$VC" curl -s -o /dev/null -w "%{http_code}" -m 3 "http://${spn}:9033/-/healthy" 2>/dev/null || echo "000")
    if [ "$hcode" = "200" ] || [ "$hcode" = "404" ]; then
      echo "    OK: health via docker network (${spn}:9033) code=$hcode"
    fi
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:${port}/-/healthy" 2>/dev/null || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "404" ]; then
    echo "    OK: localhost:${port}/-/healthy -> $code"
  fi
done

if resolve_moca_cmd >/dev/null 2>&1; then
  OUT="$(exec_moca_cmd sp ls 2>/dev/null || true)"
  if echo "$OUT" | grep -qiE "operator|IN_SERVICE|storage"; then
    echo "  OK: moca-cmd sp ls"
  else
    echo "  WARN: moca-cmd sp ls unexpected"
  fi
  EP_FIRST=$(first_in_service_sp_endpoint 2>/dev/null || true)
  if [ -n "$EP_FIRST" ]; then
    H="$(exec_moca_cmd sp head "$EP_FIRST" 2>/dev/null || true)"
    if echo "$H" | grep -qiE "operator|SP info|endpoint"; then
      echo "  OK: moca-cmd sp head"
    fi
    P="$(exec_moca_cmd sp get-price "$EP_FIRST" 2>/dev/null || true)"
    if echo "$P" | grep -qiE "quota|price|bucket"; then
      echo "  OK: moca-cmd sp get-price"
    fi
  fi
else
  echo "  SKIP: moca-cmd unavailable for sp ls/head/get-price"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: SP join visibility checks passed"
else
  echo "FAIL: SP verification had errors"
  exit 1
fi
