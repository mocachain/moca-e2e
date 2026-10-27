#!/usr/bin/env bash
# E2E: object seal progress polling (devcontainer quick_object_test parity).
# The object must reach OBJECT_STATUS_SEALED on chain with the uploaded size and be listed.
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
OBJECT_SIZE="$(wc -c < "$TEST_FILE" | tr -d ' ')"

cleanup() {
  rm -f "$TEST_FILE"
  exec_moca_cmd_signed object rm "$OBJECT_REL" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# assert_eq_within <timeout_s> <expected> <msg> <cmd...>: poll the command's stdout until it equals <expected>, then assert.
assert_eq_within() {
  local timeout="$1" expected="$2" msg="$3" actual deadline
  shift 3
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    actual="$("$@" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 2
  done
  assert_eq "$actual" "$expected" "$msg"
}

# `object head -f json` field; empty when the object does not exist.
object_field() { exec_moca_cmd object head -f json "$1" 2>/dev/null | grep -m1 '^{' | jq -r ".object_info.$2 // empty" 2>/dev/null || true; }
# size of <object> in the `object ls <bucket-url>` rows ("<date> <time> <size> <name>"), "absent" if not listed.
object_ls_size() { exec_moca_cmd object ls "$1" 2>/dev/null | awk -v n="$2" '$4 == n {print $3; f=1; exit} END {if (!f) print "absent"}'; }
bucket_presence() { if exec_moca_cmd bucket head -f json "$1" 2>/dev/null | grep -q '^{'; then echo present; else echo gone; fi; }

echo "Testing object seal progress (bucket=$BUCKET_NAME)..."

out=$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" "$BUCKET_URL" || true)
if ! grep -qF "make_bucket: ${BUCKET_NAME}" <<<"$out"; then
  echo "FAIL: bucket create output unexpected: $(echo "$out" | head -3)"
  exit 1
fi
assert_eq_within 60 present "bucket $BUCKET_NAME exists on chain" bucket_presence "$BUCKET_URL"

# object put (without --bypassSeal) prints "upload <obj> to <url>" only once HeadObject reports SEALED
# (errors print as "run command error:" with exit 0), so the head below must prove the seal.
out=$(exec_moca_cmd_signed object put --contentType "application/octet-stream" "$TEST_FILE" "$OBJECT_REL" || true)
if ! grep -qF "upload ${OBJECT_NAME} to ${OBJECT_REL}" <<<"$out"; then
  echo "FAIL: object put did not reach the sealed marker: $(echo "$out" | tail -3)"
  exit 1
fi

if ! wait_for_object_sealed "$OBJECT_REL"; then
  echo "FAIL: object never reached OBJECT_STATUS_SEALED"
  exit 1
fi
assert_eq "$(object_field "$OBJECT_REL" object_status)" "OBJECT_STATUS_SEALED" "object head object_status"
assert_eq "$(object_field "$OBJECT_REL" object_name)" "$OBJECT_NAME" "object head object_name"
assert_eq "$(object_field "$OBJECT_REL" payload_size)" "$OBJECT_SIZE" "object head payload_size"

assert_eq_within 60 "$OBJECT_SIZE" "object ls lists ${OBJECT_NAME} with its size" object_ls_size "$BUCKET_URL" "$OBJECT_NAME"

trap - EXIT
cleanup
echo "PASS: object seal progress test completed"
