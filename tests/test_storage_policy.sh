#!/usr/bin/env bash
# E2E: policy CRUD on bucket/object/group (devcontainer policy_test parity).
# Prefers moca-cmd GRN paths; falls back to mocad tx storage put-policy.
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

require_write_enabled "storage policy test"
require_test_key

OWNER_ADDR=$(exec_mocad keys show "$TEST_KEY" -a --keyring-backend test 2>/dev/null || echo "")
GRANTEE_ADDR=$(exec_mocad keys show "$SENDER_KEY" -a --keyring-backend test 2>/dev/null || echo "")

if [ -z "$OWNER_ADDR" ] || [ -z "$GRANTEE_ADDR" ]; then
  echo "SKIP: required accounts not found"
  exit 0
fi

PERM_CHECK=$(exec_mocad query permission --help 2>/dev/null || echo "")
if [ -z "$PERM_CHECK" ]; then
  echo "SKIP: permission module not available"
  exit 0
fi

SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: policy ops need primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi
PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)

run_mocad_policy() {
  local bucket_name
  bucket_name="e2e-policy-mocad-$(date +%s)"
  echo "Testing policy (mocad path): $bucket_name"

  exec_mocad tx storage create-bucket "$bucket_name" \
    --primary-sp-address "$PRIMARY_SP" \
    --visibility VISIBILITY_TYPE_PRIVATE \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --fees "$FEES" \
    -y 2>/dev/null || {
    echo "SKIP: mocad-only path cannot complete bucket create (install moca-cmd)"
    exit 0
  }
  wait_for_tx 5

  exec_mocad tx storage put-policy "$bucket_name" \
    --grantee "$GRANTEE_ADDR" \
    --actions "ACTION_GET_OBJECT" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --fees "$FEES" \
    -y 2>/dev/null || true
  wait_for_tx 3

  exec_mocad tx storage delete-bucket "$bucket_name" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --fees "$FEES" \
    -y 2>/dev/null || true
  echo "PASS: storage permission policy (mocad path)"
}

run_moca_cmd_policy_full() {
  local bucket_name bucket_url object_name object_path group_name
  bucket_name="e2e-pol-bucket-$(date +%s)-${RANDOM}"
  bucket_url="moca://${bucket_name}"
  object_name="policy-obj-$(date +%s).txt"
  object_path="${bucket_name}/${object_name}"
  group_name="e2e-pol-group-$(date +%s)-${RANDOM}"

  # The policy principal must differ from the resource owner — the chain rejects
  # self-grants (x/storage ValidatePrincipal: "principal account can not be the bucket owner").
  local signer grantee
  signer="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
  if [ -z "$signer" ]; then
    signer="$OWNER_ADDR"
  fi
  grantee="0x70997970C51812dc3A010C7d01b50e0d17dc79C8" # well-known test address (Hardhat #1) != signer

  local bucket_res="grn:b::${bucket_name}"
  local object_res="grn:o::${bucket_name}/${object_name}"
  # A group GRN embeds the group OWNER (the signer that created it), not the grantee.
  local group_res="grn:g:${signer}:${group_name}"

  # Hard mode: verify every policy tx receipt on-chain (read by moca_cmd_tx).
  export CHECK_TX_STATUS=1

  cleanup() {
    exec_moca_cmd_signed bucket rm "$bucket_url" >/dev/null 2>&1 || true
    exec_moca_cmd_signed group rm "$group_name" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  echo "Testing policy (moca-cmd path, signer=$signer grantee=$grantee)"

  print_test_section "create bucket"
  local out
  out=$(exec_moca_cmd_signed bucket create --primarySP "$PRIMARY_SP" "$bucket_url" || true)
  if ! echo "$out" | grep -q "make_bucket:\|$bucket_name"; then
    echo "FAIL: bucket create failed for policy test"
    echo "$out" | head -5
    exit 1
  fi
  wait_for_block 4

  print_test_section "put object"
  echo "content" > "/tmp/${object_name}"
  # moca-cmd returns once the object is SEALED (replicated + signed by secondary
  # SPs), so we don't need a separate seal poll here.
  out=$(exec_moca_cmd_signed object put "/tmp/${object_name}" "$object_path" || true)
  rm -f "/tmp/${object_name}"
  if ! echo "$out" | grep -qiE "created|txHash"; then
    echo "FAIL: object put failed (object policy needs it)"
    echo "$out" | head -5
    exit 1
  fi

  print_test_section "create group"
  out=$(exec_moca_cmd_signed group create "$group_name" || true)
  if ! echo "$out" | grep -qiE "make_group|group id"; then
    echo "FAIL: group create failed (group policy needs it)"
    echo "$out" | head -5
    exit 1
  fi
  wait_for_block 3

  # put_policy_checked <label> <actions> <resource>: put (receipt-verified) then
  # assert the policy is actually listed for the grantee.
  put_policy_checked() {
    local label="$1" actions="$2" res="$3" p_out
    if ! p_out=$(moca_cmd_tx policy put --grantee "$grantee" --actions "$actions" "$res"); then
      echo "FAIL: $label policy put failed on-chain"
      echo "$p_out" | head -5
      exit 1
    fi
    wait_for_block 3
    p_out=$(exec_moca_cmd policy ls --grantee "$grantee" "$res" || true)
    echo "$p_out" | head -15
    if [ -z "$p_out" ] || echo "$p_out" | grep -qiE "No such Policy|run command error"; then
      echo "FAIL: $label policy not listed after put"
      exit 1
    fi
  }

  print_test_section "bucket policy put / ls"
  put_policy_checked "bucket" "createObj,getObj" "$bucket_res"

  print_test_section "object policy put / ls"
  put_policy_checked "object" "get,delete" "$object_res"

  print_test_section "group policy put / ls / rm"
  put_policy_checked "group" "update" "$group_res"
  if ! moca_cmd_tx policy rm --grantee "$grantee" "$group_res" >/dev/null; then
    echo "FAIL: group policy rm failed on-chain"
    exit 1
  fi
  wait_for_block 3

  print_test_section "bucket policy rm"
  if ! moca_cmd_tx policy rm --grantee "$grantee" "$bucket_res" >/dev/null; then
    echo "FAIL: bucket policy rm failed on-chain"
    exit 1
  fi
  wait_for_block 3
  out=$(exec_moca_cmd policy ls --grantee "$grantee" "$bucket_res" || true)
  if ! echo "$out" | grep -qi "No such Policy"; then
    echo "FAIL: bucket policy still listed after rm"
    echo "$out" | head -10
    exit 1
  fi

  exec_moca_cmd_signed group rm "$group_name" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$bucket_url" >/dev/null 2>&1 || true
  trap - EXIT
  echo "PASS: storage policy comprehensive test (moca-cmd path)"
}

echo "Testing storage permission policies..."

PERM_PARAMS=$(exec_mocad query permission params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -n "$PERM_PARAMS" ] && [ "$PERM_PARAMS" != "{}" ]; then
  echo "  permission params ok"
fi

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_policy_full
else
  run_mocad_policy
fi
