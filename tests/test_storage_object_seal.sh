#!/usr/bin/env bash
# E2E: object seal progress polling (devcontainer quick_object_test parity).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "storage object seal test"

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for object get-progress"
  exit 0
fi

SP_CHECK=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: object seal needs primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  echo "SKIP: cannot resolve primary SP"
  exit 0
fi

BUCKET_NAME="$(generate_bucket_name "e2e-seal")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="seal_object.txt"
OBJECT_REL="${BUCKET_NAME}/${OBJECT_NAME}"
TEST_FILE="$(create_test_file "/tmp/${OBJECT_NAME}" "seal test $(date)")"

cleanup() {
  rm -f "$TEST_FILE"
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing object seal progress (bucket=$BUCKET_NAME)..."

exec_moca_cmd_signed bucket create --primarySP "$PRIMARY_SP" "$BUCKET_URL" >/dev/null
wait_for_block 3

# moca-cmd object put (without --bypassSeal) polls HeadObject internally until
# OBJECT_STATUS_SEALED or its 1-hour timeout. A zero exit means SEALED.
exec_moca_cmd_signed object put --contentType "application/octet-stream" "$TEST_FILE" "$OBJECT_REL" >/dev/null || {
  echo "FAIL: object never reached OBJECT_STATUS_SEALED"
  exit 1
}
echo "  sealed"

out=$(exec_moca_cmd object head "$OBJECT_REL" || true)
if echo "$out" | grep -q "$OBJECT_NAME"; then
  echo "  object head ok"
fi

wait_for_block 4
ls_out=$(exec_moca_cmd object ls "$BUCKET_URL" 2>&1 || true)
if echo "$ls_out" | grep -q "$OBJECT_NAME"; then
  echo "  object list contains file"
else
  echo "  WARN: object not in list yet"
fi

trap - EXIT
cleanup
echo "PASS: object seal progress test completed"
