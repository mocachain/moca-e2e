#!/usr/bin/env bash
# E2E: storage fee lifecycle — fees stream while an object is stored, stop on
# delete, and the unstreamed deposit is reclaimable from the payment account.
# Pins the "no prepaid term" model: deposit -> store -> delete -> withdraw.
# Every mutation is verified on-chain (EVM receipt status / cosmos tx code /
# state gone), not just broadcast: moca-cmd swallows DeleteObject failures and
# does not wait for the EVM CreateBucket receipt at all.
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

require_write_enabled "storage fee reclaim test"
require_test_key

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for payment-account and object flows"
  exit 0
fi

SP_CHECK=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: sealing needs primary + 2 secondaries (have ${NUM_SPS} SPs)"
  exit 0
fi

PRIMARY_SP=$(first_in_service_sp_operator 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  echo "SKIP: cannot resolve primary SP"
  exit 0
fi

# The delete step waits out the reserve window so no early-deletion charge
# applies. All live networks run 60s; bail out rather than hang if an
# environment carries a much larger value (the code default is 180 days).
PARAMS=""
if [ -n "${REST:-}" ]; then
  PARAMS=$(curl -sf "${REST}/moca/payment/params" 2>/dev/null || echo "")
fi
if [ -z "$PARAMS" ]; then
  PARAMS=$(exec_mocad query payment params --node "$TM_RPC" --output json 2>/dev/null || echo "")
fi
RESERVE_TIME=$(echo "$PARAMS" | jq -r '.params.versioned_params.reserve_time // .params.versionedParams.reserveTime // empty' 2>/dev/null)
if [ -z "$RESERVE_TIME" ]; then
  echo "SKIP: cannot read payment reserve_time param"
  exit 0
fi
if [ "$RESERVE_TIME" -gt 300 ]; then
  echo "SKIP: reserve_time=${RESERVE_TIME}s too large for the delete-after-reserve wait"
  exit 0
fi

OWNER_ADDR=$(exec_mocad keys show "$TEST_KEY" -a --keyring-backend test 2>/dev/null || echo "")
if [ -z "$OWNER_ADDR" ]; then
  echo "SKIP: cannot resolve owner address for '$TEST_KEY'"
  exit 0
fi

# Stream-record reader: LCD when configured (CLI proto drift yields empty
# records against remote chains), CLI fallback; field naming differs across
# builds. Missing record or field reads as 0.
query_stream_field() { # $1=address $2=snake_case field $3=camelCase field
  local rec val
  rec=""
  if [ -n "${REST:-}" ]; then
    rec=$(curl -sf "${REST}/moca/payment/stream_record/$1" 2>/dev/null || echo "")
  fi
  if [ -z "$rec" ]; then
    rec=$(exec_mocad query payment show-stream-record "$1" --node "$TM_RPC" --output json 2>/dev/null \
      || exec_mocad query payment stream-record "$1" --node "$TM_RPC" --output json 2>/dev/null \
      || echo "")
  fi
  val=$(echo "$rec" | jq -r ".stream_record.$2 // .streamRecord.$3 // empty" 2>/dev/null)
  echo "${val:-0}"
}

bank_balance() { # $1=address
  exec_mocad query bank balances "$1" --node "$TM_RPC" --output json 2>/dev/null |
    jq -r '.balances[] | select(.denom=="amoca") | .amount' 2>/dev/null || echo "0"
}

# Tx success gate. Depending on the operation, moca-cmd/go-sdk submits either
# an EVM-precompile tx (bucket create, payment ops) or a plain cosmos tx, and
# for some ops it swallows a failed result (DeleteObject) or never waits for
# inclusion at all (bucket create). Take the last hash the command printed and
# require a confirmed success in whichever lane it landed: EVM receipt with
# status 0x1, or cosmos tx with code 0. An explicit revert / non-zero code
# fails immediately.
assert_tx_ok() { # $1=command output $2=label
  local out="$1" label="$2" hash rcpt status rec code _i
  hash=$(echo "$out" | grep -oiE '(0x)?[0-9a-f]{64}' | tail -1 | sed 's/^0x//' || true)
  if [ -z "$hash" ]; then
    echo "FAIL: $label: no tx hash found in command output"
    echo "$out" | tail -4
    exit 1
  fi
  for _i in $(seq 1 15); do
    rcpt=$(_evm_rpc eth_getTransactionReceipt "[\"0x${hash}\"]")
    status=$(echo "$rcpt" | jq -r '.status // empty' 2>/dev/null)
    if [ "$status" = "0x1" ]; then
      echo "  $label: EVM receipt status=0x1 (0x${hash:0:12}...)"
      return 0
    fi
    if [ "$status" = "0x0" ]; then
      echo "FAIL: $label: EVM tx 0x${hash} reverted (receipt status 0x0)"
      exit 1
    fi
    rec=$(curl -sf "${RPC}/tx?hash=0x${hash}" 2>/dev/null || echo "")
    code=$(echo "$rec" | jq -r '.result.tx_result.code // empty' 2>/dev/null)
    if [ "$code" = "0" ]; then
      echo "  $label: cosmos code=0 (0x${hash:0:12}...)"
      return 0
    fi
    if [ -n "$code" ]; then
      echo "FAIL: $label: cosmos tx 0x${hash} failed with code $code"
      echo "$rec" | jq -r '.result.tx_result.log // empty' 2>/dev/null | head -3
      exit 1
    fi
    sleep 2
  done
  echo "FAIL: $label: tx 0x${hash} not found as EVM receipt or cosmos tx"
  exit 1
}

# On-chain absence gate for deletes whose CLI output carries no usable hash.
wait_gone() { # $1=label $2...=mocad query args
  local label="$1" _i
  shift
  for _i in $(seq 1 15); do
    if ! exec_mocad query "$@" --node "$TM_RPC" --output json >/dev/null 2>&1; then
      echo "  $label: gone on chain"
      return 0
    fi
    sleep 2
  done
  echo "FAIL: $label still exists on chain after deletion"
  exit 1
}

BUCKET_NAME="$(generate_bucket_name "e2e-fee")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="fee_reclaim_object.bin"
OBJECT_REL="${BUCKET_NAME}/${OBJECT_NAME}"
TEST_FILE="$(create_test_file "/tmp/${OBJECT_NAME}" "fee reclaim test $(date)")"

cleanup() {
  rm -f "$TEST_FILE"
  exec_moca_cmd_signed object rm "$OBJECT_REL" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing storage fee reclaim (bucket=$BUCKET_NAME, reserve_time=${RESERVE_TIME}s)..."

print_test_section "dedicated payment account"
OUT=$(exec_moca_cmd_signed payment-account create) || {
  echo "FAIL: payment-account create failed"
  exit 1
}
assert_tx_ok "$OUT" "create payment account"
wait_for_block 2
# Newest account is listed last for this owner; prefer the addr:"..." field
# form, fall back to any bare address in the listing.
PA_LS=$(exec_moca_cmd payment-account ls --owner "$OWNER_ADDR" 2>/dev/null || true)
PA_ADDR=$(echo "$PA_LS" | grep -oE 'addr:"0x[a-fA-F0-9]{40}"' | tail -1 | grep -oE '0x[a-fA-F0-9]{40}' || true)
if [ -z "$PA_ADDR" ]; then
  PA_ADDR=$(echo "$PA_LS" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1 || true)
fi
if [ -z "$PA_ADDR" ]; then
  echo "FAIL: could not parse created payment account address"
  exit 1
fi
echo "  payment account: $PA_ADDR"

DEPOSIT="1000000000000000000" # 1 MOCA
BANK_PRE_DEPOSIT=$(bank_balance "$OWNER_ADDR")
OUT=$(exec_moca_cmd_signed payment-account deposit --toAddress "$PA_ADDR" --amount "$DEPOSIT") || {
  echo "FAIL: deposit failed"
  exit 1
}
assert_tx_ok "$OUT" "deposit"
wait_for_block 2
STATIC_0=$(query_stream_field "$PA_ADDR" static_balance staticBalance)
BANK_POST_DEPOSIT=$(bank_balance "$OWNER_ADDR")
# A fresh account with no flows holds the deposit exactly.
if [ "${STATIC_0:-0}" -ne "$DEPOSIT" ]; then
  echo "FAIL: fresh payment account static balance is $STATIC_0, expected exactly $DEPOSIT"
  exit 1
fi
# The deposit (plus any gas) left the owner's bank balance. Balances exceed
# 2^63 and float rounding at 1e26 scale makes awk unreliable, so compare in bc.
if [ "$(echo "$BANK_PRE_DEPOSIT - $BANK_POST_DEPOSIT >= $DEPOSIT" | bc)" != "1" ]; then
  echo "FAIL: owner bank did not decrease by the deposit (pre=$BANK_PRE_DEPOSIT post=$BANK_POST_DEPOSIT)"
  exit 1
fi
echo "  deposit reflected: static=$STATIC_0, owner bank down by >= deposit"

print_test_section "store: bucket + sealed object billed to the payment account"
OUT=$(exec_moca_cmd_signed bucket create --primarySP "$PRIMARY_SP" --paymentAddress "$PA_ADDR" "$BUCKET_URL")
assert_tx_ok "$OUT" "create bucket"
wait_for_block 2
# The bucket must actually bill the dedicated account, on chain.
BUCKET_PAYMENT=$(exec_mocad query storage head-bucket "$BUCKET_NAME" --node "$TM_RPC" --output json 2>/dev/null |
  jq -r '.bucket_info.payment_address // .bucketInfo.paymentAddress // empty' 2>/dev/null || true)
if [ "$(echo "$BUCKET_PAYMENT" | tr 'A-F' 'a-f')" != "$(echo "$PA_ADDR" | tr 'A-F' 'a-f')" ]; then
  echo "FAIL: bucket payment address is '$BUCKET_PAYMENT', expected $PA_ADDR"
  exit 1
fi
echo "  bucket payment address pinned to the dedicated account"

# object put without --bypassSeal polls until OBJECT_STATUS_SEALED, which is
# itself the on-chain proof for create + seal.
exec_moca_cmd_signed object put --contentType "application/octet-stream" "$TEST_FILE" "$OBJECT_REL" >/dev/null || {
  echo "FAIL: object never reached OBJECT_STATUS_SEALED"
  exit 1
}
SEALED_AT=$(date +%s)
echo "  sealed"

NETFLOW_STORED=$(query_stream_field "$PA_ADDR" netflow_rate netflowRate)
BUFFER_STORED=$(query_stream_field "$PA_ADDR" buffer_balance bufferBalance)
echo "  netflow_rate=$NETFLOW_STORED buffer_balance=$BUFFER_STORED"
case "$NETFLOW_STORED" in
-*) ;; # negative = paying out, as expected
*)
  echo "FAIL: expected negative netflow while object is stored, got '$NETFLOW_STORED'"
  exit 1
  ;;
