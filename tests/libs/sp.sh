#!/usr/bin/env bash
# Storage provider and virtual group helpers.

# First IN_SERVICE SP operator from chain JSON (not moca-cmd output).
# If SP_ENDPOINT_FILTER is set (regex), prefer SPs whose endpoint matches. Useful
# on testnet where both legacy .org and new .dev SPs coexist and tests should
# target a specific cluster.
first_in_service_sp_operator() {
  local json addr
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ -n "${SP_ENDPOINT_FILTER:-}" ]; then
    addr=$(echo "$json" | jq -r --arg f "$SP_ENDPOINT_FILTER" \
      '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and (.endpoint | test($f))) | .operator_address' 2>/dev/null | head -1)
    if [ -n "$addr" ] && [ "$addr" != "null" ]; then
      echo "$addr"
      return 0
    fi
  fi
  addr=$(echo "$json" | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .operator_address' 2>/dev/null | head -1)
  if [ -n "$addr" ] && [ "$addr" != "null" ]; then
    echo "$addr"
    return 0
  fi
  echo "$json" | jq -r '.sps[0].operator_address // empty' 2>/dev/null
}

# SP endpoint URL from first IN_SERVICE SP (http/https).
# If SP_ENDPOINT_FILTER is set (regex), prefer SPs whose endpoint matches.
first_in_service_sp_endpoint() {
  local json ep
  json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ -n "${SP_ENDPOINT_FILTER:-}" ]; then
    ep=$(echo "$json" | jq -r --arg f "$SP_ENDPOINT_FILTER" \
      '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and (.endpoint | test($f))) | .endpoint' 2>/dev/null | head -1)
    if [ -n "$ep" ] && [ "$ep" != "null" ]; then
      echo "$ep"
      return 0
    fi
  fi
  ep=$(echo "$json" | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .endpoint' 2>/dev/null | head -1)
  if [ -n "$ep" ] && [ "$ep" != "null" ]; then
    echo "$ep"
    return 0
  fi
  echo "$json" | jq -r '.sps[0].endpoint // empty' 2>/dev/null
}

