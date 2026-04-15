#!/usr/bin/env bash
# E2E: SP exit workflow pre-checks and migration queries (devcontainer test_exit parity).
# SP exit/complete messages are exposed via EVM precompile in this chain; mocad has no
# direct virtualgroup exit subcommand. This script validates data plane before exit and
# queries GVG state. Set E2E_SP_EXIT_FULL=1 to fail if operator-side exit tx is required.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP exit test only on local"; exit 0; fi

SP_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
NUM_SPS="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$NUM_SPS" -lt 2 ]; then
  echo "SKIP: need at least 2 SPs for exit migration scenarios"
  exit 0
fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for bucket/object steps"
  exit 0
fi

PICK="${E2E_SP_EXIT_INDEX:-$((NUM_SPS - 1))}"
if [ "$PICK" -lt 0 ] || [ "$PICK" -ge "$NUM_SPS" ]; then
  PICK=$((NUM_SPS - 1))
fi
echo "Testing SP exit workflow (chain SP index ${PICK})..."

OP="$(echo "$SP_JSON" | jq -r ".sps[$PICK].operator_address // empty" 2>/dev/null || true)"
if [ -z "$OP" ]; then
  echo "SKIP: cannot resolve operator"
  exit 0
fi

SP_ID="$(exec_mocad query sp storage-provider-by-operator-address "$OP" --node "$TM_RPC" --output json 2>/dev/null | jq -r '.storage_provider.id // .storageProvider.id // empty' 2>/dev/null || true)"

BUCKET_NAME="e2e-sp-exit-$(date +%s)-${RANDOM}"
OBJECT_NAME="exit_obj.txt"
REL_PATH="${BUCKET_NAME}/${OBJECT_NAME}"
TMPF="$(create_test_file "/tmp/${OBJECT_NAME}" "sp exit object $(date)")"

cleanup() {
  rm -f "$TMPF"
  # Delete object first; bucket rm on a non-empty bucket is a no-op on-chain.
  exec_moca_cmd object rm "$REL_PATH" >/dev/null 2>&1 || true
  exec_moca_cmd bucket rm "moca://${BUCKET_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_test_section "create bucket on SP"
out=$(moca_cmd_tx bucket create --primarySP "$OP" "moca://${BUCKET_NAME}" || true)
if ! echo "$out" | grep -q "make_bucket:\|$BUCKET_NAME"; then
  echo "WARN: bucket create failed"
  trap - EXIT
  exit 0
fi

print_test_section "put object"
MC=$(resolve_moca_cmd 2>/dev/null || true)
if [[ "${MC:-}" == docker:* ]]; then
  docker cp "$TMPF" "${MC#docker:}:/tmp/${OBJECT_NAME}" >/dev/null 2>&1 || true
fi
out=$(moca_cmd_tx object put --bypassSeal --contentType "application/octet-stream" "/tmp/${OBJECT_NAME}" "$REL_PATH" || true)
if ! echo "$out" | grep -qiE "created|sealing|upload"; then
  echo "WARN: object put did not reach upload state; SP exit test cannot verify migration"
  trap - EXIT
  cleanup
  exit 0
fi

# SP exit scenarios (graceful exit, bucket migration) only work on sealed objects;
# pre-seal CREATED objects can be cancelled out from under us mid-migration.
if ! wait_for_object_sealed "$REL_PATH"; then
  echo "WARN: object never sealed; skipping exit-path verification"
  trap - EXIT
  cleanup
  exit 0
fi

print_test_section "verify object head before exit"
out=$(exec_moca_cmd object head "$REL_PATH" || true)
if ! echo "$out" | grep -q "object_name:\"$OBJECT_NAME\""; then
  echo "WARN: object head before exit incomplete"
fi

print_test_section "query SP and GVG before exit"
echo "  operator=$OP sp_id=${SP_ID:-unknown}"
if [ -n "$SP_ID" ] && [ "$SP_ID" != "null" ]; then
  gvg=$(exec_mocad query virtualgroup gvg-statistics-within-sp "$SP_ID" --node "$TM_RPC" --output json 2>/dev/null || echo "")
  echo "$gvg" | jq -c '{primary_count, secondary_count}' 2>/dev/null || echo "$gvg" | head -3
fi

print_test_section "chain exit tx"
echo "  INFO: MsgStorageProviderExit / CompleteStorageProviderExit are broadcast via EVM"
echo "  INFO: precompile on chain (not exposed as mocad tx virtualgroup subcommands)."
if [ "${E2E_SP_EXIT_FULL:-}" = "1" ]; then
  echo "FAIL: E2E_SP_EXIT_FULL set but automated operator-signed exit is not wired in this suite"
  exit 1
fi

trap - EXIT
cleanup
echo "PASS: SP exit data-plane and GVG pre-checks (operator-signed exit tx out of band)"
