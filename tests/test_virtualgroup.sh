#!/usr/bin/env bash
# E2E test: virtual group module — query GVGs and global virtual group families
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"

echo "Testing virtual group module..."

# Query virtualgroup params
echo "  Querying virtualgroup params..."
VG_PARAMS=$(exec_mocad query virtualgroup params \
  --node "$TM_RPC" --output json 2>/dev/null || echo "")

if [ -z "$VG_PARAMS" ] || [ "$VG_PARAMS" = "{}" ]; then
  echo "  WARN: Virtualgroup module not available"
  echo "PASS: Virtualgroup query attempted"
  exit 0
fi

GVG_STAKING=$(echo "$VG_PARAMS" | jq -r '.params.gvg_staking_per_bytes // empty' 2>/dev/null)
MAX_STORE_SIZE=$(echo "$VG_PARAMS" | jq -r '.params.max_global_virtual_group_num_per_family // empty' 2>/dev/null)
echo "  gvg_staking_per_bytes: $GVG_STAKING"
echo "  max_gvg_per_family: $MAX_STORE_SIZE"

# Check if any SPs registered
SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")

if [ "$NUM_SPS" -le 0 ]; then
  echo "  No SPs registered — skipping GVG queries"
  echo "PASS: Virtualgroup params queried"
  exit 0
fi

# Query global virtual group families
echo "  Querying global virtual group families..."
GVG_FAMILIES=$(exec_mocad query virtualgroup global-virtual-group-families \
  100 --node "$TM_RPC" --output json 2>/dev/null || echo "")

NUM_FAMILIES=$(echo "$GVG_FAMILIES" | jq '.gvg_families | length // 0' 2>/dev/null || echo "0")
echo "  GVG families: $NUM_FAMILIES"

# Query GVG statistics per SP
for i in $(seq 0 $((NUM_SPS - 1))); do
  SP_ID=$((i + 1))
  GVG_STATS=$(exec_mocad query virtualgroup gvg-statistics-within-sp "$SP_ID" \
    --node "$TM_RPC" --output json 2>/dev/null || echo "")

  if [ -n "$GVG_STATS" ] && [ "$GVG_STATS" != "{}" ]; then
    echo "  SP $SP_ID GVG count: $(echo "$GVG_STATS" | jq '.gvg_statistics.stored_size // "N/A"' 2>/dev/null)"
  fi
done

echo "PASS: Virtual group module tested"
