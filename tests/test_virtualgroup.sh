#!/usr/bin/env bash
# E2E test: virtual group module — query GVGs and global virtual group families.
# A family exists once SPs have been in use, every family has a registered primary, and each GVG
# keeps its full redundancy set of distinct, registered secondary SPs.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/assertions.sh
source "$SCRIPT_DIR/libs/assertions.sh"
# shellcheck source=libs/sp.sh
source "$SCRIPT_DIR/libs/sp.sh"

echo "Testing virtual group module..."

# Query virtualgroup params
echo "  Querying virtualgroup params..."
VG_PARAMS=$(exec_mocad query virtualgroup params \
  --node "$TM_RPC" --output json 2>/dev/null || echo "")

if [ -z "$VG_PARAMS" ] || [ "$VG_PARAMS" = "{}" ]; then
  echo "  FAIL: cannot query virtualgroup params"
  exit 1
fi

GVG_STAKING=$(echo "$VG_PARAMS" | jq -r '.params.gvg_staking_per_bytes // empty' 2>/dev/null)
MAX_GVG_PER_FAMILY=$(echo "$VG_PARAMS" | jq -r '.params.max_global_virtual_group_num_per_family // empty' 2>/dev/null)
echo "  gvg_staking_per_bytes: $GVG_STAKING"
echo "  max_gvg_per_family: $MAX_GVG_PER_FAMILY"
assert_gt "${GVG_STAKING:-0}" 0 "gvg_staking_per_bytes is positive"
assert_gt "${MAX_GVG_PER_FAMILY:-0}" 0 "max_global_virtual_group_num_per_family is positive"

# Check if any SPs registered
SP_JSON=$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "{}")
NUM_SPS=$(echo "$SP_JSON" | jq '.sps | length // 0' 2>/dev/null || echo "0")

if [ "$NUM_SPS" -le 0 ]; then
  echo "  FAIL: no SPs registered — GVG queries have nothing to verify"
  exit 1
fi
IN_SERVICE_SPS=$(echo "$SP_JSON" | jq '[.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0")] | length' 2>/dev/null || echo "0")
SP_IDS=$(echo "$SP_JSON" | jq -c '[.sps[].id | tonumber]' 2>/dev/null)

# Redundancy: a GVG has one secondary SP per data and parity chunk.
STORAGE_PARAMS=$(exec_mocad query storage params --node "$TM_RPC" --output json 2>/dev/null || echo "")
REDUNDANCY=$(echo "$STORAGE_PARAMS" | jq -r '(.params.versioned_params.redundant_data_chunk_num // 0) + (.params.versioned_params.redundant_parity_chunk_num // 0)' 2>/dev/null || echo "0")
assert_gt "${REDUNDANCY:-0}" 0 "storage redundancy (data + parity chunks) is positive"

# A GVG needs a primary plus one secondary per chunk, so a smaller topology (minimal, stress) has none to check.
SP_SLOTS=$NUM_SPS
if [ "$ENV" = "local" ]; then
  SP_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ec '^sp-[0-9]+$' || true)
  [ "${SP_CONTAINERS:-0}" -le "$SP_SLOTS" ] || SP_SLOTS=$SP_CONTAINERS
fi
if [ "$SP_SLOTS" -le "$REDUNDANCY" ]; then
  echo "  INFO: $SP_SLOTS SPs cannot form a GVG (needs a primary plus $REDUNDANCY secondaries); family and GVG checks skipped"
  echo "PASS: Virtual group module tested (params only)"
  exit 0
fi

