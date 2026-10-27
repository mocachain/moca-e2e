#!/usr/bin/env bash
# E2E: verify deployed SPs (devcontainer test_join verification parity, no create-sp): chain
# registration and status, health probes of every SP container, and the moca-cmd sp queries.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/moca_cmd.sh
source "$SCRIPT_DIR/libs/moca_cmd.sh"
# shellcheck source=libs/sp.sh
source "$SCRIPT_DIR/libs/sp.sh"

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

# Every SP is IN_SERVICE or exiting; locally at most the two sp-exit targets are out of service.
FAIL=0
IN_SERVICE=0
for i in $(seq 0 $((CHAIN_SP_COUNT - 1))); do
  OP=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].operator_address // empty" 2>/dev/null)
  ST=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].status // empty" 2>/dev/null)
  EP=$(echo "$CHAIN_JSON" | jq -r ".sps[$i].endpoint // empty" 2>/dev/null)
  echo "  SP[$i] operator=$OP status=$ST"
  if [ -z "$OP" ]; then
    echo "    FAIL: empty operator"
    FAIL=$((FAIL + 1))
  fi
  if [ -z "$EP" ]; then
    echo "    FAIL: empty endpoint"
    FAIL=$((FAIL + 1))
  fi
  case "$ST" in
    STATUS_IN_SERVICE | 0) IN_SERVICE=$((IN_SERVICE + 1)) ;;
    STATUS_GRACEFUL_EXITING | STATUS_FORCED_EXITING) echo "    NOTE: SP is exiting: $ST" ;;
    *)
      echo "    FAIL: status neither IN_SERVICE nor exiting: $ST"
      FAIL=$((FAIL + 1))
      ;;
  esac

  Q=$(exec_mocad query sp storage-provider-by-operator-address "$OP" --node "$TM_RPC" --output json 2>/dev/null || echo "")
  Q_OP=$(echo "$Q" | jq -r '.storage_provider.operator_address // .storageProvider.operator_address // empty' 2>/dev/null || true)
  if [ -n "$OP" ] && [ "$(echo "$Q_OP" | tr '[:upper:]' '[:lower:]')" = "$(echo "$OP" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "    OK: per-operator query works"
  else
    echo "    FAIL: storage-provider-by-operator-address returned operator '${Q_OP:-<none>}'"
    FAIL=$((FAIL + 1))
  fi
done

VC="${VALIDATOR_CONTAINER:-validator-0}"
SP_CONTAINERS="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$' | sort -V || true)"
RUNNING_SPS="$(list_sp_container_names)"
echo "  docker SP containers:"
for spn in $RUNNING_SPS; do
  echo "    - $spn"
done

MIN_IN_SERVICE=1
SP_CONTAINER_COUNT="$(printf '%s\n' "$SP_CONTAINERS" | grep -c . || true)"
if [ "${SP_CONTAINER_COUNT:-0}" -gt 2 ]; then
  MIN_IN_SERVICE=$((SP_CONTAINER_COUNT - 2))
fi
echo "  in service: $IN_SERVICE (need >= $MIN_IN_SERVICE)"
if [ "$IN_SERVICE" -lt "$MIN_IN_SERVICE" ]; then
  echo "    FAIL: only $IN_SERVICE storage provider(s) in service, expected at least $MIN_IN_SERVICE"
  FAIL=$((FAIL + 1))
fi

# Health/readiness live on the probe server (container port 9402, host 9502+N); the gateway port answers 400 there.
for spn in $SP_CONTAINERS; do
  idx="${spn#sp-}"
  if ! grep -qx "$spn" <<<"$RUNNING_SPS"; then
    echo "  container $spn not running"
    FAIL=$((FAIL + 1))
    continue
  fi
  echo "  container $spn running"
  for probe in healthy ready; do
    hcode=$(docker exec "$VC" curl -s -o /dev/null -w "%{http_code}" -m 3 "http://${spn}:9402/-/${probe}" 2>/dev/null || true)
    if [ "$hcode" = "200" ]; then
      echo "    OK: ${probe} via docker network (${spn}:9402) code=$hcode"
    else
      echo "    FAIL: ${probe} via docker network (${spn}:9402) code=${hcode:-000}"
      FAIL=$((FAIL + 1))
    fi
  done
  port=$((9502 + idx))
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:${port}/-/healthy" 2>/dev/null || true)
  if [ "$code" = "200" ]; then
    echo "    OK: localhost:${port}/-/healthy -> $code"
  else
    echo "    FAIL: localhost:${port}/-/healthy -> ${code:-000}"
    FAIL=$((FAIL + 1))
  fi
done

if resolve_moca_cmd >/dev/null 2>&1; then
  OUT="$(exec_moca_cmd sp ls 2>/dev/null || true)"
  MISSING=0
  for op in $(echo "$CHAIN_JSON" | jq -r '.sps[].operator_address' 2>/dev/null); do
    if ! grep -qi "$op" <<<"$OUT"; then
      echo "  FAIL: moca-cmd sp ls does not list $op"
      MISSING=$((MISSING + 1))
    fi
  done
  if [ "$MISSING" -eq 0 ]; then
    echo "  OK: moca-cmd sp ls lists all $CHAIN_SP_COUNT on-chain SPs"
  else
    FAIL=$((FAIL + 1))
  fi

  EP_FIRST=$(first_in_service_sp_endpoint 2>/dev/null || true)
  OP_FIRST=$(first_in_service_sp_operator 2>/dev/null || true)
  if [ -z "$EP_FIRST" ] || [ -z "$OP_FIRST" ]; then
    echo "  FAIL: cannot resolve an IN_SERVICE SP for moca-cmd sp head/get-price"
    FAIL=$((FAIL + 1))
  else
    H="$(exec_moca_cmd sp head "$EP_FIRST" 2>/dev/null || true)"
    if grep -qi "$OP_FIRST" <<<"$H"; then
      echo "  OK: moca-cmd sp head"
    else
      echo "  FAIL: moca-cmd sp head $EP_FIRST does not show operator $OP_FIRST: $(echo "$H" | head -2)"
      FAIL=$((FAIL + 1))
    fi
    P="$(exec_moca_cmd sp get-price "$EP_FIRST" 2>/dev/null || true)"
    if grep -qi "read quota price" <<<"$P" && grep -qi "storage price" <<<"$P" && grep -qi "free quota" <<<"$P"; then
      echo "  OK: moca-cmd sp get-price"
    else
      echo "  FAIL: moca-cmd sp get-price $EP_FIRST is missing a price: $(echo "$P" | head -3)"
      FAIL=$((FAIL + 1))
    fi
  fi
else
  echo "  SKIP: moca-cmd unavailable for sp ls/head/get-price"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: SP join visibility checks passed"
else
  echo "FAIL: SP verification reported $FAIL failure(s)"
  exit 1
fi
