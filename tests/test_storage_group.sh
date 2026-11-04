#!/usr/bin/env bash
# E2E test: group operations.
# When moca-cmd is available: create -> head -> update members -> head-member / ls-member ->
# setTag -> ls -> rm (aligned with devcontainer group_test flow), each step asserted on
# Otherwise: mocad tx storage create-group / head-group / update-group-member / delete-group.
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
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
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
      --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
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
    --fees "${COSMOS_TX_FEES:-10000000000000000amoca}" \
    -y 2>/dev/null || echo "")
  del_hash=$(echo "$del_out" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
  if [ -n "$del_hash" ]; then
    wait_for_evm_tx "$del_hash" 60 || true
  else
    wait_for_tx 3
  fi
  echo "PASS: storage group operations tested (mocad path)"
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

# `group head -f json` as one JSON object; empty when the group does not exist.
group_info_json() { exec_moca_cmd group head -f json "$1" 2>/dev/null | grep -m1 '^{' || true; }
group_field() { group_info_json "$1" | jq -r "$2 // empty" 2>/dev/null || true; }
group_tags() { group_info_json "$1" | jq -r '[.tags.tags[]? | "\(.key)=\(.value)"] | sort | join(",")' 2>/dev/null || true; }
group_presence() { if [ -n "$(group_info_json "$1")" ]; then echo present; else echo gone; fi; }
group_listed() { exec_moca_cmd group ls 2>/dev/null | awk -v n="$1" '$3 == n {f=1} END {print f ? "listed" : "missing"}'; }
# head-member args are "<member> <group>" (member first); prints member / not-member.
group_member_state() {
  if exec_moca_cmd group head-member --groupOwner "$1" "$2" "$3" 2>/dev/null | grep -qF "the user $2 is a member of the group: $3"; then
    echo member
  else
    echo not-member
  fi
}
# live rows printed by ls-member (the header is the first line).
group_member_rows() { exec_moca_cmd group ls-member --groupOwner "$1" "$2" 2>/dev/null | tail -n +2 | grep -c . || true; }

run_moca_cmd_group_full() {
  # global: the EXIT trap needs it after a failed assertion
  group_name="e2e-group-$(date +%s)-${RANDOM}"
  local tags='[{"key":"key1","value":"value1"},{"key":"key2","value":"value2"}]'
  local updated_tags='[{"key":"key3","value":"value3"}]'
  local owner member non_member="0x0000000000000000000000000000000000000001" out listed

  owner="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
  [ -n "$owner" ] || owner="$OWNER_ADDR"
  member="${MEMBER_ADDR:-}"
  if [ -z "$member" ] || [ "$(lc "$member")" = "$(lc "$owner")" ]; then
    member="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  fi

  echo "Testing storage group (moca-cmd path): $group_name"

  cleanup_group() {
    exec_moca_cmd_signed group rm "$group_name" >/dev/null 2>&1 || true
  }
  trap cleanup_group EXIT

  echo "  Step 1: create group..."
  out=$(exec_moca_cmd_signed group create --tags="$tags" "$group_name" || true)
  if ! grep -qF "make_group: ${group_name}" <<<"$out"; then
    echo "  FAIL: group create output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi

  echo "  Step 2: head..."
  assert_eq_within 60 "$group_name" "group $group_name exists on chain" group_field "$group_name" .group_name
  assert_eq "$(lc "$(group_field "$group_name" .owner)")" "$(lc "$owner")" "group owner is the signer"
  assert_eq_within 30 "key1=value1,key2=value2" "tags set at create" group_tags "$group_name"

  echo "  Step 3: update members..."
  out=$(exec_moca_cmd_signed group update --addMembers "$member" "$group_name" || true)
  if ! grep -qF "update_group: ${group_name}" <<<"$out"; then
    echo "  FAIL: group update output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi

  echo "  Step 4-5: head-member / ls-member..."
  assert_eq_within 60 member "head-member reports the added member" group_member_state "$owner" "$member" "$group_name"
  assert_eq "$(group_member_state "$owner" "$non_member" "$group_name")" "not-member" "head-member rejects a non-member"
  assert_eq_within 60 1 "ls-member lists exactly the added member" group_member_rows "$owner" "$group_name"
  # The list-member response currently has a blank member column; once it carries the address it must match.
  listed="$(exec_moca_cmd group ls-member --groupOwner "$owner" "$group_name" 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' || true)"
  if [ -n "$listed" ]; then
    assert_eq "$(lc "$listed")" "$(lc "$member")" "ls-member row address"
  else
    echo "  NOTE: ls-member row has no member address; only the row count is asserted"
  fi

  echo "  Step 6: setTag..."
  exec_moca_cmd_signed group setTag --tags="$updated_tags" "$group_name" >/dev/null 2>&1 || true
  assert_eq_within 30 "key3=value3" "tags after setTag replace the old set" group_tags "$group_name"

  echo "  Step 7: ls..."
  assert_eq_within 60 listed "group ls lists the group" group_listed "$group_name"

  echo "  Step 8: remove group..."
  out=$(exec_moca_cmd_signed group rm "$group_name" || true)
  if ! grep -qF "delete_group: ${group_name}" <<<"$out"; then
    echo "  FAIL: group rm output unexpected: $(echo "$out" | head -3)"
    exit 1
  fi
  assert_eq_within 60 gone "group head reports the group gone after rm" group_presence "$group_name"
  assert_eq_within 60 missing "group ls no longer lists the group" group_listed "$group_name"

  trap - EXIT
  echo "PASS: storage group comprehensive test (moca-cmd path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  run_moca_cmd_group_full
else
  run_mocad_group_smoke
fi
