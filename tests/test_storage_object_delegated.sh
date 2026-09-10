#!/usr/bin/env bash
# E2E: delegated object lifecycle — the primary SP creates the object on chain on the
# user's behalf (MsgDelegateCreateObject) and later replaces its content
# (MsgDelegateUpdateObjectContent), the flow the moca-go-sdk e2e drives through
# DelegatePutObject / DelegateUpdateObjectContent.
# moca-cmd: bucket create -> object put --delegate -> sealed -> head + get/sha256 ->
#           object update --delegate (new content) -> re-sealed -> get/sha256 -> cleanup.
# The uploader signs no chain transaction in either step: the test pins that by
# checking its EVM nonce does not move and that moca-cmd prints no local tx hash.
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

require_write_enabled "storage object delegated test"

if ! resolve_moca_cmd >/dev/null 2>&1; then
  skip "moca-cmd required for delegated object put/update"
fi
# moca-cmd refs that predate the flag would fail on an unknown option, not on the flow.
# (captured first: `grep -q` on a live pipe closes it early, which pipefail reports as a failure)
PUT_HELP="$(exec_moca_cmd object put -h 2>/dev/null || true)"
if ! grep -q -- '--delegate' <<<"$PUT_HELP"; then
  skip "moca-cmd at this ref has no 'object put --delegate'"
fi

SP_CHECK=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
NUM_SPS="${NUM_SPS:-0}"
if [ "$NUM_SPS" -lt 3 ]; then
  skip "delegated object ops need primary + 2 secondaries (have ${NUM_SPS} SPs)"
fi

PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  skip "cannot resolve primary SP"
fi

BUCKET_NAME="$(generate_bucket_name "e2e-obj-dlg")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="delegated_object.txt"
OBJECT_URL="${BUCKET_URL}/${OBJECT_NAME}"
OBJECT_REL="${BUCKET_NAME}/${OBJECT_NAME}"
CONTENT_TYPE="application/octet-stream"
# /tmp is shared with the moca-cmd sidecar: put sources and the get target must live there.
SOURCE_FILE="$(create_test_file "/tmp/${BUCKET_NAME}-v1.txt" "delegated put $(date) ${RANDOM}")"
UPDATE_FILE="$(create_test_file "/tmp/${BUCKET_NAME}-v2.txt" "delegated update $(date) ${RANDOM} - second revision, deliberately longer than the first")"
DOWNLOAD_FILE="/tmp/${BUCKET_NAME}-download.txt"

