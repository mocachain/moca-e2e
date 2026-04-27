#!/usr/bin/env bash
# E2E: successor SP takes over a primary SP and keeps object reads available.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" != "local" ]; then
  echo "SKIP: storage object failover test is local-only"
  exit 0
fi

require_write_enabled "storage object failover test"

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for object get failover"
  exit 0
fi

SP_CHECK="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
NUM_SPS="$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
NUM_SPS="${NUM_SPS:-0}"
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: object failover needs primary + successors (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP_CONTAINER="sp-0"
PRIMARY_SP_EXPECTED_ENDPOINT="http://${PRIMARY_SP_CONTAINER}:9033"
PRIMARY_SP="$(printf '%s\n' "$SP_CHECK" | jq -r --arg primary_container "$PRIMARY_SP_CONTAINER" --arg expected_endpoint "$PRIMARY_SP_EXPECTED_ENDPOINT" '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and ((.description.moniker // "") == $primary_container or (.endpoint // "") == $expected_endpoint)) | .operator_address' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP" ] || [ "$PRIMARY_SP" = "null" ]; then
  echo "SKIP: cannot resolve operator for local primary SP container ${PRIMARY_SP_CONTAINER}"
  exit 0
fi

PRIMARY_SP_ID="$(printf '%s\n' "$SP_CHECK" | jq -r --arg primary_operator "$PRIMARY_SP" '.sps[] | select(.operator_address == $primary_operator) | .id' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP_ID" ] || [ "$PRIMARY_SP_ID" = "null" ]; then
  echo "SKIP: cannot resolve SP ID for local primary SP container ${PRIMARY_SP_CONTAINER}"
  exit 0
fi

PRIMARY_STATUS="$(get_sp_status_by_operator "$PRIMARY_SP")"
if [ "$PRIMARY_STATUS" != "STATUS_IN_SERVICE" ] && [ "$PRIMARY_STATUS" != "0" ]; then
  echo "SKIP: local primary SP ${PRIMARY_SP_CONTAINER} is not IN_SERVICE (status=${PRIMARY_STATUS:-unknown})"
  exit 0
fi

sha256_file() {
  local path="${1:?path required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  shasum -a 256 "$path" | awk '{print $1}'
}

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

wait_for_sp_removed_from_list() {
  local operator="${1:?operator required}"
  local timeout="${2:-180}"
  local deadline now sp_json

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    sp_json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
    if ! printf '%s\n' "$sp_json" | jq -e --arg op "$operator" '.sps[] | select(.operator_address == $op)' >/dev/null 2>&1; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_sp_removed_from_list: timeout after ${timeout}s; operator still present: ${operator}" >&2
      return 1
    fi
    sleep 3
  done
}

BUCKET_NAME="$(generate_bucket_name "e2e-obj-failover")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="failover-object.txt"
OBJECT_URL="${BUCKET_URL}/${OBJECT_NAME}"
SOURCE_FILE="$(create_test_file "/tmp/${BUCKET_NAME}-${OBJECT_NAME}" "storage failover $(date)")"
DOWNLOAD_FILE="/tmp/${BUCKET_NAME}-${OBJECT_NAME}.downloaded"

cleanup() {
  rm -f "$SOURCE_FILE" >/dev/null 2>&1 || true
  rm -f "$DOWNLOAD_FILE" >/dev/null 2>&1 || true
  exec_moca_cmd_signed object rm "$OBJECT_URL" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_test_section "Step 1: create bucket on ${PRIMARY_SP_CONTAINER}"
bucket_out="$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" "$BUCKET_URL" || true)"
if ! echo "$bucket_out" | grep -q "make_bucket:\|$BUCKET_NAME"; then
  echo "$bucket_out"
  echo "FAIL: bucket create did not succeed"
  exit 1
fi

print_test_section "Step 2: put object and wait for OBJECT_STATUS_SEALED"
put_out="$(exec_moca_cmd_signed object put --contentType "application/octet-stream" "$SOURCE_FILE" "$OBJECT_URL" || true)"
if ! echo "$put_out" | grep -qiE "object.*created|created on chain|upload"; then
  echo "$put_out"
  echo "FAIL: object put did not reach uploaded/sealed state"
  exit 1
fi
print_success "object put completed (SEALED)"

print_test_section "Step 3: record pre-exit primary ownership"
before_bucket_head="$(exec_moca_cmd bucket head "$BUCKET_URL" 2>&1 || true)"
if ! echo "$before_bucket_head" | grep -q "bucket_name:\"$BUCKET_NAME\""; then
  echo "$before_bucket_head"
  echo "FAIL: bucket head did not return the created bucket"
  exit 1
fi

BUCKET_FAMILY_ID="$(printf '%s\n' "$before_bucket_head" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
BEFORE_PRIMARY_SP_ID="$(printf '%s\n' "$before_bucket_head" | awk -F': ' '/^primary SP ID:/ {print $2; exit}')"
if [ -z "$BUCKET_FAMILY_ID" ] || [ -z "$BEFORE_PRIMARY_SP_ID" ]; then
  echo "$before_bucket_head"
  echo "FAIL: could not resolve bucket family ID / primary SP ID before exit"
  exit 1
