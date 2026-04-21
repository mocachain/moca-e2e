#!/usr/bin/env bash
# E2E: reproduce sg-sp0 style graceful-exit query path and assert scheduler is active.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP exit scheduler test only on local"; exit 0; fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for SP exit scheduler test"
  exit 0
fi

SP_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
NUM_SPS="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: need at least 3 SPs to exercise graceful exit"
  exit 0
fi

PICK="${E2E_SP_EXIT_INDEX:-$((NUM_SPS - 1))}"
if [ "$PICK" -lt 0 ] || [ "$PICK" -ge "$NUM_SPS" ]; then
  PICK=$((NUM_SPS - 1))
fi

TARGET_SP="$(sp_container_name_for_index "$PICK")"
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${TARGET_SP}$"; then
  echo "SKIP: target SP container ${TARGET_SP} is not running"
  exit 0
fi

OPERATOR="$(docker exec "$TARGET_SP" sh -lc "grep '^SpOperatorAddress' /root/.moca-sp/config.toml | sed -E \"s/.*'([^']+)'.*/\\1/\"" 2>/dev/null || true)"
if [ -z "$OPERATOR" ]; then
  echo "SKIP: cannot resolve operator for target SP ${TARGET_SP}"
  exit 0
fi
STATUS="$(get_sp_status_by_operator "$OPERATOR")"
if [ "$STATUS" != "STATUS_IN_SERVICE" ] && [ "$STATUS" != "0" ]; then
  echo "SKIP: target SP ${TARGET_SP} is not IN_SERVICE (status=${STATUS:-unknown})"
  exit 0
fi

SP_INFO="$(exec_mocad query sp storage-provider-by-operator-address "$OPERATOR" --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
SP_ID="$(echo "$SP_INFO" | jq -r '.storage_provider.id // .storageProvider.id // empty' 2>/dev/null || true)"

BUCKET_NAME="e2e-sp-exit-scheduler-$(date +%s)-${RANDOM}"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="scheduler_object.txt"
OBJECT_REL="${BUCKET_NAME}/${OBJECT_NAME}"
TEST_FILE="$(create_test_file "/tmp/${OBJECT_NAME}" "sp exit scheduler regression $(date)")"

cleanup() {
  rm -f "$TEST_FILE"
  exec_moca_cmd object rm "$OBJECT_REL" >/dev/null 2>&1 || true
  exec_moca_cmd bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing SP exit scheduler on ${TARGET_SP} (sp_id=${SP_ID:-unknown}, operator=${OPERATOR})..."

print_test_section "create bucket on target SP"
bucket_out="$(moca_cmd_tx bucket create --primarySP "$OPERATOR" "$BUCKET_URL" || true)"
if ! echo "$bucket_out" | grep -q "$BUCKET_NAME"; then
  echo "$bucket_out"
  echo "FAIL: bucket create did not succeed on target SP"
  exit 1
fi

print_test_section "put and seal object"
put_out="$(moca_cmd_tx object put --contentType "application/octet-stream" "$TEST_FILE" "$OBJECT_REL" || true)"
if ! echo "$put_out" | grep -qiE "created|sealing|upload"; then
  echo "$put_out"
  echo "FAIL: object put did not start successfully"
  exit 1
fi
if ! wait_for_object_sealed "$OBJECT_REL" 180; then
  echo "FAIL: object never reached OBJECT_STATUS_SEALED"
  exit 1
fi

if [ -n "$SP_ID" ] && [ "$SP_ID" != "null" ]; then
  print_test_section "query GVG statistics before exit"
  exec_mocad query virtualgroup gvg-statistics-within-sp "$SP_ID" \
    --node "$TM_RPC" --output json 2>/dev/null | jq -c '.gvg_statistics // .' 2>/dev/null || true
fi

print_test_section "send sp.exit from target SP container"
sp_exit_out="$(exec_sp_cmd "$TARGET_SP" -c /root/.moca-sp/config.toml sp.exit --operatorAddress "$OPERATOR" 2>&1 || true)"
if ! echo "$sp_exit_out" | grep -q "send sp exit txn successfully"; then
  echo "$sp_exit_out"
  echo "FAIL: moca-sp sp.exit did not return success"
  exit 1
fi
echo "$sp_exit_out"

print_test_section "wait for chain status to become graceful exiting"
if ! wait_for_sp_status "$OPERATOR" "STATUS_GRACEFUL_EXITING" 180; then
  echo "FAIL: target SP never entered STATUS_GRACEFUL_EXITING"
  exit 1
fi
echo "  OK: chain status is STATUS_GRACEFUL_EXITING"

print_test_section "query sp exit plan from same SP"
query_out="$(exec_sp_cmd "$TARGET_SP" query.sp.exit -c /root/.moca-sp/config.toml --endpoint localhost:9333 2>&1 || true)"
echo "$query_out"

if echo "$query_out" | grep -q "spExitScheduler not exit"; then
  echo "FAIL: reproduced the sg-sp0 bug; scheduler was not started"
  exit 1
fi

if ! echo "$query_out" | jq -e '.self_sp_id >= 0' >/dev/null 2>&1; then
  echo "FAIL: query.sp.exit did not return the expected JSON payload"
  exit 1
fi

trap - EXIT
cleanup
echo "PASS: SP exit scheduler query works after entering graceful exit"
