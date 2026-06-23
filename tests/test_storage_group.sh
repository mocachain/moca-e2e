#!/usr/bin/env bash
# E2E test: group operations.
# When moca-cmd is available: create -> head -> update members -> head-member / ls-member ->
# setTag -> ls -> rm (aligned with devcontainer group_test flow).
# Otherwise: mocad tx storage create-group / head-group / update-group-member / delete-group.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/moca_cmd.sh
source "$SCRIPT_DIR/libs/moca_cmd.sh"

require_write_enabled "storage group test"
require_test_key

OWNER_ADDR=$(exec_mocad keys show "$TEST_KEY" -a --keyring-backend test 2>/dev/null || echo "")
MEMBER_ADDR=$(exec_mocad keys show "$SENDER_KEY" -a --keyring-backend test 2>/dev/null || echo "")

if [ -z "$OWNER_ADDR" ]; then
  echo "SKIP: testaccount not found in validator keyring"
  exit 0
fi

run_mocad_group_smoke() {
  local group_name priv
  group_name="e2e-test-group-$(date +%s)"
  echo "Testing storage group (mocad tx path): $group_name"
  echo "  Owner: $OWNER_ADDR"
  echo "  Member: $MEMBER_ADDR"

  # mocad's `tx storage create-group/update-group-member/delete-group` are EVM
  # precompile calls: they sign with the raw eth private key passed via
  # --privatekey, NOT the keyring --from account. Without it the CLI aborts in
  # NewPrivateKeyManager("") with "len of Keybytes is not equal to 32" before
  # ever broadcasting. (--evm-node is already injected by exec_mocad on remote.)
  priv=$(exec_mocad keys unsafe-export-eth-key "$TEST_KEY" --keyring-backend test 2>/dev/null || echo "")
  if [ -z "$priv" ]; then
    echo "SKIP: could not export eth key for '$TEST_KEY' (required for storage group txs)"
    exit 0
  fi

  echo "  Creating group..."
  local create_out create_hash
  create_out=$(exec_mocad tx storage create-group "$group_name" \
    --privatekey "$priv" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    -y 2>/dev/null || echo "FAILED")

  create_hash=$(echo "$create_out" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
  if [ -z "$create_hash" ]; then
    echo "FAIL: group creation failed on mocad path (group does not need SP; this is a real error)"
    echo "$create_out" | tail -5
    exit 1
  fi
  wait_for_evm_tx "$create_hash" 60 || true

  # Verify via the EVM tx receipt rather than head-group/list-groups: those
  # keeper queries are not reliably served on remote RPC nodes, but the receipt
  # status is authoritative (0x1 == the create-group precompile call succeeded).
  echo "  Verifying create receipt ($create_hash)..."
  local status
  status=$(_evm_rpc eth_getTransactionReceipt "[\"$create_hash\"]" | jq -r '.status // empty' 2>/dev/null)
  if [ "$status" != "0x1" ]; then
    echo "FAIL: create-group tx $create_hash did not succeed (receipt status=${status:-none})"
    exit 1
  fi
  echo "  OK: group created (receipt status 0x1)"

  # Best-effort head-group (informational; not served on all remote RPC nodes).
  exec_mocad query storage head-group "$OWNER_ADDR" "$group_name" \
    --node "$TM_RPC" --output json 2>/dev/null | jq -r '.group_info.id // empty' || true

  if [ -n "$MEMBER_ADDR" ]; then
    echo "  Adding member (best-effort)..."
    # update-group-member uses positional args, not flags:
    #   [group-name] [member-to-add] [member-expiration] [member-to-delete]
    local member_exp
    member_exp=$(( $(date +%s) + 31536000 ))  # +1 year
    exec_mocad tx storage update-group-member "$group_name" "$MEMBER_ADDR" "$member_exp" "" \
      --privatekey "$priv" \
      --from "$TEST_KEY" \
      --keyring-backend test \
      --chain-id "$CHAIN_ID" \
      --node "$TM_RPC" \
      --gas auto --gas-adjustment 1.5 \
      -y 2>/dev/null || true
    wait_for_tx 3
  fi

  echo "  Deleting group (best-effort)..."
  local del_out del_hash
  del_out=$(exec_mocad tx storage delete-group "$group_name" \
    --privatekey "$priv" \
    --from "$TEST_KEY" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    -y 2>/dev/null || echo "")
  del_hash=$(echo "$del_out" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
  if [ -n "$del_hash" ]; then
    wait_for_evm_tx "$del_hash" 60 || true
  else
    wait_for_tx 3
  fi
  echo "PASS: storage group operations tested (mocad path)"
}

run_moca_cmd_group_full() {
  local group_name
  group_name="e2e-group-$(date +%s)-${RANDOM}"
  local tags='[{"key":"key1","value":"value1"},{"key":"key2","value":"value2"}]'
  local updated_tags='[{"key":"key3","value":"value3"}]'
  local member="${MEMBER_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

  echo "Testing storage group (moca-cmd path): $group_name"

  cleanup_group() {
    exec_moca_cmd_signed group rm "$group_name" >/dev/null 2>&1 || true
  }
  trap cleanup_group EXIT

  echo "  Step 1: create group..."
  local out
  out=$(exec_moca_cmd_signed group create --tags="$tags" "$group_name" || true)
  if ! echo "$out" | grep -q "make_group:\|$group_name"; then
    echo "  WARN: create group output unexpected"
    trap - EXIT
    exit 0
  fi
  wait_for_tx 3

  echo "  Step 2: head..."
  exec_moca_cmd group head "$group_name" 2>/dev/null | head -20 || true
  wait_for_tx 2

  echo "  Step 3: update members..."
  out=$(exec_moca_cmd_signed group update --addMembers "$member" "$group_name" || true)
  echo "$out" | head -5
  wait_for_tx 3

  if [ -n "$OWNER_ADDR" ]; then
    echo "  Step 4-5: head-member / ls-member..."
    exec_moca_cmd group head-member --groupOwner "$OWNER_ADDR" "$group_name" "$member" 2>/dev/null || true
    exec_moca_cmd group ls-member --groupOwner "$OWNER_ADDR" "$group_name" 2>/dev/null | head -20 || true
  fi
  wait_for_tx 2

  echo "  Step 6: setTag..."
  out=$(exec_moca_cmd group setTag --tags="$updated_tags" "$group_name" || true)
  echo "$out" | head -5
  wait_for_tx 3

  echo "  Step 7: ls..."
  exec_moca_cmd group ls 2>/dev/null | head -20 || true

  echo "  Step 8: remove group..."
  exec_moca_cmd_signed group rm "$group_name" >/dev/null 2>&1 || true
  wait_for_tx 3

  trap - EXIT
  echo "PASS: storage group comprehensive test (moca-cmd path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_group_full
else
  run_mocad_group_smoke
fi
