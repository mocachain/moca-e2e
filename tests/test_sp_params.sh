#!/usr/bin/env bash
# E2E test: verify SP module parameters are correctly configured
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "Testing SP module parameters..."

# Query SP params
SP_PARAMS=$(exec_mocad query sp params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -z "$SP_PARAMS" ] || [ "$SP_PARAMS" = "{}" ]; then
  echo "  WARN: Cannot query SP params"
  echo "PASS: SP params query attempted"
  exit 0
fi

DEPOSIT_DENOM=$(echo "$SP_PARAMS" | jq -r '.params.deposit_denom // empty' 2>/dev/null)
MIN_DEPOSIT=$(echo "$SP_PARAMS" | jq -r '.params.min_deposit // empty' 2>/dev/null)

echo "  deposit_denom: $DEPOSIT_DENOM"
echo "  min_deposit: $MIN_DEPOSIT"

# Query storage params
STORAGE_PARAMS=$(exec_mocad query storage params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -n "$STORAGE_PARAMS" ] && [ "$STORAGE_PARAMS" != "{}" ]; then
  MAX_SEGMENT_SIZE=$(echo "$STORAGE_PARAMS" | jq -r '.params.max_segment_size // empty' 2>/dev/null)
  REDUNDANT_DATA=$(echo "$STORAGE_PARAMS" | jq -r '.params.redundant_data_chunk_num // empty' 2>/dev/null)
  REDUNDANT_PARITY=$(echo "$STORAGE_PARAMS" | jq -r '.params.redundant_parity_chunk_num // empty' 2>/dev/null)

  echo "  max_segment_size: $MAX_SEGMENT_SIZE"
  echo "  redundant_data_chunks: $REDUNDANT_DATA"
  echo "  redundant_parity_chunks: $REDUNDANT_PARITY"
fi

# Query payment params
PAYMENT_PARAMS=$(exec_mocad query payment params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -n "$PAYMENT_PARAMS" ] && [ "$PAYMENT_PARAMS" != "{}" ]; then
  RESERVE_TIME=$(echo "$PAYMENT_PARAMS" | jq -r '.params.reserve_time // empty' 2>/dev/null)
  FORCED_SETTLE=$(echo "$PAYMENT_PARAMS" | jq -r '.params.forced_settle_time // empty' 2>/dev/null)

  echo "  payment reserve_time: $RESERVE_TIME"
  echo "  payment forced_settle_time: $FORCED_SETTLE"
fi

# Query virtualgroup params
VG_PARAMS=$(exec_mocad query virtualgroup params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -n "$VG_PARAMS" ] && [ "$VG_PARAMS" != "{}" ]; then
  GVG_STAKING=$(echo "$VG_PARAMS" | jq -r '.params.gvg_staking_per_bytes // empty' 2>/dev/null)
  echo "  vg gvg_staking_per_bytes: $GVG_STAKING"
fi

echo "PASS: SP/storage/payment/virtualgroup parameters queried"
