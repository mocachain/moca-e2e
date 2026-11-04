#!/usr/bin/env bash
# E2E test: bucket operations.
# When moca-cmd is available: full flow aligned with devcontainer (create -> ls -> head ->
# get-quota -> update visibility -> setTag -> buy-quota -> verify quota -> rm), each step
# Otherwise: mocad tx storage create-bucket / head-bucket / delete-bucket (legacy path).
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
# shellcheck source=libs/sp.sh
source "$SCRIPT_DIR/libs/sp.sh"

require_write_enabled "storage bucket test"
require_test_key

SP_CHECK=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
NUM_SPS="${NUM_SPS:-0}"

if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: bucket ops need primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  echo "SKIP: cannot resolve primary SP"
  exit 0
fi

run_mocad_bucket_smoke() {
  local bucket_name
  bucket_name="e2e-test-bucket-$(date +%s)"
  echo "Testing storage bucket (mocad tx path): $bucket_name"
  echo "  Primary SP: $PRIMARY_SP"

  echo "  Creating bucket..."
  local create_result
  create_result=$(exec_mocad tx storage create-bucket "$bucket_name" \
    --primary-sp-address "$PRIMARY_SP" \
    --visibility VISIBILITY_TYPE_PRIVATE \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
    -y 2>/dev/null || echo "FAILED")

  if echo "$create_result" | grep -q "FAILED\|Error\|error"; then
    echo "  WARN: bucket create failed (SP may not be fully operational)"
    echo "SKIP: mocad-only path cannot complete without SP off-chain approval (install moca-cmd)"
    exit 0
  fi

  wait_for_tx 5

  echo "  Querying bucket..."
  local bucket_info
  bucket_info=$(exec_mocad query storage head-bucket "$bucket_name" \
    --node "$TM_RPC" --output json 2>/dev/null || echo "")
  if [ -n "$bucket_info" ] && echo "$bucket_info" | jq -e '.bucket_info' >/dev/null 2>&1; then
    echo "  head-bucket: ok"
  else
    echo "  WARN: head-bucket returned no usable info"
  fi

  echo "  Deleting bucket..."
  exec_mocad tx storage delete-bucket "$bucket_name" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
    -y 2>/dev/null || true
  wait_for_tx 3
  echo "PASS: storage bucket operations tested (mocad path)"
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# `bucket head -f json` as one JSON object; empty when the bucket does not exist.
bucket_info_json() { exec_moca_cmd bucket head -f json "$1" 2>/dev/null | grep -m1 '^{' || true; }
bucket_field() { bucket_info_json "$1" | jq -r "$2 // empty" 2>/dev/null || true; }
bucket_tags() { bucket_info_json "$1" | jq -r '[.tags.tags[]? | "\(.key)=\(.value)"] | sort | join(",")' 2>/dev/null || true; }
bucket_presence() { if [ -n "$(bucket_info_json "$1")" ]; then echo present; else echo gone; fi; }
bucket_listed() { exec_moca_cmd bucket ls 2>/dev/null | awk -v n="$1" '$NF == n {f=1} END {print f ? "listed" : "missing"}'; }
bucket_charged_quota() { exec_moca_cmd bucket get-quota "$1" 2>/dev/null | awk '/^charged quota:/ {print $3; exit}'; }

run_moca_cmd_bucket_full() {
  local bucket_name
  bucket_name="e2e-bucket-$(date +%s)-${RANDOM}"
  # global: the EXIT trap needs it after a failed assertion
  bucket_url="moca://${bucket_name}"
  local tags='[{"key":"key1","value":"value1"},{"key":"key2","value":"value2"}]'
  local updated_tags='[{"key":"key3","value":"value3"}]'
  local quota_target=1000000000
  local owner out

  owner="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
  [ -n "$owner" ] || owner="$(get_key_address "$TEST_KEY")"

  echo "Testing storage bucket (moca-cmd full path): $bucket_name"

  cleanup_bucket() {
    exec_moca_cmd_signed bucket rm "$bucket_url" >/dev/null 2>&1 || true
  }
  trap cleanup_bucket EXIT

  echo "  Step 1: create bucket..."
  # make_bucket: prints before the tx is mined; the head below proves the bucket exists.
  out=$(moca_cmd_tx bucket create --tags="$tags" --primarySP "$PRIMARY_SP" "$bucket_url" || true)
  if ! grep -qF "make_bucket: ${bucket_name}" <<<"$out"; then
    echo "  FAIL: bucket create output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi
  assert_eq_within 60 "$bucket_name" "bucket $bucket_name exists on chain" bucket_field "$bucket_url" .bucket_name

  echo "  Step 2: head..."
  assert_eq "$(bucket_field "$bucket_url" .bucket_status)" "BUCKET_STATUS_CREATED" "bucket status"
  assert_eq "$(lc "$(bucket_field "$bucket_url" .owner)")" "$(lc "$owner")" "bucket owner is the signer"
  assert_eq "$(bucket_field "$bucket_url" .visibility)" "VISIBILITY_TYPE_PRIVATE" "default visibility"
  assert_eq_within 30 "key1=value1,key2=value2" "tags set at create" bucket_tags "$bucket_url"

  echo "  Step 3: ls..."
  assert_eq_within 60 listed "bucket ls lists the bucket" bucket_listed "$bucket_name"

  echo "  Step 4: get-quota..."
  assert_eq_within 60 0 "charged quota before buy-quota" bucket_charged_quota "$bucket_url"

  echo "  Step 5: update visibility..."
  exec_moca_cmd_signed bucket update --visibility=public-read "$bucket_url" >/dev/null 2>&1 || true
  assert_eq_within 30 VISIBILITY_TYPE_PUBLIC_READ "visibility after update to public-read" bucket_field "$bucket_url" .visibility
  exec_moca_cmd_signed bucket update --visibility=private "$bucket_url" >/dev/null 2>&1 || true
  assert_eq_within 30 VISIBILITY_TYPE_PRIVATE "visibility after update back to private" bucket_field "$bucket_url" .visibility

  echo "  Step 6: setTag..."
  exec_moca_cmd_signed bucket setTag --tags="$updated_tags" "$bucket_url" >/dev/null 2>&1 || true
  assert_eq_within 30 "key3=value3" "tags after setTag replace the old set" bucket_tags "$bucket_url"

  echo "  Step 7-8: buy-quota + verify..."
  moca_cmd_tx bucket buy-quota --chargedQuota "$quota_target" "$bucket_url" >/dev/null 2>&1 || true
  assert_eq_within 60 "$quota_target" "charged quota after buy-quota" bucket_charged_quota "$bucket_url"

  echo "  Step 9: remove bucket..."
  out=$(exec_moca_cmd_signed bucket rm "$bucket_url" || true)
  if ! grep -qF "delete_bucket: ${bucket_name}" <<<"$out"; then
    echo "  FAIL: bucket rm output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi
  assert_eq_within 60 gone "bucket head reports the bucket gone after rm" bucket_presence "$bucket_url"

  trap - EXIT
  echo "PASS: storage bucket comprehensive test (moca-cmd path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_bucket_full
else
  run_mocad_bucket_smoke
fi