cleanup() {
  rm -f "$SOURCE_FILE" "$UPDATE_FILE"
  remove_file_docker_aware "$DOWNLOAD_FILE"
  exec_moca_cmd_signed object rm "$OBJECT_URL" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The delegated create/update txs are signed by the SP operator, so the uploader's
# EVM nonce must stay put across both steps. The uploader is whatever account
# moca-cmd's keystore signs with — resolve it from there, not the mocad keyring,
# or the assertion pins an address that was never going to move.
UPLOADER_ADDR="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
if [ -z "$UPLOADER_ADDR" ]; then
  skip "cannot resolve the moca-cmd signer address for the nonce checks"
fi
uploader_nonce() {
  local n
  n="$(_evm_rpc eth_getTransactionCount "[\"${UPLOADER_ADDR}\",\"pending\"]")"
  echo "${n//\"/}"
}

# head_has_line <exact line>: `object head` prints one proto field per line.
head_has_line() {
  local out
  out="$(exec_moca_cmd object head "$OBJECT_REL" 2>/dev/null || true)"
  grep -qx -- "$1" <<<"$out"
}

# wait_for_object_content <expected sha256> [timeout]: re-download until the SP serves the
# expected payload (reads can lag the seal by a few blocks of metadata sync).
wait_for_object_content() {
  local expected="$1" timeout="${2:-60}" deadline got
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    remove_file_docker_aware "$DOWNLOAD_FILE"
    exec_moca_cmd_signed object get "$OBJECT_URL" "$DOWNLOAD_FILE" >/dev/null 2>&1 || true
    got="$(sha256_file_docker_aware "$DOWNLOAD_FILE" 2>/dev/null || true)"
    if [ -n "$got" ] && [ "$got" = "$expected" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "  wait_for_object_content: timeout after ${timeout}s; last sha256: ${got:-<no file>}" >&2
      return 1
    fi
    sleep 3
  done
}

print_test_section "Step 1: create bucket"
out=$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" "$BUCKET_URL" || true)
if ! echo "$out" | grep -q "make_bucket:\|$BUCKET_NAME"; then
  echo "FAIL: bucket create output unexpected: $(echo "$out" | head -3)"
  exit 1
fi
print_success "bucket created: $BUCKET_NAME"
NONCE_BEFORE="$(uploader_nonce)"

print_test_section "Step 2: object put --delegate (SP creates the object on chain, blocks until SEALED)"
# moca-cmd polls HeadObject until OBJECT_STATUS_SEALED before printing "upload <obj> to <url>".
# Its errors are printed as "run command error: ..." with exit 0, so assert on the output.
out=$(exec_moca_cmd_signed object put --delegate --contentType "$CONTENT_TYPE" "$SOURCE_FILE" "$OBJECT_URL" || true)
if ! echo "$out" | grep -qF -- "upload ${OBJECT_NAME} to ${OBJECT_URL}"; then
  echo "FAIL: delegated object put did not reach SEALED: $(echo "$out" | tail -3)"
  exit 1
fi
if echo "$out" | grep -q "transaction hash:"; then
  echo "FAIL: delegated put signed a local transaction: $(echo "$out" | grep 'transaction hash:')"
  exit 1
fi
if ! wait_for_object_sealed "$OBJECT_REL" 60; then
  echo "FAIL: object not OBJECT_STATUS_SEALED after delegated put"
  exit 1
fi
print_success "delegated put completed, object SEALED"

print_test_section "Step 3: object head reflects the delegated create"
SOURCE_SIZE="$(wc -c < "$SOURCE_FILE" | tr -d ' ')"
if ! head_has_line "object_name:\"${OBJECT_NAME}\""; then
  echo "FAIL: object head missing object name"
  exit 1
fi
if ! head_has_line "content_type:\"${CONTENT_TYPE}\""; then
  echo "FAIL: object head content_type is not ${CONTENT_TYPE}"
  exit 1
fi
if ! head_has_line "payload_size:${SOURCE_SIZE}"; then
  echo "FAIL: object head payload_size is not ${SOURCE_SIZE}"
  exit 1
fi
print_success "object head: name, content_type and payload_size (${SOURCE_SIZE}) match"
assert_eq "$(uploader_nonce)" "$NONCE_BEFORE" "uploader nonce unchanged by delegated put"

print_test_section "Step 4: object get matches the uploaded content"
SOURCE_SHA="$(sha256_file "$SOURCE_FILE")"
if ! wait_for_object_content "$SOURCE_SHA" 60; then
  echo "FAIL: downloaded object does not match the delegated put content"
  exit 1
fi
print_success "downloaded object sha256 matches (${SOURCE_SHA:0:12}...)"

print_test_section "Step 5: object update --delegate (SP replaces the content on chain, blocks until re-sealed)"
out=$(exec_moca_cmd_signed object update --delegate --contentType "$CONTENT_TYPE" "$UPDATE_FILE" "$OBJECT_URL" || true)
if ! echo "$out" | grep -qF -- "update ${OBJECT_NAME} to ${OBJECT_URL}"; then
  echo "FAIL: delegated object update did not reach SEALED: $(echo "$out" | tail -3)"
  exit 1
fi
if echo "$out" | grep -q "transaction hash:"; then
  echo "FAIL: delegated update signed a local transaction: $(echo "$out" | grep 'transaction hash:')"
  exit 1
fi
if ! wait_for_object_sealed "$OBJECT_REL" 60; then
  echo "FAIL: object not OBJECT_STATUS_SEALED after delegated update"
  exit 1
fi
UPDATE_SIZE="$(wc -c < "$UPDATE_FILE" | tr -d ' ')"
if head_has_line "is_updating:true"; then
  echo "FAIL: object is still flagged is_updating after the delegated update"
  exit 1
fi
if ! head_has_line "payload_size:${UPDATE_SIZE}"; then
  echo "FAIL: object head payload_size is not the updated ${UPDATE_SIZE}"
  exit 1
fi
print_success "delegated update completed, object re-SEALED with payload_size ${UPDATE_SIZE}"
assert_eq "$(uploader_nonce)" "$NONCE_BEFORE" "uploader nonce unchanged by delegated update"

print_test_section "Step 6: object get matches the updated content"
UPDATE_SHA="$(sha256_file "$UPDATE_FILE")"
assert_ne "$UPDATE_SHA" "$SOURCE_SHA" "update payload differs from the original"
if ! wait_for_object_content "$UPDATE_SHA" 60; then
  echo "FAIL: downloaded object does not match the delegated update content"
  exit 1
fi
print_success "downloaded object sha256 matches the update (${UPDATE_SHA:0:12}...)"

print_test_section "Step 7: cleanup"
out=$(moca_cmd_tx object rm "$OBJECT_URL" || true)
if ! echo "$out" | grep -qiE "delete|remove"; then
  echo "FAIL: object rm failed: $(echo "$out" | tail -2)"
  exit 1
fi
print_success "object removed"
out=$(moca_cmd_tx bucket rm "$BUCKET_URL" || true)
if ! echo "$out" | grep -qiE "delete_bucket|remove"; then
  echo "FAIL: bucket rm failed: $(echo "$out" | tail -2)"
  exit 1
fi
print_success "bucket removed"

trap - EXIT
cleanup
echo "PASS: storage object delegated test (moca-cmd path)"
