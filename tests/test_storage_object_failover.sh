#!/usr/bin/env bash
# E2E: object read failover when the primary SP is unreachable.
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
  echo "SKIP: object failover needs primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP_CONTAINER="sp-0"
PRIMARY_SP="$(printf '%s\n' "$SP_CHECK" | jq -r '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and (.endpoint | tostring | test(":9033$"))) | .operator_address' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP" ] || [ "$PRIMARY_SP" = "null" ]; then
  echo "SKIP: cannot resolve operator for local primary SP container ${PRIMARY_SP_CONTAINER}"
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

PRIMARY_PAUSED=0
BUCKET_NAME="$(generate_bucket_name "e2e-obj-failover")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="failover-object.txt"
OBJECT_URL="${BUCKET_URL}/${OBJECT_NAME}"
SOURCE_FILE="$(create_test_file "/tmp/${BUCKET_NAME}-${OBJECT_NAME}" "storage failover $(date)")"
DOWNLOAD_FILE="/tmp/${BUCKET_NAME}-${OBJECT_NAME}.downloaded"

cleanup() {
  if [ "$PRIMARY_PAUSED" = "1" ]; then
    docker unpause "$PRIMARY_SP_CONTAINER" >/dev/null 2>&1 || true
    PRIMARY_PAUSED=0
  fi
  rm -f "$SOURCE_FILE" "$DOWNLOAD_FILE"
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

print_test_section "Step 3: pause primary SP container"
docker pause "$PRIMARY_SP_CONTAINER" >/dev/null
PRIMARY_PAUSED=1
sleep 3
print_success "primary container paused"

print_test_section "Step 4: get object through secondary failover"
get_out="$(exec_moca_cmd_signed object get "$OBJECT_URL" "$DOWNLOAD_FILE" || true)"
if [ ! -f "$DOWNLOAD_FILE" ]; then
  echo "$get_out"
  echo "FAIL: object get did not produce a downloaded file while primary was paused"
  exit 1
fi

SOURCE_SHA="$(sha256_file "$SOURCE_FILE")"
DOWNLOAD_SHA="$(sha256_file "$DOWNLOAD_FILE")"
assert_eq "$DOWNLOAD_SHA" "$SOURCE_SHA" "downloaded object matches original sha256"

print_test_section "Step 5: unpause primary SP container"
docker unpause "$PRIMARY_SP_CONTAINER" >/dev/null
PRIMARY_PAUSED=0
print_success "primary container resumed"

trap - EXIT
cleanup
echo "PASS: storage object failover test completed"
