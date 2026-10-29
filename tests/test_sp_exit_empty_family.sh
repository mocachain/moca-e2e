#!/usr/bin/env bash
# E2E: an SP whose bucket was deleted down to an empty GVG family still completes a graceful exit.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/assertions.sh
source "$SCRIPT_DIR/libs/assertions.sh"
# shellcheck source=libs/moca_cmd.sh
source "$SCRIPT_DIR/libs/moca_cmd.sh"
# shellcheck source=libs/storage.sh
source "$SCRIPT_DIR/libs/storage.sh"
# shellcheck source=libs/sp.sh
source "$SCRIPT_DIR/libs/sp.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP exit test only on local"; exit 0; fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for empty-family exit test"
  exit 0
fi

SP_JSON="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
NUM_SPS="$(echo "$SP_JSON" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: need at least 3 SPs to exercise graceful exit with an empty family"
  exit 0
fi

PICK="$(select_target_sp_index || true)"
if [ -z "$PICK" ]; then
  echo "SKIP: could not find a usable IN_SERVICE target SP for secondary exit coverage"
  exit 0
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
SECONDARY_OBJECT_NAME="secondary_exit_obj.txt"
HOST_TEST_FILE="$(create_test_file "/tmp/${OBJECT_NAME}" "sp exit object $(date)")"
CONTAINER_TEST_FILE="/tmp/${OBJECT_NAME}"
SECONDARY_OBJECT_REL=""