esac
if [ "${BUFFER_STORED:-0}" -le 0 ]; then
  echo "FAIL: expected positive buffer balance while object is stored"
  exit 1
fi

print_test_section "delete after the reserve window"
NOW=$(date +%s)
WAIT=$((RESERVE_TIME - (NOW - SEALED_AT) + 10))
if [ "$WAIT" -gt 0 ]; then
  echo "  waiting ${WAIT}s for the reserve window to lapse..."
  sleep "$WAIT"
fi
# moca-cmd prints no hash for DeleteObject and swallows a failed tx result, so
# gate on the object actually disappearing from chain state.
exec_moca_cmd_signed object rm "$OBJECT_REL" >/dev/null || {
  echo "FAIL: object rm failed"
  exit 1
}
wait_gone "object" storage head-object "$BUCKET_NAME" "$OBJECT_NAME"
OUT=$(exec_moca_cmd_signed bucket rm "$BUCKET_URL") || {
  echo "FAIL: bucket rm failed"
  exit 1
}
assert_tx_ok "$OUT" "delete bucket"
wait_gone "bucket" storage head-bucket "$BUCKET_NAME"
wait_for_block 2

NETFLOW_AFTER=$(query_stream_field "$PA_ADDR" netflow_rate netflowRate)
LOCK_AFTER=$(query_stream_field "$PA_ADDR" lock_balance lockBalance)
STATIC_AFTER=$(query_stream_field "$PA_ADDR" static_balance staticBalance)
echo "  netflow_rate=$NETFLOW_AFTER lock_balance=$LOCK_AFTER static_balance=$STATIC_AFTER"
if [ "${NETFLOW_AFTER:-1}" != "0" ]; then
  echo "FAIL: netflow rate should return to 0 after deletion, got '$NETFLOW_AFTER'"
  exit 1
