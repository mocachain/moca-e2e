#!/usr/bin/env bash
# E2E: complete SP graceful-exit workflow.
# Covers:
# - create bucket/object on the target SP
# - query pre-exit SP/GVG state
# - send sp.exit from the target SP container
# - assert sp exit scheduler is active
# - verify bucket/object remain available after exit
# - verify bucket primary SP changes away from the exited SP
# - verify chain SP list reflects graceful exiting
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP exit test only on local"; exit 0; fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for complete SP exit test"
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
if [ -z "$SP_ID" ] || [ "$SP_ID" = "null" ]; then
  echo "SKIP: cannot resolve on-chain SP ID for ${TARGET_SP}"
  exit 0
fi

BUCKET_NAME="e2e-sp-exit-$(date +%s)-${RANDOM}"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="exit_obj.txt"
OBJECT_REL="${BUCKET_NAME}/${OBJECT_NAME}"
HOST_TEST_FILE="$(create_test_file "/tmp/${OBJECT_NAME}" "sp exit object $(date)")"
CONTAINER_TEST_FILE="/tmp/${OBJECT_NAME}"

cleanup() {
  rm -f "$HOST_TEST_FILE"
  exec_moca_cmd object rm "$OBJECT_REL" >/dev/null 2>&1 || true
  exec_moca_cmd bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

gvg_primary_sp_id_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].primary_sp_id // empty' 2>/dev/null || true
}