fi
assert_eq "$BEFORE_PRIMARY_SP_ID" "$PRIMARY_SP_ID" "bucket primary SP ID matches target SP before exit"

print_test_section "Step 4: send sp.exit from ${PRIMARY_SP_CONTAINER}"
sp_exit_out="$(exec_sp_cmd "$PRIMARY_SP_CONTAINER" -c /root/.moca-sp/config.toml sp.exit --operatorAddress "$PRIMARY_SP" 2>&1 || true)"
if ! echo "$sp_exit_out" | grep -q "send sp exit txn successfully"; then
  echo "$sp_exit_out"
  echo "FAIL: moca-sp sp.exit did not return success"
  exit 1
fi
echo "$sp_exit_out"

print_test_section "Step 5: wait for chain status to become graceful exiting"
if ! wait_for_sp_status "$PRIMARY_SP" "STATUS_GRACEFUL_EXITING" 180; then
  echo "FAIL: primary SP never entered STATUS_GRACEFUL_EXITING"
  exit 1
fi
print_success "chain status is STATUS_GRACEFUL_EXITING"

print_test_section "Step 6: query successor takeover plan"
query_out="$(exec_sp_cmd "$PRIMARY_SP_CONTAINER" query.sp.exit -c /root/.moca-sp/config.toml --endpoint localhost:9333 2>&1 || true)"
echo "$query_out"
if echo "$query_out" | grep -q "spExitScheduler not exit"; then
  echo "FAIL: sp exit scheduler was not started"
  exit 1
fi
if ! echo "$query_out" | jq -e '.self_sp_id >= 0' >/dev/null 2>&1; then
  echo "FAIL: query.sp.exit did not return the expected JSON payload"
  exit 1
fi
SUCCESSOR_IDS="$(echo "$query_out" | jq -r '[.swap_out_dest[]?.successor_sp_id] | unique | .[]' 2>/dev/null || true)"

print_test_section "Step 7: wait for successor SP to become the new primary"
NEW_PRIMARY_SP_ID="$(wait_for_gvg_primary_sp_change "$BUCKET_FAMILY_ID" "$BEFORE_PRIMARY_SP_ID" 180)"
assert_ne "$NEW_PRIMARY_SP_ID" "$BEFORE_PRIMARY_SP_ID" "GVG primary SP changed after graceful exit"
if [ -n "$SUCCESSOR_IDS" ] && ! printf '%s\n' "$SUCCESSOR_IDS" | grep -qx "$NEW_PRIMARY_SP_ID"; then
  echo "  successor_sp_ids from query.sp.exit:"
  printf '%s\n' "$SUCCESSOR_IDS" | sed 's/^/    - /'
  echo "FAIL: bucket migrated to unexpected primary SP ID ${NEW_PRIMARY_SP_ID}"
  exit 1
fi
print_success "bucket primary moved from ${BEFORE_PRIMARY_SP_ID} to successor ${NEW_PRIMARY_SP_ID}"

print_test_section "Step 8: verify object get succeeds after successor takeover"
rm -f "$DOWNLOAD_FILE" >/dev/null 2>&1 || true
get_out="$(exec_moca_cmd_signed object get "$OBJECT_URL" "$DOWNLOAD_FILE" || true)"
if [ ! -f "$DOWNLOAD_FILE" ]; then
  echo "$get_out"
  echo "FAIL: object get did not succeed after successor takeover"
  exit 1
fi

SOURCE_SHA="$(sha256_file "$SOURCE_FILE")"
DOWNLOAD_SHA="$(sha256_file "$DOWNLOAD_FILE")"
assert_eq "$DOWNLOAD_SHA" "$SOURCE_SHA" "downloaded object matches original sha256"

print_test_section "Step 9: complete final primary SP exit"
if wait_for_sp_removed_from_list "$PRIMARY_SP" 90; then
  print_success "primary SP completed final exit automatically"
else
  complete_out="$(exec_sp_cmd "$PRIMARY_SP_CONTAINER" -c /root/.moca-sp/config.toml sp.complete.exit --operatorAddress "$PRIMARY_SP" 2>&1 || true)"
  echo "$complete_out"
  if ! echo "$complete_out" | grep -q "send complete sp exit txn successfully"; then
    if ! wait_for_sp_removed_from_list "$PRIMARY_SP" 30; then
      echo "FAIL: moca-sp sp.complete.exit did not return success"
      exit 1
    fi
    print_success "primary SP completed final exit automatically while sp.complete.exit was racing"
  else
    if ! wait_for_sp_removed_from_list "$PRIMARY_SP" 180; then
      echo "FAIL: primary SP still exists in chain SP list after complete exit"
      exit 1
    fi
    print_success "primary SP removed from chain SP list after sp.complete.exit"
  fi
fi

trap - EXIT
cleanup
echo "PASS: storage object failover successor takeover test completed"