fi
if [ "${LOCK_AFTER:-1}" != "0" ]; then
  echo "FAIL: lock balance should be 0 after deletion, got '$LOCK_AFTER'"
  exit 1
fi
# Storage was not free: the stored window (>= reserve_time) must have consumed
# something...
if [ "${STATIC_AFTER:-0}" -ge "$DEPOSIT" ]; then
  echo "FAIL: static balance did not decrease at all ($STATIC_AFTER); storage was never charged"
  exit 1
fi
# ...but only the stored seconds (plus 1% validator tax on them); the reserve
# window for a tiny object is dust against the 1 MOCA deposit.
MIN_REMAINING="900000000000000000" # 0.9 MOCA
if [ "${STATIC_AFTER:-0}" -lt "$MIN_REMAINING" ]; then
  echo "FAIL: expected >=90% of the deposit to remain, got $STATIC_AFTER"
  exit 1
fi

print_test_section "reclaim: withdraw the unstreamed deposit"
BANK_BEFORE=$(bank_balance "$OWNER_ADDR")
WITHDRAW="500000000000000000" # 0.5 MOCA, under the 100 MOCA timelock threshold
OUT=$(exec_moca_cmd_signed payment-account withdraw --fromAddress "$PA_ADDR" --amount "$WITHDRAW") || {
  echo "FAIL: withdraw failed"
  exit 1
}
assert_tx_ok "$OUT" "withdraw"
wait_for_block 2
STATIC_FINAL=$(query_stream_field "$PA_ADDR" static_balance staticBalance)
BANK_AFTER=$(bank_balance "$OWNER_ADDR")
echo "  static_balance=$STATIC_FINAL bank: $BANK_BEFORE -> $BANK_AFTER"
EXPECTED_STATIC=$((STATIC_AFTER - WITHDRAW))
if [ "${STATIC_FINAL:-0}" -ne "$EXPECTED_STATIC" ]; then
  echo "FAIL: static balance after withdraw is $STATIC_FINAL, expected $EXPECTED_STATIC"
  exit 1
fi
# The withdrawal lands in the owner's bank minus tx gas; on this stack gas is
# well under 0.01 MOCA, so require the delta within that of the full amount
# (bc: balances exceed 2^63 and float rounding makes awk unreliable).
GAS_ALLOWANCE="10000000000000000" # 0.01 MOCA
if [ "$(echo "$BANK_AFTER - $BANK_BEFORE >= $WITHDRAW - $GAS_ALLOWANCE" | bc)" != "1" ]; then
  echo "FAIL: owner bank balance did not receive the withdrawal (before=$BANK_BEFORE after=$BANK_AFTER)"
  exit 1
fi

trap - EXIT
cleanup
echo "PASS: storage fees stream while stored, stop on delete, and the deposit is reclaimable"