wait_for_gvg_primary_sp_change() {
  local family_id="${1:?family id required}"
  local old_sp_id="${2:?old primary sp id required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_primary_sp_id_by_family "$family_id")"
    if [ -n "$current" ] && [ "$current" != "$old_sp_id" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_primary_sp_change: timeout after ${timeout}s; last primary SP ID: ${current:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_object_visible() {
  local bucket_url="${1:?bucket url required}"
  local object_name="${2:?object name required}"
  local timeout="${3:-120}"
  local deadline now out

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    out="$(exec_moca_cmd object ls "$bucket_url" 2>/dev/null || true)"
    if echo "$out" | grep -q "$object_name"; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_object_visible: timeout after ${timeout}s" >&2
      return 1
    fi
    sleep 3
  done
}

echo "Testing complete SP exit on ${TARGET_SP} (sp_id=${SP_ID}, operator=${OPERATOR})..."

print_test_section "create bucket on target SP"
bucket_out="$(moca_cmd_tx bucket create --primarySP "$OPERATOR" "$BUCKET_URL" || true)"
if ! echo "$bucket_out" | grep -q "$BUCKET_NAME"; then
  echo "$bucket_out"
  echo "FAIL: bucket create did not succeed on target SP"
  exit 1
fi

BEFORE_BUCKET_HEAD="$(exec_moca_cmd bucket head "$BUCKET_URL" 2>&1 || true)"
if ! echo "$BEFORE_BUCKET_HEAD" | grep -q "bucket_name:\"$BUCKET_NAME\""; then
  echo "$BEFORE_BUCKET_HEAD"
  echo "FAIL: bucket head did not return the created bucket"
  exit 1
fi

BUCKET_FAMILY_ID="$(printf '%s\n' "$BEFORE_BUCKET_HEAD" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
BEFORE_PRIMARY_SP_ID="$(printf '%s\n' "$BEFORE_BUCKET_HEAD" | awk -F': ' '/^primary SP ID:/ {print $2; exit}')"
if [ -z "$BUCKET_FAMILY_ID" ] || [ -z "$BEFORE_PRIMARY_SP_ID" ]; then
  echo "$BEFORE_BUCKET_HEAD"
  echo "FAIL: could not resolve bucket family ID / primary SP ID before exit"
  exit 1
fi
assert_eq "$BEFORE_PRIMARY_SP_ID" "$SP_ID" "bucket primary SP ID matches target SP before exit"

print_test_section "put and seal object on target SP bucket"
MC="$(resolve_moca_cmd 2>/dev/null || true)"
if [[ "${MC:-}" == docker:* ]]; then
  docker cp "$HOST_TEST_FILE" "${MC#docker:}:${CONTAINER_TEST_FILE}" >/dev/null 2>&1 || true
fi
put_out="$(moca_cmd_tx object put --contentType "application/octet-stream" "$CONTAINER_TEST_FILE" "$OBJECT_REL" || true)"
if ! echo "$put_out" | grep -qiE "created|sealing|upload"; then
  echo "$put_out"
  echo "FAIL: object put did not start successfully"
  exit 1
fi
if ! wait_for_object_sealed "$OBJECT_REL" 180; then
  echo "FAIL: object never reached OBJECT_STATUS_SEALED"
  exit 1
fi

print_test_section "record pre-exit state"
OBJECT_HEAD_BEFORE="$(exec_moca_cmd object head "$OBJECT_REL" 2>&1 || true)"
if ! echo "$OBJECT_HEAD_BEFORE" | grep -q "object_name:\"$OBJECT_NAME\""; then
  echo "$OBJECT_HEAD_BEFORE"
  echo "FAIL: object head before exit did not return the test object"
  exit 1
fi
GVG_BEFORE="$(exec_mocad query virtualgroup global-virtual-group-by-family-id "$BUCKET_FAMILY_ID" --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
SECONDARY_SP_IDS_BEFORE="$(printf '%s\n' "$GVG_BEFORE" | jq -c '.global_virtual_groups[0].secondary_sp_ids // []' 2>/dev/null || true)"
echo "  gvg_family_id=${BUCKET_FAMILY_ID}"
echo "  primary_sp_id_before=${BEFORE_PRIMARY_SP_ID}"
echo "  secondary_sp_ids_before=${SECONDARY_SP_IDS_BEFORE:-unknown}"

if [ -n "$SP_ID" ] && [ "$SP_ID" != "null" ]; then
  exec_mocad query virtualgroup gvg-statistics-within-sp "$SP_ID" \
    --node "$TM_RPC" --output json 2>/dev/null | jq -c '.gvg_statistics // .' 2>/dev/null || true
fi

print_test_section "query chain SP list before exit"
printf '%s\n' "$SP_JSON" | jq -r '.sps[] | "  id=\(.id) status=\(.status) operator=\(.operator_address)"' 2>/dev/null || true

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

SUCCESSOR_IDS="$(echo "$query_out" | jq -r '[.swap_out_dest[]?.successor_sp_id] | unique | .[]' 2>/dev/null || true)"

print_test_section "verify bucket and object still exist after exit"
NEW_PRIMARY_SP_ID="$(wait_for_gvg_primary_sp_change "$BUCKET_FAMILY_ID" "$BEFORE_PRIMARY_SP_ID" 180)"
assert_ne "$NEW_PRIMARY_SP_ID" "$BEFORE_PRIMARY_SP_ID" "GVG primary SP changed after graceful exit"

BUCKET_HEAD_AFTER="$(exec_moca_cmd bucket head "$BUCKET_URL" 2>&1 || true)"
if ! echo "$BUCKET_HEAD_AFTER" | grep -q "bucket_name:\"$BUCKET_NAME\""; then
  echo "$BUCKET_HEAD_AFTER"
  echo "FAIL: bucket head after exit did not return the bucket"
  exit 1
fi

OBJECT_HEAD_AFTER="$(exec_moca_cmd object head "$OBJECT_REL" 2>&1 || true)"
if ! echo "$OBJECT_HEAD_AFTER" | grep -q "object_name:\"$OBJECT_NAME\""; then
  echo "$OBJECT_HEAD_AFTER"
  echo "FAIL: object head after exit did not return the object"
  exit 1
fi
if ! wait_for_object_visible "$BUCKET_URL" "$OBJECT_NAME" 120; then
  echo "FAIL: object is no longer visible in object ls after exit"
  exit 1
fi
echo "  OK: bucket and object remain accessible after exit"
echo "  OK: GVG primary SP migrated from ${BEFORE_PRIMARY_SP_ID} to ${NEW_PRIMARY_SP_ID}"

if [ -n "$SUCCESSOR_IDS" ]; then
  if ! printf '%s\n' "$SUCCESSOR_IDS" | grep -qx "$NEW_PRIMARY_SP_ID"; then
    echo "  successor_sp_ids from query.sp.exit:"
    printf '%s\n' "$SUCCESSOR_IDS" | sed 's/^/    - /'
    echo "FAIL: bucket migrated to unexpected primary SP ID ${NEW_PRIMARY_SP_ID}"
    exit 1
  fi
  echo "  OK: bucket migrated to successor SP ID ${NEW_PRIMARY_SP_ID}"
fi

print_test_section "verify chain SP list after exit"
SP_JSON_AFTER="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
printf '%s\n' "$SP_JSON_AFTER" | jq -r '.sps[] | "  id=\(.id) status=\(.status) operator=\(.operator_address)"' 2>/dev/null || true

STATUS_AFTER="$(printf '%s\n' "$SP_JSON_AFTER" | jq -r --arg op "$OPERATOR" '.sps[] | select(.operator_address == $op) | .status' 2>/dev/null | head -1)"
assert_eq "$STATUS_AFTER" "STATUS_GRACEFUL_EXITING" "target SP status in chain SP list"

if [ -n "$SUCCESSOR_IDS" ]; then
  while IFS= read -r successor_id; do
    [ -n "$successor_id" ] || continue
    if ! printf '%s\n' "$SP_JSON_AFTER" | jq -e --arg sid "$successor_id" '.sps[] | select((.id|tostring) == $sid)' >/dev/null 2>&1; then
      echo "FAIL: successor SP ID ${successor_id} from query.sp.exit not found in chain SP list"
      exit 1
    fi
  done <<EOF
$SUCCESSOR_IDS
EOF
  echo "  OK: successor SPs from query.sp.exit exist on chain"
fi

trap - EXIT
cleanup
echo "PASS: complete SP graceful exit workflow succeeded"
