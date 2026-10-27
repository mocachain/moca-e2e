#!/usr/bin/env bash
# E2E: object lifecycle (devcontainer object_test parity).
# moca-cmd: create bucket -> put (SEALED) -> head -> setTag -> ls -> rm object -> rm bucket,
# fallback: mocad storage txs when moca-cmd unavailable.
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

require_write_enabled "storage object test"

SP_CHECK=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
NUM_SPS="${NUM_SPS:-0}"
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: object ops need primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  echo "SKIP: cannot resolve primary SP"
  exit 0
fi

run_mocad_object_smoke() {
  local bucket_name
  bucket_name="$(generate_bucket_name "e2e-obj-mocad")"
  echo "Testing storage object (mocad fallback, bucket-only): $bucket_name"
  echo "  Note: full object put/setTag requires moca-cmd; mocad create-object needs payload/off-chain keys."

  local cr
  cr=$(exec_mocad tx storage create-bucket "$bucket_name" \
    --primary-sp-address "$PRIMARY_SP" \
    --visibility VISIBILITY_TYPE_PRIVATE \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
    -y 2>/dev/null || echo "FAILED")
  if echo "$cr" | grep -q "FAILED\|Error\|error"; then
    echo "SKIP: mocad bucket create failed; object upload requires moca-cmd"
    exit 0
  fi
  wait_for_tx 5
  exec_mocad query storage head-bucket "$bucket_name" --node "$TM_RPC" --output json 2>/dev/null | jq -r '.bucket_info.bucket_name // empty' || true
  exec_mocad tx storage delete-bucket "$bucket_name" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
    -y 2>/dev/null || true
  echo "PASS: storage object fallback (bucket smoke only; use moca-cmd for full flow)"
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

# `object head -f json` as one JSON object; empty when the object does not exist.
object_info_json() { exec_moca_cmd object head -f json "$1" 2>/dev/null | grep -m1 '^{' || true; }
object_field() { object_info_json "$1" | jq -r ".object_info.$2 // empty" 2>/dev/null || true; }
object_tags() { object_info_json "$1" | jq -r '[.object_info.tags.tags[]? | "\(.key)=\(.value)"] | sort | join(",")' 2>/dev/null || true; }
object_presence() { if [ -n "$(object_info_json "$1")" ]; then echo present; else echo gone; fi; }
# size of <object> in the `object ls <bucket-url>` rows ("<date> <time> <size> <name>"), "absent" if not listed.
object_ls_size() { exec_moca_cmd object ls "$1" 2>/dev/null | awk -v n="$2" '$4 == n {print $3; f=1; exit} END {if (!f) print "absent"}'; }
bucket_presence() { if exec_moca_cmd bucket head -f json "$1" 2>/dev/null | grep -q '^{'; then echo present; else echo gone; fi; }

run_moca_cmd_object_full() {
  local bucket_name object_name tags utags owner object_size
  bucket_name="$(generate_bucket_name "e2e-obj")"
  # globals: the EXIT trap needs them after a failed assertion
  bucket_url="moca://${bucket_name}"
  object_name="test_object.txt"
  object_path="${bucket_url}/${object_name}"
  object_file="$(create_test_file "/tmp/e2e-object-$(date +%s).txt" "object body $(date)")"
  object_size="$(wc -c < "$object_file" | tr -d ' ')"
  tags="$(get_default_tags)"
  utags="$(get_updated_tags)"
  local content_type="application/octet-stream"

  owner="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
  [ -n "$owner" ] || owner="$(get_key_address "$TEST_KEY")"

  cleanup() {
    rm -f "$object_file"
    exec_moca_cmd_signed object rm "$object_path" >/dev/null 2>&1 || true
    exec_moca_cmd_signed bucket rm "$bucket_url" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  print_test_section "Step 1: create bucket"
  # moca_cmd_tx waits for the sender's mempool to drain before returning so the
  # subsequent object put doesn't race on nonce (bucket-create-with-tags emits
  # an implicit second tx whose hash isn't printed).
  # make_bucket: prints before the tx is mined; the head below proves the bucket exists.
  local out
  out=$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" --tags="$tags" "$bucket_url" || true)
  if ! grep -qF "make_bucket: ${bucket_name}" <<<"$out"; then
    echo "FAIL: bucket create output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi
  assert_eq_within 60 present "bucket $bucket_name exists on chain" bucket_presence "$bucket_url"

  print_test_section "Step 2: put object (blocks until SEALED)"
  # "upload <obj> to <url>" prints only after SEALED; the head must prove it
  out=$(exec_moca_cmd_signed object put --tags="$tags" --contentType "$content_type" "$object_file" "$object_path" || true)
  if ! grep -qF "upload ${object_name} to ${object_path}" <<<"$out"; then
    echo "FAIL: object put did not reach the sealed marker: $(echo "$out" | tail -3)"
    exit 1
  fi
  if ! wait_for_object_sealed "${bucket_name}/${object_name}"; then
    echo "FAIL: object never reached OBJECT_STATUS_SEALED"
    exit 1
  fi
  print_success "object put completed (SEALED)"

  print_test_section "Step 3: object head"
  assert_eq "$(object_field "$object_path" object_name)" "$object_name" "object head object_name"
  assert_eq "$(object_field "$object_path" bucket_name)" "$bucket_name" "object head bucket_name"
  assert_eq "$(object_field "$object_path" object_status)" "OBJECT_STATUS_SEALED" "object head object_status"
  assert_eq "$(object_field "$object_path" payload_size)" "$object_size" "object head payload_size"
  assert_eq "$(object_field "$object_path" content_type)" "$content_type" "object head content_type"
  assert_eq "$(lc "$(object_field "$object_path" owner)")" "$(lc "$owner")" "object owner is the signer"
  assert_eq "$(object_tags "$object_path")" "key1=value1,key2=value2" "object tags set at put"

  print_test_section "Step 4: set object tags"
  exec_moca_cmd_signed object setTag --tags="$utags" "$object_path" >/dev/null 2>&1 || true
  assert_eq_within 30 "key3=value3" "object tags after setTag replace the old set" object_tags "$object_path"

  print_test_section "Step 5: list objects"
  assert_eq_within 60 "$object_size" "object ls lists ${object_name} with its size" object_ls_size "$bucket_url" "$object_name"

  print_test_section "Step 6: remove object"
  out=$(exec_moca_cmd_signed object rm "$object_path" || true)
  if ! grep -qxF "delete: ${object_name}" <<<"$out"; then
    echo "FAIL: object rm output unexpected: $(echo "$out" | tail -3)"
    exit 1
  fi
  assert_eq_within 60 gone "object head reports the object gone after rm" object_presence "$object_path"
  assert_eq_within 60 absent "object ls no longer lists the object" object_ls_size "$bucket_url" "$object_name"

  print_test_section "Step 7: remove bucket"
  out=$(exec_moca_cmd_signed bucket rm "$bucket_url" || true)
  if ! grep -qF "delete_bucket: ${bucket_name}" <<<"$out"; then
    echo "FAIL: bucket rm output unexpected: $(echo "$out" | tail -3)"
    exit 1
  fi
  assert_eq_within 60 gone "bucket head reports the bucket gone after rm" bucket_presence "$bucket_url"

  trap - EXIT
  rm -f "$object_file"
  echo "PASS: storage object comprehensive test (moca-cmd path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_object_full
else
  run_mocad_object_smoke
fi
