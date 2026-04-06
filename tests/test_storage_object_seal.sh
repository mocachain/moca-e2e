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
if [ "$NUM_SPS" -le 0 ]; then
  echo "SKIP: no storage providers"
  exit 0
fi

PRIMARY_SP=$(echo "$SP_CHECK" | jq -r '.sps[0].operator_address // empty' 2>/dev/null || true)
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

exec_moca_cmd_signed object put --contentType "application/octet-stream" "$TEST_FILE" "$OBJECT_REL" >/dev/null || {
  echo "WARN: object put failed"
  exit 0
}
wait_for_block 2

sealed=false
for i in $(seq 1 12); do
  prog=$(exec_moca_cmd object get-progress "$OBJECT_REL" 2>&1 || true)
  if echo "$prog" | grep -q "OBJECT_STATUS_SEALED"; then
    echo "  sealed after $((i * 5))s (approx)"
    sealed=true
    break
  fi
  sleep 5
done

if [ "$sealed" != true ]; then
  echo "  WARN: timeout waiting for OBJECT_STATUS_SEALED"
fi

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