cleanup() {
  rm -f "$HOST_TEST_FILE"
  if [ -n "${SECONDARY_OBJECT_REL:-}" ]; then
    exec_moca_cmd object rm "$SECONDARY_OBJECT_REL" >/dev/null 2>&1 || true
  fi
  if [ -n "${SECONDARY_BUCKET_URL:-}" ]; then
    exec_moca_cmd bucket rm "$SECONDARY_BUCKET_URL" >/dev/null 2>&1 || true
  fi
  exec_moca_cmd object rm "$OBJECT_REL" >/dev/null 2>&1 || true
  exec_moca_cmd bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing graceful exit with an empty family on ${TARGET_SP} (sp_id=${SP_ID}, operator=${OPERATOR})..."

print_test_section "create bucket on target SP"
bucket_out="$(moca_cmd_tx bucket create --primarySP "$OPERATOR" "$BUCKET_URL" || true)"
if ! echo "$bucket_out" | grep -q "$BUCKET_NAME"; then
  echo "$bucket_out"
  echo "FAIL: bucket create did not succeed on target SP"
  exit 1
fi

bucket_head_before="$(exec_moca_cmd bucket head "$BUCKET_URL" 2>&1 || true)"
if ! echo "$bucket_head_before" | grep -q "bucket_name:\"$BUCKET_NAME\""; then
  echo "$bucket_head_before"
  echo "FAIL: bucket head did not return the created bucket"
  exit 1
fi

BUCKET_FAMILY_ID="$(printf '%s\n' "$bucket_head_before" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
BEFORE_PRIMARY_SP_ID="$(printf '%s\n' "$bucket_head_before" | awk -F': ' '/^primary SP ID:/ {print $2; exit}')"
if [ -z "$BUCKET_FAMILY_ID" ] || [ -z "$BEFORE_PRIMARY_SP_ID" ]; then
  echo "$bucket_head_before"
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

print_test_section "create auxiliary bucket where target SP is a secondary"
if ! create_bucket_with_target_as_secondary "$SP_ID" "$SP_JSON"; then
  exit 1
fi
echo "  OK: auxiliary bucket uses target SP ${SP_ID} as secondary"
echo "  auxiliary_bucket=${SECONDARY_BUCKET_URL}"
echo "  auxiliary_family_id=${SECONDARY_BUCKET_FAMILY_ID}"
echo "  auxiliary_secondary_sp_ids=${SECONDARY_BUCKET_SECONDARY_IDS}"

print_test_section "put and seal object on auxiliary bucket"
SECONDARY_OBJECT_REL="${SECONDARY_BUCKET_URL#moca://}/${SECONDARY_OBJECT_NAME}"
secondary_put_out="$(moca_cmd_tx object put --contentType "application/octet-stream" "$CONTAINER_TEST_FILE" "$SECONDARY_OBJECT_REL" || true)"
if ! echo "$secondary_put_out" | grep -qiE "created|sealing|upload"; then
  echo "$secondary_put_out"
  echo "FAIL: auxiliary object put did not start successfully"
  exit 1
fi
if ! wait_for_object_sealed "$SECONDARY_OBJECT_REL" 180; then
  echo "FAIL: auxiliary object never reached OBJECT_STATUS_SEALED"
  exit 1
fi

print_test_section "delete target primary bucket to leave an empty family"
remove_object_out="$(exec_moca_cmd_signed object rm "$OBJECT_REL" || true)"
echo "$remove_object_out" | head -5
wait_for_block 3

remove_bucket_out="$(exec_moca_cmd_signed bucket rm "$BUCKET_URL" || true)"
echo "$remove_bucket_out" | head -5
wait_for_block 3

if ! wait_for_gvg_family_gvg_count "$BUCKET_FAMILY_ID" "1" 180; then
  echo "FAIL: target family did not retain the expected single empty GVG after deleting the primary bucket"
  exit 1
fi
if ! wait_for_gvg_stored_size "$BUCKET_FAMILY_ID" "0" 180; then
  echo "FAIL: target family's remaining GVG did not drain to stored_size=0 after deleting the primary bucket"
  exit 1
fi

EMPTY_FAMILY_PRIMARY_SP_ID="$(gvg_family_primary_sp_id "$BUCKET_FAMILY_ID")"
EMPTY_FAMILY_GVG_COUNT="$(gvg_family_gvg_count "$BUCKET_FAMILY_ID")"
EMPTY_FAMILY_GVG_STORED_SIZE="$(gvg_stored_size_by_family "$BUCKET_FAMILY_ID")"
echo "  empty_family_id=${BUCKET_FAMILY_ID}"
echo "  empty_family_primary_sp_id=${EMPTY_FAMILY_PRIMARY_SP_ID:-unknown}"
echo "  empty_family_gvg_count=${EMPTY_FAMILY_GVG_COUNT}"
echo "  empty_family_gvg_stored_size=${EMPTY_FAMILY_GVG_STORED_SIZE:-unknown}"
assert_eq "$EMPTY_FAMILY_PRIMARY_SP_ID" "$SP_ID" "empty family remains owned by target SP before exit"
assert_eq "$EMPTY_FAMILY_GVG_COUNT" "1" "target family retains one empty GVG before exit"
assert_eq "$EMPTY_FAMILY_GVG_STORED_SIZE" "0" "target family's remaining GVG is empty before exit"

print_test_section "record pre-exit state"
GVG_BEFORE="$(exec_mocad query virtualgroup global-virtual-group-by-family-id "$BUCKET_FAMILY_ID" --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
SECONDARY_SP_IDS_BEFORE="$(printf '%s\n' "$GVG_BEFORE" | jq -c '.global_virtual_groups[0].secondary_sp_ids // []' 2>/dev/null || true)"
echo "  gvg_family_id=${BUCKET_FAMILY_ID}"
echo "  primary_sp_id_before=${BEFORE_PRIMARY_SP_ID}"
echo "  secondary_sp_ids_before=${SECONDARY_SP_IDS_BEFORE:-unknown}"

PRIMARY_COUNT_BEFORE="$(gvg_stat_value "$SP_ID" primary_count)"
SECONDARY_COUNT_BEFORE="$(gvg_stat_value "$SP_ID" secondary_count)"
echo "  primary_count_before=${PRIMARY_COUNT_BEFORE}"
echo "  secondary_count_before=${SECONDARY_COUNT_BEFORE}"
if gvg_statistics_query_supported; then
  assert_eq "$PRIMARY_COUNT_BEFORE" "0" "target SP has no primary GVGs before exit in empty-family mode"
  assert_gt "$SECONDARY_COUNT_BEFORE" "0" "target SP has secondary GVGs before exit"
else
  echo "  INFO: skipping GVG statistics assertion because local mocad does not expose gvg-statistics-within-sp"
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

if gvg_statistics_query_supported; then
  print_test_section "wait for target SP GVG counts to drain to zero"
  if ! wait_for_gvg_stat_value "$SP_ID" primary_count "0" 180; then
    echo "FAIL: target SP primary_count did not drain to zero"
    exit 1
  fi
  if ! wait_for_gvg_stat_value "$SP_ID" secondary_count "0" 180; then
    echo "FAIL: target SP secondary_count did not drain to zero"
    exit 1
  fi
  echo "  OK: target SP primary_count drained to 0"
  echo "  OK: target SP secondary_count drained to 0"
else
  print_test_section "skip GVG statistics drain check"
  echo "  INFO: local mocad does not expose gvg-statistics-within-sp; final SP removal is used as the end-to-end completion signal"
fi

print_test_section "complete final SP exit"
# the exit scheduler hands off the empty family first; a manual complete exit sent earlier is rejected
if wait_for_sp_removed_from_list "$OPERATOR" 120; then
  echo "  OK: target SP completed final exit automatically"
else
  complete_out="$(exec_sp_cmd "$TARGET_SP" -c /root/.moca-sp/config.toml sp.complete.exit --operatorAddress "$OPERATOR" 2>&1 || true)"
  echo "$complete_out"
  if ! wait_for_sp_removed_from_list "$OPERATOR" 180; then
    echo "FAIL: target SP is still in the chain SP list; the empty family blocked its exit"
    exit 1
  fi
  echo "  OK: target SP removed from the chain SP list"
fi

print_test_section "verify the empty family left the exited SP"
if ! FAMILIES_AFTER="$(exec_mocad query virtualgroup global-virtual-group-families 1000 --node "$TM_RPC" --output json)" \
  || ! printf '%s\n' "$FAMILIES_AFTER" | jq -e '(.gvg_families | type) == "array" and all(.gvg_families[]; type == "object" and (.id | type) != "null" and (.primary_sp_id | type) != "null")' >/dev/null 2>&1; then
  echo "FAIL: could not list GVG families after exit"
  exit 1
fi
FAMILY_PRIMARY_AFTER="$(printf '%s\n' "$FAMILIES_AFTER" | jq -r --arg id "$BUCKET_FAMILY_ID" '.gvg_families[] | select((.id | tostring) == $id) | .primary_sp_id | tostring')"
if [ -z "$FAMILY_PRIMARY_AFTER" ]; then
  echo "  OK: empty family ${BUCKET_FAMILY_ID} was removed with the exit"
else
  assert_ne "$FAMILY_PRIMARY_AFTER" "$SP_ID" "empty family no longer belongs to the exited SP"
  if ! SP_JSON_AFTER="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json)" \
    || ! printf '%s\n' "$SP_JSON_AFTER" | jq -e --arg sid "$FAMILY_PRIMARY_AFTER" '.sps[] | select((.id | tostring) == $sid)' >/dev/null 2>&1; then
    echo "FAIL: empty family ${BUCKET_FAMILY_ID} moved to SP ${FAMILY_PRIMARY_AFTER}, which is not in the chain SP list"
    exit 1
  fi
  echo "  OK: empty family ${BUCKET_FAMILY_ID} moved to SP ${FAMILY_PRIMARY_AFTER}"
fi

print_test_section "verify the auxiliary GVGs no longer use the exited SP"
if ! AUX_GVGS="$(exec_mocad query virtualgroup global-virtual-group-by-family-id "$SECONDARY_BUCKET_FAMILY_ID" --node "$TM_RPC" --output json)"; then
  echo "FAIL: could not read the auxiliary family's GVGs after exit"
  exit 1
fi
case "$(printf '%s\n' "$AUX_GVGS" | gvg_usage_verdict "$SP_ID")" in
  clear) echo "  OK: auxiliary GVGs no longer include SP ${SP_ID}" ;;
  uses)
    echo "$AUX_GVGS"
    echo "FAIL: the exited SP ${SP_ID} still serves an auxiliary GVG"
    exit 1
    ;;
  *)
    echo "$AUX_GVGS"
    echo "FAIL: the auxiliary family's GVG list is unreadable"
    exit 1
    ;;
esac

trap - EXIT
cleanup
echo "PASS: an empty family did not block the graceful exit"
