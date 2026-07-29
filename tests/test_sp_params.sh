#!/usr/bin/env bash
# E2E test: verify SP module parameters are correctly configured
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"

echo "Testing SP module parameters..."

# Query SP params
SP_PARAMS=$(exec_mocad query sp params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -z "$SP_PARAMS" ] || [ "$SP_PARAMS" = "{}" ]; then
  echo "  FAIL: cannot query SP params"
  exit 1
fi

DEPOSIT_DENOM=$(echo "$SP_PARAMS" | jq -r '.params.deposit_denom // empty' 2>/dev/null)
MIN_DEPOSIT=$(echo "$SP_PARAMS" | jq -r '.params.min_deposit // empty' 2>/dev/null)

echo "  deposit_denom: $DEPOSIT_DENOM"
echo "  min_deposit: $MIN_DEPOSIT"
if [ -z "$DEPOSIT_DENOM" ] || [ -z "$MIN_DEPOSIT" ]; then
  echo "  FAIL: sp params missing expected fields"
  exit 1
fi

# Query storage params
STORAGE_PARAMS=$(exec_mocad query storage params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -z "$STORAGE_PARAMS" ] || [ "$STORAGE_PARAMS" = "{}" ]; then
  echo "  FAIL: cannot query storage params"
  exit 1
fi
MAX_SEGMENT_SIZE=$(echo "$STORAGE_PARAMS" | jq -r '.params.versioned_params.max_segment_size // empty' 2>/dev/null)
REDUNDANT_DATA=$(echo "$STORAGE_PARAMS" | jq -r '.params.versioned_params.redundant_data_chunk_num // empty' 2>/dev/null)
REDUNDANT_PARITY=$(echo "$STORAGE_PARAMS" | jq -r '.params.versioned_params.redundant_parity_chunk_num // empty' 2>/dev/null)

echo "  max_segment_size: $MAX_SEGMENT_SIZE"
echo "  redundant_data_chunks: $REDUNDANT_DATA"
echo "  redundant_parity_chunks: $REDUNDANT_PARITY"
if [ -z "$MAX_SEGMENT_SIZE" ] || [ -z "$REDUNDANT_DATA" ] || [ -z "$REDUNDANT_PARITY" ]; then
  echo "  FAIL: storage versioned params missing expected fields"
  exit 1
fi

# Query payment params
PAYMENT_PARAMS=$(exec_mocad query payment params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -z "$PAYMENT_PARAMS" ] || [ "$PAYMENT_PARAMS" = "{}" ]; then
  echo "  FAIL: cannot query payment params"
  exit 1
fi
RESERVE_TIME=$(echo "$PAYMENT_PARAMS" | jq -r '.params.versioned_params.reserve_time // empty' 2>/dev/null)
FORCED_SETTLE=$(echo "$PAYMENT_PARAMS" | jq -r '.params.forced_settle_time // empty' 2>/dev/null)

echo "  payment reserve_time: $RESERVE_TIME"
echo "  payment forced_settle_time: $FORCED_SETTLE"
if [ -z "$RESERVE_TIME" ] || [ -z "$FORCED_SETTLE" ]; then
  echo "  FAIL: payment params missing expected fields"
  exit 1
fi

# Query virtualgroup params
VG_PARAMS=$(exec_mocad query virtualgroup params --node "$TM_RPC" --output json 2>/dev/null || echo "")
if [ -z "$VG_PARAMS" ] || [ "$VG_PARAMS" = "{}" ]; then
  echo "  FAIL: cannot query virtualgroup params"
  exit 1
fi
GVG_STAKING=$(echo "$VG_PARAMS" | jq -r '.params.gvg_staking_per_bytes // empty' 2>/dev/null)
echo "  vg gvg_staking_per_bytes: $GVG_STAKING"
if [ -z "$GVG_STAKING" ]; then
  echo "  FAIL: virtualgroup params missing gvg_staking_per_bytes"
  exit 1
fi

echo "PASS: SP/storage/payment/virtualgroup parameters queried"