# Some stacks create a family per SP while booting, others with the first bucket; either way one must exist by now.
echo "  Querying global virtual group families..."
deadline=$(( $(date +%s) + 60 ))
while :; do
  GVG_FAMILIES=$(exec_mocad query virtualgroup global-virtual-group-families \
    100 --node "$TM_RPC" --output json 2>/dev/null || echo "")
  NUM_FAMILIES=$(echo "$GVG_FAMILIES" | jq '.gvg_families | length // 0' 2>/dev/null || echo "0")
  [ "${NUM_FAMILIES:-0}" -ge 1 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 3
done
echo "  GVG families: $NUM_FAMILIES (SPs in service: $IN_SERVICE_SPS)"
if [ "${NUM_FAMILIES:-0}" -lt 1 ]; then
  echo "  FAIL: no GVG family on chain (families are created at SP boot or with the first bucket)"
  exit 1
fi
BAD_FAMILIES=$(echo "$GVG_FAMILIES" | jq -c --argjson ids "$SP_IDS" '[.gvg_families[] | select(.primary_sp_id | tonumber | IN($ids[]) | not) | {id, primary_sp_id}]')
if [ "$(echo "$BAD_FAMILIES" | jq 'length')" -ne 0 ]; then
  echo "  FAIL: families whose primary is not a registered SP: $BAD_FAMILIES"
  exit 1
fi
print_success "all $NUM_FAMILIES families have a registered primary SP"

# Every GVG: family size within the limit, a redundancy-sized set of distinct secondaries, all SPs registered.
ALL_GVGS="[]"
for family_id in $(echo "$GVG_FAMILIES" | jq -r '.gvg_families[].id'); do
  family_gvgs=$(exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null | jq -c '.global_virtual_groups // []' 2>/dev/null || true)
  if [ -z "$family_gvgs" ]; then
    echo "  FAIL: cannot query the GVGs of family $family_id"
    exit 1
  fi
  family_gvg_count=$(echo "$family_gvgs" | jq 'length')
  if [ "$family_gvg_count" -gt "$MAX_GVG_PER_FAMILY" ]; then
    echo "  FAIL: family $family_id holds $family_gvg_count GVGs, more than max_global_virtual_group_num_per_family ($MAX_GVG_PER_FAMILY)"
    exit 1
  fi
  ALL_GVGS=$(jq -c -n --argjson all "$ALL_GVGS" --argjson f "$family_gvgs" '$all + $f')
done
NUM_GVGS=$(echo "$ALL_GVGS" | jq 'length')
echo "  GVGs: $NUM_GVGS across $NUM_FAMILIES families"
assert_gt "$NUM_GVGS" 0 "at least one global virtual group exists"

BAD_GVGS=$(echo "$ALL_GVGS" | jq -c --argjson ids "$SP_IDS" --argjson red "$REDUNDANCY" '
  [ .[] | select(
      (.secondary_sp_ids | length) != $red
      or ((.secondary_sp_ids | unique | length) != (.secondary_sp_ids | length))
      or ([.primary_sp_id] + .secondary_sp_ids | map(select(IN($ids[]) | not)) | length) > 0
    ) | {id, primary_sp_id, secondary_sp_ids} ]')
if [ "$(echo "$BAD_GVGS" | jq 'length')" -ne 0 ]; then
  echo "  FAIL: GVGs without $REDUNDANCY distinct registered secondary SPs: $BAD_GVGS"
  exit 1
fi
print_success "all $NUM_GVGS GVGs have $REDUNDANCY distinct registered secondary SPs"

# Per-SP statistics must match the counts derived from the GVG list when mocad exposes the query (it does not today).
if gvg_statistics_query_supported; then
  for sp_id in $(echo "$SP_IDS" | jq -r '.[]'); do
    want_primary=$(echo "$ALL_GVGS" | jq --argjson id "$sp_id" '[.[] | select(.primary_sp_id == $id)] | length')
    want_secondary=$(echo "$ALL_GVGS" | jq --argjson id "$sp_id" '[.[] | select(.secondary_sp_ids | index($id) != null)] | length')
    assert_eq "$(gvg_stat_value "$sp_id" primary_count)" "$want_primary" "SP $sp_id primary GVG count"
    assert_eq "$(gvg_stat_value "$sp_id" secondary_count)" "$want_secondary" "SP $sp_id secondary GVG count"
  done
else
  echo "  INFO: mocad does not expose gvg-statistics-within-sp; per-SP GVG counts not queried"
fi

echo "PASS: Virtual group module tested"