extract_tx_hash() {
  local output="$1"
  local h
  h=$(echo "$output" | grep -oE 'transaction hash:[[:space:]]+0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1)
  [ -n "$h" ] && echo "$h" && return 0
  h=$(echo "$output" | grep -oE 'txHash[=:][[:space:]]*0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1)
  [ -n "$h" ] && echo "$h" && return 0
  echo "$output" | grep -oE 'txn hash:[[:space:]]*0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1
}

list_sp_container_names() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$' | sort -V || true
}

sp_container_name_for_index() {
  local index="${1:?sp index required}"
  echo "sp-${index}"
}

exec_sp_cmd() {
  local container="${1:?sp container required}"
  shift
  docker exec "$container" moca-sp "$@"
}

get_sp_status_by_operator() {
  local operator="${1:?operator required}"
  exec_mocad query sp storage-provider-by-operator-address "$operator" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.storage_provider.status // .storageProvider.status // empty' 2>/dev/null || true
}

wait_for_sp_status() {
  local operator="${1:?operator required}"
  local expected_status="${2:?expected status required}"
  local timeout="${3:-120}"
  local deadline now status

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    status="$(get_sp_status_by_operator "$operator")"
    if [ "$status" = "$expected_status" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_sp_status: timeout after ${timeout}s; last status: ${status:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

sp_appears_as_secondary_somewhere() {
  local sp_id="${1:?sp id required}"
  local family_id

  for family_id in $(exec_mocad query virtualgroup global-virtual-group-families 100 \
    --node "$TM_RPC" --output json 2>/dev/null | jq -r '.gvg_families[]?.id' 2>/dev/null); do
    if exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
      --node "$TM_RPC" --output json 2>/dev/null \
      | jq -e --argjson sid "$sp_id" '[.global_virtual_groups[]?.secondary_sp_ids[]?] | index($sid) != null' >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

current_family_count() {
  exec_mocad query virtualgroup global-virtual-group-families 100 \
    --node "$TM_RPC" --output json 2>/dev/null | jq -r '.gvg_families | length // 0' 2>/dev/null || echo "0"
}

select_target_sp_index() {
  local requested="${E2E_SP_EXIT_INDEX:-}"
  local candidate_id candidate_idx family_count seen_first

  if [ -n "$requested" ] && [ "$requested" -ge 0 ] 2>/dev/null && [ "$requested" -lt "${NUM_SPS:-0}" ] 2>/dev/null; then
    printf '%s\n' "$requested"
    return 0
  fi

  family_count="$(current_family_count)"
  if [ "$family_count" = "0" ]; then
    seen_first=0
    for candidate_id in $(printf '%s\n' "${SP_JSON:-}" \
      | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .id' 2>/dev/null | sort -nr); do
      [ -n "$candidate_id" ] || continue
      candidate_idx=$((candidate_id - 1))
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^sp-${candidate_idx}$"; then
        continue
      fi
      if [ "$seen_first" = "0" ]; then
        seen_first=1
        continue
      fi
      printf '%s\n' "$candidate_idx"
      return 0
    done
  fi

  for candidate_id in $(printf '%s\n' "${SP_JSON:-}" \
    | jq -r '.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") | .id' 2>/dev/null | sort -nr); do
    [ -n "$candidate_id" ] || continue
    candidate_idx=$((candidate_id - 1))
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^sp-${candidate_idx}$" \
      && sp_appears_as_secondary_somewhere "$candidate_id"; then
      printf '%s\n' "$candidate_idx"
      return 0
    fi
  done

  return 1
}

gvg_primary_sp_id_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].primary_sp_id // empty' 2>/dev/null || true
}

wait_for_gvg_primary_sp_change() {
  local family_id="${1:?family id required}"
  local old_sp_id="${2:?old primary sp id required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_primary_sp_id_by_family "$family_id")"
    if [ -n "$current" ] && [ "$current" != "$old_sp_id" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_primary_sp_change: timeout after ${timeout}s; last primary SP ID: ${current:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

secondary_sp_ids_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -c '[.global_virtual_groups[]?.secondary_sp_ids[]?] | unique' 2>/dev/null || echo "[]"
}

gvg_stats_json_by_sp() {
  local sp_id="${1:?sp id required}"
  exec_mocad query virtualgroup gvg-statistics-within-sp "$sp_id" \
    --node "$TM_RPC" --output json 2>/dev/null || echo '{}'
}

gvg_statistics_query_supported() {
  exec_mocad query virtualgroup --help 2>/dev/null | grep -q "gvg-statistics-within-sp"
}

gvg_family_json_by_id() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-family "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null || echo '{}'
}

gvg_family_primary_sp_id() {
  local family_id="${1:?family id required}"
  gvg_family_json_by_id "$family_id" \
    | jq -r '.global_virtual_group_family.primary_sp_id // .globalVirtualGroupFamily.primarySpId // empty' 2>/dev/null || true
}

gvg_family_gvg_count() {
  local family_id="${1:?family id required}"
  gvg_family_json_by_id "$family_id" \
    | jq -r '(.global_virtual_group_family.global_virtual_group_ids // .globalVirtualGroupFamily.globalVirtualGroupIds // []) | length' 2>/dev/null || echo "0"
}

gvg_stored_size_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].stored_size // .global_virtual_groups[0].store_size // empty' 2>/dev/null || true
}

wait_for_gvg_stored_size() {
  local family_id="${1:?family id required}"
  local expected="${2:?expected value required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_stored_size_by_family "$family_id")"
    if [ -n "$current" ] && [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_stored_size: timeout after ${timeout}s; stored_size=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_gvg_family_gvg_count() {
  local family_id="${1:?family id required}"
  local expected="${2:?expected value required}"
  local timeout="${3:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_family_gvg_count "$family_id")"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_family_gvg_count: timeout after ${timeout}s; gvg_count=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

gvg_stat_value() {
  local sp_id="${1:?sp id required}"
  local field="${2:?field required}"
  local json

  json="$(gvg_stats_json_by_sp "$sp_id")"
  case "$field" in
    primary_count)
      printf '%s\n' "$json" | jq -r '.gvg_statistics.primary_count // .gvgStatistics.primaryCount // 0' 2>/dev/null || echo "0"
      ;;
    secondary_count)
      printf '%s\n' "$json" | jq -r '.gvg_statistics.secondary_count // .gvgStatistics.secondaryCount // 0' 2>/dev/null || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

wait_for_gvg_stat_value() {
  local sp_id="${1:?sp id required}"
  local field="${2:?field required}"
  local expected="${3:?expected value required}"
  local timeout="${4:-180}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(gvg_stat_value "$sp_id" "$field")"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_gvg_stat_value: timeout after ${timeout}s; ${field}=${current:-unknown}, expected=${expected}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_sp_removed_from_list() {
  local operator="${1:?operator required}"
  local timeout="${2:-180}"
  local deadline now sp_json

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    sp_json="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
    if ! printf '%s\n' "$sp_json" | jq -e --arg op "$operator" '.sps[] | select(.operator_address == $op)' >/dev/null 2>&1; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_sp_removed_from_list: timeout after ${timeout}s; operator still present: ${operator}" >&2
      return 1
    fi
    sleep 3
  done
}

create_bucket_with_target_as_secondary() {
  local target_sp_id="${1:?target sp id required}"
  local sp_json="${2:-${SP_JSON:-}}"
  local candidate_operators candidate bucket_name bucket_url bucket_out bucket_head family_id secondary_ids attempt

  candidate_operators="$(printf '%s\n' "$sp_json" | jq -r --arg sid "$target_sp_id" \
    '.sps[] | select((.id|tostring) != $sid and (.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0")) | .operator_address' 2>/dev/null || true)"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    for attempt in 1 2 3; do
      bucket_name="e2e-sp-exit-secondary-${target_sp_id}-$(date +%s)-${RANDOM}"
      bucket_url="moca://${bucket_name}"
      bucket_out="$(moca_cmd_tx bucket create --primarySP "$candidate" "$bucket_url" || true)"
      if ! echo "$bucket_out" | grep -q "$bucket_name"; then
        echo "$bucket_out"
        echo "FAIL: auxiliary bucket create did not succeed on candidate primary SP ${candidate}"
        return 1
      fi

      bucket_head="$(exec_moca_cmd bucket head "$bucket_url" 2>&1 || true)"
      family_id="$(printf '%s\n' "$bucket_head" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
      if [ -z "$family_id" ]; then
        echo "$bucket_head"
        echo "FAIL: could not resolve auxiliary bucket family ID"
        return 1
      fi

      secondary_ids="$(secondary_sp_ids_by_family "$family_id")"
      echo "  auxiliary bucket attempt=${attempt} candidate_primary=${candidate} family_id=${family_id} secondary_sp_ids=${secondary_ids}"
      if printf '%s\n' "$secondary_ids" | jq -e --argjson sid "$target_sp_id" 'index($sid) != null' >/dev/null 2>&1; then
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_URL="$bucket_url"
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_FAMILY_ID="$family_id"
        # shellcheck disable=SC2034
        SECONDARY_BUCKET_SECONDARY_IDS="$secondary_ids"
        return 0
      fi

      exec_moca_cmd bucket rm "$bucket_url" >/dev/null 2>&1 || true
    done
  done <<EOF
$candidate_operators
EOF

  echo "FAIL: could not create an auxiliary bucket whose GVG uses target SP ${target_sp_id} as secondary"
  return 1
}
