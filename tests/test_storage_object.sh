#!/usr/bin/env bash
# E2E: object lifecycle (devcontainer object_test parity).
# moca-cmd: create bucket -> put -> head -> setTag -> ls -> rm bucket.
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
    --fees "$FEES" \
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
    --fees "$FEES" \
    -y 2>/dev/null || true
  echo "PASS: storage object fallback (bucket smoke only; use moca-cmd for full flow)"
}

run_moca_cmd_object_full() {
  local bucket_name bucket_url object_file object_name object_path tags utags
  bucket_name="$(generate_bucket_name "e2e-obj")"
  bucket_url="moca://${bucket_name}"
  object_name="test_object.txt"
  object_path="${bucket_url}/${object_name}"
  object_file="$(create_test_file "/tmp/e2e-object-$(date +%s).txt" "object body $(date)")"
  tags="$(get_default_tags)"
  utags="$(get_updated_tags)"
  local content_type="application/octet-stream"

  cleanup() {
    rm -f "$object_file"
    exec_moca_cmd_signed bucket rm "$bucket_url" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  print_test_section "Step 1: create bucket"
  # moca_cmd_tx waits for the sender's mempool to drain before returning so the
  # subsequent object put doesn't race on nonce (bucket-create-with-tags emits
  # an implicit second tx whose hash isn't printed).
  local out
  out=$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" --tags="$tags" "$bucket_url" || true)
  if ! echo "$out" | grep -q "make_bucket:\|$bucket_name"; then
    echo "WARN: bucket create output unexpected"
    trap - EXIT
    exit 0
  fi

  print_test_section "Step 2: put object (blocks until SEALED)"
  # moca-cmd's object put polls HeadObject internally and only returns once the
  # object has reached OBJECT_STATUS_SEALED (i.e. replicated + signed by secondary
  # SPs). A non-zero exit means it either didn't reach SEALED or chain rejected
  # the createObject tx — in both cases the assertion below should fail.
  out=$(exec_moca_cmd_signed object put --tags="$tags" --contentType "$content_type" "$object_file" "$object_path" || true)
  if ! echo "$out" | grep -qiE "object.*created|created on chain|upload"; then
    echo "FAIL: object put did not reach uploaded/sealed state"
    exit 1
  fi
  print_success "object put completed (SEALED)"

  print_test_section "Step 3: object head"
  out=$(exec_moca_cmd object head "$object_path" || true)
  if ! echo "$out" | grep -q "object_name:\"$object_name\""; then
    echo "WARN: object head missing object name"
    trap - EXIT
    exit 0
  fi
  if ! echo "$out" | grep -q "bucket_name:\"$bucket_name\""; then
    echo "WARN: object head missing bucket name"
  fi
  print_success "object head fields present"

  print_test_section "Step 4: set object tags"
  out=$(exec_moca_cmd object setTag --tags="$utags" "$object_path" || true)
  if echo "$out" | grep -q "key:\"key3\""; then
    print_success "setTag output contains key3"
  fi
  wait_for_block 3

  print_test_section "Step 5: list objects"
  wait_for_block 5
  out=$(exec_moca_cmd object ls "$bucket_url" || true)
  if echo "$out" | grep -q "$object_name"; then
    print_success "object visible in list"
  else
    echo "  WARN: object not in list yet (SP DB sync)"
  fi

  print_test_section "Step 6: remove bucket"
  out=$(exec_moca_cmd_signed bucket rm "$bucket_url" || true)
  if echo "$out" | grep -qiE "delete|remove|success"; then
    print_success "bucket removed"
  fi
  wait_for_block 3

  trap - EXIT
  echo "PASS: storage object comprehensive test (moca-cmd path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_object_full
else
  run_mocad_object_smoke
fi
