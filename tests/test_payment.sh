#!/usr/bin/env bash
# E2E: payment account create / list / stream-record / deposit / withdraw
# (devcontainer payment_test parity: moca-cmd path when available).
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

require_write_enabled "payment test"
require_test_key

OWNER_ADDR=$(exec_mocad keys show "$TEST_KEY" -a --keyring-backend test 2>/dev/null || echo "")

run_moca_cmd_payment() {
  echo "Testing payment module (moca-cmd path)..."

  local default_addr out pa_addr before dep_amt after withdraw_amt after2
  default_addr="$(exec_moca_cmd account ls 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)"
  if [ -z "$default_addr" ]; then
    default_addr="$OWNER_ADDR"
  fi
  if [ -z "$default_addr" ]; then
    echo "SKIP: cannot resolve owner address for payment-account ls"
    exit 0
  fi

  print_test_section "payment-account create"
  out=$(exec_moca_cmd_signed payment-account create || true)
  if ! echo "$out" | grep -qiE "txHash|transaction"; then
    echo "WARN: payment-account create output unexpected, falling back to mocad"
    return 1
  fi
  wait_for_block 5

  print_test_section "payment-account ls"
  out=$(exec_moca_cmd payment-account ls --owner "$default_addr" || true)
  echo "$out" | head -12
  pa_addr=$(echo "$out" | grep -oE 'addr:"0x[0-9a-fA-F]{40}"' | head -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
  if [ -z "$pa_addr" ]; then
    pa_addr=$(echo "$out" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1 || true)
  fi
  if [ -z "$pa_addr" ]; then
    echo "WARN: could not parse payment account address"
    return 1
  fi

  print_test_section "stream-record before deposit"
  out=$(exec_moca_cmd payment-account stream-record "$pa_addr" || true)
  echo "$out" | head -8
  before=$(echo "$out" | grep -oE 'Static Balance:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "0")

  dep_amt="1000000000000000000"
  print_test_section "deposit"
  out=$(exec_moca_cmd_signed payment-account deposit --toAddress "$pa_addr" --amount "$dep_amt" || true)
  echo "$out" | head -6
  wait_for_block 5

  out=$(exec_moca_cmd payment-account stream-record "$pa_addr" || true)
  after=$(echo "$out" | grep -oE 'Static Balance:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "0")
  echo "  static balance after deposit: $after (before: $before)"
  if [ "${after:-0}" -le "${before:-0}" ]; then
    echo "FAIL: static balance did not increase after deposit"
    exit 1
  fi

  withdraw_amt="500000000000000000"
  print_test_section "withdraw"
  out=$(exec_moca_cmd_signed payment-account withdraw --fromAddress "$pa_addr" --amount "$withdraw_amt" || true)
  echo "$out" | head -6
  wait_for_block 5

  out=$(exec_moca_cmd payment-account stream-record "$pa_addr" || true)
  after2=$(echo "$out" | grep -oE 'Static Balance:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "0")
  echo "  static balance after withdraw: $after2"
  if [ "${after2:-0}" -ge "${after:-0}" ]; then
    echo "FAIL: static balance did not decrease after withdraw"
    exit 1
  fi

  exec_moca_cmd payment-account ls --owner "$default_addr" 2>/dev/null | head -8 || true
  echo "PASS: payment module (moca-cmd path)"
  exit 0
}

run_mocad_payment() {
  echo "Testing payment module (mocad path)..."
  # The payment txs derive the signer from --privatekey, not the keyring
  # --from account. Without it the CLI aborts with "len of Keybytes is not
  # equal to 32" before broadcasting.
  local priv
  priv=$(exec_mocad keys unsafe-export-eth-key "$TEST_KEY" --keyring-backend test 2>/dev/null || echo "")
  if [ -z "$priv" ]; then
    echo "  FAIL: cannot export private key for '$TEST_KEY'"
    exit 1
  fi
  local CREATE_RESULT
  CREATE_RESULT=$(exec_mocad tx payment create-payment-account \
    --from "$TEST_KEY" \
    --privatekey "$priv" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    -y 2>/dev/null || echo "FAILED")

  if echo "$CREATE_RESULT" | grep -q "FAILED\|Error\|error"; then
    echo "  FAIL: payment account creation failed: $CREATE_RESULT"
    exit 1
  fi
  wait_for_tx 5

  if [ -z "$OWNER_ADDR" ]; then
    echo "  FAIL: cannot resolve owner address to verify created account"
    exit 1
  fi

  ACCOUNTS=$(exec_mocad query payment get-payment-accounts-by-owner "$OWNER_ADDR" \
    --node "$TM_RPC" --output json 2>/dev/null || echo "")
  # Field naming differs across mocad builds: snake_case on the local stack,
  # camelCase on current remote chains. Same for the stream-record command name.
  NUM_ACCOUNTS=$(echo "$ACCOUNTS" | jq '(.payment_accounts // .paymentAccounts // []) | length' 2>/dev/null || echo "0")
  echo "  payment accounts for owner: $NUM_ACCOUNTS"

  if [ "$NUM_ACCOUNTS" -le 0 ]; then
    echo "  FAIL: created payment account not returned by get-payment-accounts-by-owner"
    exit 1
  fi

  PA_ADDR=$(echo "$ACCOUNTS" | jq -r '(.payment_accounts // .paymentAccounts // [])[0] // empty' 2>/dev/null)
  echo "  payment account: $PA_ADDR"

  # Read the stream record via LCD when configured: the CLI ABCI path decodes
  # with the local binary's proto and silently yields an empty record when it
  # does not match the remote chain's version. Fall back to the CLI, whose
  # command is show-stream-record on current builds, stream-record on older
  # ones; no record exists until the first deposit either way.
  query_stream_balance() {
    local rec bal
    rec=""
    if [ -n "${REST:-}" ]; then
      rec=$(curl -sf "${REST}/moca/payment/stream_record/$1" 2>/dev/null || echo "")
    fi
    if [ -z "$rec" ]; then
      rec=$(exec_mocad query payment show-stream-record "$1" --node "$TM_RPC" --output json 2>/dev/null \
        || exec_mocad query payment stream-record "$1" --node "$TM_RPC" --output json 2>/dev/null \
        || echo "")
    fi
    # jq on empty input prints nothing and exits 0, so default via the shell
    bal=$(echo "$rec" | jq -r '.stream_record.static_balance // .streamRecord.staticBalance // empty' 2>/dev/null)
    echo "${bal:-0}"
  }

  BALANCE=$(query_stream_balance "$PA_ADDR")
  echo "  stream balance: $BALANCE"

  DEPOSIT_AMOUNT="1000000000000000000"
  exec_mocad tx payment deposit "$PA_ADDR" "${DEPOSIT_AMOUNT}" \
    --from "$TEST_KEY" \
    --privatekey "$priv" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    -y 2>/dev/null || {
    echo "  FAIL: deposit tx broadcast failed"
    exit 1
  }
  wait_for_tx 5

  BALANCE_AFTER=$(query_stream_balance "$PA_ADDR")
  echo "  stream balance after deposit: $BALANCE_AFTER (before: $BALANCE)"
  if [ "${BALANCE_AFTER:-0}" -le "${BALANCE:-0}" ]; then
    echo "  FAIL: static balance did not increase after deposit"
    exit 1
  fi

  WITHDRAW_AMOUNT="500000000000000000"
  exec_mocad tx payment withdraw "$PA_ADDR" "${WITHDRAW_AMOUNT}" \
    --from "$TEST_KEY" \
    --privatekey "$priv" \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node "$TM_RPC" \
    --gas auto --gas-adjustment 1.5 \
    -y 2>/dev/null || {
    echo "  FAIL: withdraw tx broadcast failed"
    exit 1
  }
  wait_for_tx 3

  BALANCE_FINAL=$(query_stream_balance "$PA_ADDR")
  echo "  stream balance after withdraw: $BALANCE_FINAL"
  if [ "${BALANCE_FINAL:-0}" -ge "${BALANCE_AFTER:-0}" ]; then
    echo "  FAIL: static balance did not decrease after withdraw"
    exit 1
  fi

  echo "PASS: payment module operations tested (mocad path)"
}

if resolve_moca_cmd >/dev/null 2>&1; then
  if ! run_moca_cmd_payment; then
    run_mocad_payment
  fi
else
  run_mocad_payment
fi
