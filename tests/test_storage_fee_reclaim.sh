#!/usr/bin/env bash
# E2E: storage fee lifecycle — fees stream while an object is stored, stop on
# delete, and the unstreamed deposit is reclaimable from the payment account.
# Pins the "no prepaid term" model: deposit -> store -> delete -> withdraw.
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
exec_moca_cmd_signed payment-account create >/dev/null || {
  echo "FAIL: payment-account create failed"
  exit 1
}
wait_for_block 3
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
exec_moca_cmd_signed payment-account deposit --toAddress "$PA_ADDR" --amount "$DEPOSIT" >/dev/null || {
  echo "FAIL: deposit failed"
  exit 1
}
wait_for_block 3
STATIC_0=$(query_stream_field "$PA_ADDR" static_balance staticBalance)
if [ "${STATIC_0:-0}" -lt "$DEPOSIT" ]; then
  echo "FAIL: deposit not reflected in static balance (got $STATIC_0)"
  exit 1
fi

print_test_section "store: bucket + sealed object billed to the payment account"
exec_moca_cmd_signed bucket create --primarySP "$PRIMARY_SP" --paymentAddress "$PA_ADDR" "$BUCKET_URL" >/dev/null
wait_for_block 3
# object put without --bypassSeal polls until OBJECT_STATUS_SEALED.
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
exec_moca_cmd_signed object rm "$OBJECT_REL" >/dev/null || {
  echo "FAIL: object rm failed"
  exit 1
}
wait_for_block 3
exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null || {
  echo "FAIL: bucket rm failed"
  exit 1
}
wait_for_block 3

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
# Only the stored seconds (plus 1% validator tax on them) were consumed; the
# 60s window for a tiny object is dust against the 1 MOCA deposit.
MIN_REMAINING="900000000000000000" # 0.9 MOCA
if [ "${STATIC_AFTER:-0}" -lt "$MIN_REMAINING" ]; then
  echo "FAIL: expected >=90% of the deposit to remain, got $STATIC_AFTER"
  exit 1
fi

print_test_section "reclaim: withdraw the unstreamed deposit"
BANK_BEFORE=$(bank_balance "$OWNER_ADDR")
WITHDRAW="500000000000000000" # 0.5 MOCA, under the 100 MOCA timelock threshold
exec_moca_cmd_signed payment-account withdraw --fromAddress "$PA_ADDR" --amount "$WITHDRAW" >/dev/null || {
  echo "FAIL: withdraw failed"
  exit 1
}
wait_for_block 3
STATIC_FINAL=$(query_stream_field "$PA_ADDR" static_balance staticBalance)
BANK_AFTER=$(bank_balance "$OWNER_ADDR")
echo "  static_balance=$STATIC_FINAL bank: $BANK_BEFORE -> $BANK_AFTER"
EXPECTED_STATIC=$((STATIC_AFTER - WITHDRAW))
if [ "${STATIC_FINAL:-0}" -ne "$EXPECTED_STATIC" ]; then
  echo "FAIL: static balance after withdraw is $STATIC_FINAL, expected $EXPECTED_STATIC"
  exit 1
fi
# Owner's bank balance grows by the withdrawal minus tx gas; balances exceed
# int64 so compare in awk. Require at least half the withdrawal to net out.
if ! awk -v before="$BANK_BEFORE" -v after="$BANK_AFTER" -v w="$WITHDRAW" \
  'BEGIN { exit !(after - before >= w / 2) }'; then
  echo "FAIL: owner bank balance did not receive the withdrawal (before=$BANK_BEFORE after=$BANK_AFTER)"
  exit 1
fi

trap - EXIT
cleanup
echo "PASS: storage fees stream while stored, stop on delete, and the deposit is reclaimable"
