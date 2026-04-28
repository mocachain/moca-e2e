#!/usr/bin/env bash
# E2E: manual object failover after the primary SP is forced to exit and its endpoint becomes unavailable.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" != "local" ]; then
  echo "SKIP: storage object failover test is local-only"
  exit 0
fi

require_write_enabled "storage object failover test"

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd required for object get failover"
  exit 0
fi
MOCA_CMD_TARGET="$(resolve_moca_cmd 2>/dev/null || true)"

SP_CHECK="$(exec_mocad query sp storage-providers --node "$TM_RPC" --output json 2>/dev/null || echo "")"
NUM_SPS="$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")"
NUM_SPS="${NUM_SPS:-0}"
if [ "$NUM_SPS" -lt 3 ]; then
  echo "SKIP: object failover needs primary + successors (have ${NUM_SPS} SPs)"
  exit 0
fi

IN_SERVICE_SP_COUNT="$(printf '%s\n' "$SP_CHECK" | jq -r '[.sps[] | select(.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0")] | length' 2>/dev/null || echo "0")"
if [ "${IN_SERVICE_SP_COUNT:-0}" -lt 7 ]; then
  echo "SKIP: manual object failover test needs 7 IN_SERVICE SPs to create a fresh family on local stack (have ${IN_SERVICE_SP_COUNT:-0})"
  exit 0
fi

PRIMARY_SP_CONTAINER="sp-0"
PRIMARY_SP_EXPECTED_ENDPOINT="http://${PRIMARY_SP_CONTAINER}:9033"
PRIMARY_SP="$(printf '%s\n' "$SP_CHECK" | jq -r --arg primary_container "$PRIMARY_SP_CONTAINER" --arg expected_endpoint "$PRIMARY_SP_EXPECTED_ENDPOINT" '.sps[] | select((.status == "STATUS_IN_SERVICE" or .status == 0 or .status == "0") and ((.description.moniker // "") == $primary_container or (.endpoint // "") == $expected_endpoint)) | .operator_address' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP" ] || [ "$PRIMARY_SP" = "null" ]; then
  echo "SKIP: cannot resolve operator for local primary SP container ${PRIMARY_SP_CONTAINER}"
  exit 0
fi

PRIMARY_SP_ID="$(printf '%s\n' "$SP_CHECK" | jq -r --arg primary_operator "$PRIMARY_SP" '.sps[] | select(.operator_address == $primary_operator) | .id' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP_ID" ] || [ "$PRIMARY_SP_ID" = "null" ]; then
  echo "SKIP: cannot resolve SP ID for local primary SP container ${PRIMARY_SP_CONTAINER}"
  exit 0
fi

PRIMARY_SP_ENDPOINT="$(printf '%s\n' "$SP_CHECK" | jq -r --arg primary_operator "$PRIMARY_SP" '.sps[] | select(.operator_address == $primary_operator) | .endpoint' 2>/dev/null | head -1)"
if [ -z "$PRIMARY_SP_ENDPOINT" ] || [ "$PRIMARY_SP_ENDPOINT" = "null" ]; then
  echo "SKIP: cannot resolve endpoint for local primary SP container ${PRIMARY_SP_CONTAINER}"
  exit 0
fi

PRIMARY_STATUS="$(get_sp_status_by_operator "$PRIMARY_SP")"
if [ "$PRIMARY_STATUS" != "STATUS_IN_SERVICE" ] && [ "$PRIMARY_STATUS" != "0" ]; then
  echo "SKIP: local primary SP ${PRIMARY_SP_CONTAINER} is not IN_SERVICE (status=${PRIMARY_STATUS:-unknown})"
  exit 0
fi

sha256_file() {
  local path="${1:?path required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  shasum -a 256 "$path" | awk '{print $1}'
}

sha256_file_docker_aware() {
  local path="${1:?path required}"
  if [ -r "$path" ]; then
    sha256_file "$path"
    return 0
  fi
  if [[ "$MOCA_CMD_TARGET" == docker:* ]]; then
    docker exec "${MOCA_CMD_TARGET#docker:}" sh -lc '
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk "{print \$1}"
      else
        shasum -a 256 "$1" | awk "{print \$1}"
      fi
    ' sh "$path" 2>/dev/null
    return $?
  fi
  return 1
}

remove_file_docker_aware() {
  local path="${1:?path required}"
  rm -f "$path" >/dev/null 2>&1 || true
  if [ -e "$path" ] && [[ "$MOCA_CMD_TARGET" == docker:* ]]; then
    docker exec "${MOCA_CMD_TARGET#docker:}" rm -f "$path" >/dev/null 2>&1 || true
    rm -f "$path" >/dev/null 2>&1 || true
  fi
}

timed_object_get() {
  local timeout_seconds="${1:?timeout seconds required}"
  shift

  if [[ "$MOCA_CMD_TARGET" == docker:* ]]; then
    local container="${MOCA_CMD_TARGET#docker:}"
    docker exec "$container" sh -lc '
      timeout="$1"
      shift
      exec timeout "$timeout" moca-cmd -p /root/.moca-cmd/password.txt "$@"
    ' sh "$timeout_seconds" "$@" 2>/dev/null
    return $?
  fi

  exec_moca_cmd_signed "$@"
}

exec_validator_mocad() {
  local validator_index="${1:?validator index required}"
  shift
  docker exec "validator-${validator_index}" mocad "$@" --home /root/.mocad 2>/dev/null
}

current_proposal_count() {
  exec_mocad query gov proposals --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.proposals | length // 0' 2>/dev/null || echo "0"
}

latest_proposal_id() {
  exec_mocad query gov proposals --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.proposals[-1].id // .proposals[-1].proposal_id // empty' 2>/dev/null || true
}

gov_module_authority() {
  local authority

  authority="$(exec_mocad query auth module-account gov --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.account.base_account.address // .account.value.address // empty' 2>/dev/null || true)"
  if [ -n "$authority" ]; then
    printf '%s\n' "$authority"
    return 0
  fi

  authority="$(exec_mocad query auth module-accounts --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.accounts[]? | select(.name == "gov") | .base_account.address // .value.address // empty' 2>/dev/null || true)"
  if [ -n "$authority" ]; then
    printf '%s\n' "$authority"
    return 0
  fi

  return 1
}

gov_min_deposit() {
  local gov_params amount denom

  gov_params="$(exec_mocad query gov params --node "$TM_RPC" --output json 2>/dev/null || echo '{}')"
  amount="$(printf '%s\n' "$gov_params" | jq -r '.params.min_deposit[0].amount // .deposit_params.min_deposit[0].amount // empty' 2>/dev/null || true)"
  denom="$(printf '%s\n' "$gov_params" | jq -r '.params.min_deposit[0].denom // .deposit_params.min_deposit[0].denom // empty' 2>/dev/null || true)"
  if [ -z "$amount" ] || [ -z "$denom" ]; then
    return 1
  fi

  printf '%s%s\n' "$amount" "$denom"
}

wait_for_proposal_status() {
  local proposal_id="${1:?proposal id required}"
  local expected_status="${2:?expected status required}"
  local timeout="${3:-60}"
  local deadline now current

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(exec_mocad query gov proposal "$proposal_id" --node "$TM_RPC" --output json 2>/dev/null \
      | jq -r '.proposal.status // empty' 2>/dev/null || true)"
    if [ "$current" = "$expected_status" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_proposal_status: timeout after ${timeout}s; proposal ${proposal_id} status=${current:-unknown}" >&2
      return 1
    fi
    sleep 2
  done
}

submit_forced_exit_proposal() {
  local target_operator="${1:?target operator required}"
  local gov_authority deposit before_count after_count proposal_id submit_out tmpfile validator_count validator_name vote_out
  local proposal_json=""

  gov_authority="$(gov_module_authority || true)"
  if [ -z "$gov_authority" ]; then
    echo "FAIL: could not determine gov module authority"
    exit 1
  fi

  deposit="$(gov_min_deposit || true)"
  if [ -z "$deposit" ]; then
    echo "FAIL: could not determine governance min deposit"
    exit 1
  fi

  before_count="$(current_proposal_count)"
  tmpfile="/tmp/forced-exit-proposal-${PRIMARY_SP_CONTAINER}.json"
  proposal_json=$(cat <<EOF
{
  "messages": [
    {
      "@type": "/moca.virtualgroup.MsgStorageProviderForcedExit",
      "authority": "${gov_authority}",
      "storageProvider": "${target_operator}"
    }
  ],
  "deposit": "${deposit}",
  "title": "E2E forced exit for ${PRIMARY_SP_CONTAINER}",
  "summary": "Force ${PRIMARY_SP_CONTAINER} to exit before manual object failover"
}
EOF
)

  printf '%s\n' "$proposal_json" | docker exec -i validator-0 sh -lc "cat > ${tmpfile}"
  submit_out="$(exec_validator_mocad 0 tx gov submit-proposal "${tmpfile}" \
    --from validator0 \
    --keyring-backend test \
    --chain-id "$CHAIN_ID" \
    --node tcp://localhost:26657 \
    --fees "$FEES" \
    -y 2>&1 || true)"
  echo "$submit_out"
  sleep 5

  after_count="$(current_proposal_count)"
  if [ "$after_count" -le "$before_count" ] 2>/dev/null; then
    echo "FAIL: forced-exit proposal was not created"
    exit 1
  fi

  proposal_id="$(latest_proposal_id)"
  if [ -z "$proposal_id" ]; then
    echo "FAIL: could not resolve forced-exit proposal id"
    exit 1
  fi
  print_success "forced-exit proposal created (id=${proposal_id})"

  validator_count="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ec '^validator-[0-9]+$')"
  if [ -z "$validator_count" ] || [ "$validator_count" -eq 0 ] 2>/dev/null; then
    echo "FAIL: could not find validator containers to vote on proposal ${proposal_id}"
    exit 1
  fi

  for validator_name in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^validator-[0-9]+$' | sort -V); do
    vote_out="$(docker exec "$validator_name" mocad tx gov vote "$proposal_id" yes \
      --from "validator${validator_name#validator-}" \
      --keyring-backend test \
      --chain-id "$CHAIN_ID" \
      --node tcp://localhost:26657 \
      --fees "$FEES" \
      --home /root/.mocad \
      -y 2>&1 || true)"
    echo "$vote_out"
  done

  if ! wait_for_proposal_status "$proposal_id" "PROPOSAL_STATUS_PASSED" 60; then
    echo "FAIL: forced-exit proposal ${proposal_id} did not pass"
    exit 1
  fi
  print_success "forced-exit proposal passed"
}

extract_evm_tx_hash_from_output() {
  printf '%s\n' "${1:-}" | grep -oE '0x[0-9a-fA-F]{64}' | head -1
}

wait_for_evm_receipt_status() {
  local tx_hash="${1:?tx hash required}"
  local timeout="${2:-30}"
  local deadline now receipt status

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    receipt="$(_evm_rpc eth_getTransactionReceipt "[\"$tx_hash\"]")"
    if [ -n "$receipt" ] && [ "$receipt" != "null" ]; then
      status="$(printf '%s\n' "$receipt" | jq -r '.status // empty' 2>/dev/null || true)"
      if [ -n "$status" ]; then
        printf '%s\n' "$status"
        return 0
      fi
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    sleep 1
  done
}

require_sp_tx_success() {
  local step_name="${1:?step name required}"
  local cmd_output="${2:-}"
  local tx_hash receipt_status

  tx_hash="$(extract_evm_tx_hash_from_output "$cmd_output")"
  if [ -z "$tx_hash" ]; then
    echo "$cmd_output"
    echo "FAIL: ${step_name} did not emit a transaction hash"
    exit 1
  fi

  receipt_status="$(wait_for_evm_receipt_status "$tx_hash" 30 || true)"
  if [ -z "$receipt_status" ]; then
    echo "$cmd_output"
    echo "FAIL: ${step_name} tx ${tx_hash} did not produce a receipt in time"
    exit 1
  fi
  if [ "$receipt_status" != "0x1" ]; then
    echo "$cmd_output"
    echo "FAIL: ${step_name} tx ${tx_hash} reverted on-chain (status=${receipt_status})"
    exit 1
  fi
}

gvg_primary_sp_id_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '.global_virtual_groups[0].primary_sp_id // empty' 2>/dev/null || true
}

gvg_json_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-by-family-id "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null || echo '{}'
}

gvg_secondary_sp_ids_by_family() {
  local family_id="${1:?family id required}"
  gvg_json_by_family "$family_id" \
    | jq -r '.global_virtual_groups[0].secondary_sp_ids[]? // empty' 2>/dev/null || true
}

gvg_count_by_family() {
  local family_id="${1:?family id required}"
  exec_mocad query virtualgroup global-virtual-group-family "$family_id" \
    --node "$TM_RPC" --output json 2>/dev/null \
    | jq -r '(.global_virtual_group_family.global_virtual_group_ids // []) | length' 2>/dev/null || echo "0"
}

sp_moniker_by_id() {
  local sp_id="${1:?sp id required}"
  printf '%s\n' "$SP_CHECK" | jq -r --argjson sid "$sp_id" '.sps[] | select(.id == $sid) | (.description.moniker // empty)' 2>/dev/null | head -1
}

sp_operator_by_id() {
  local sp_id="${1:?sp id required}"
  printf '%s\n' "$SP_CHECK" | jq -r --argjson sid "$sp_id" '.sps[] | select(.id == $sid) | .operator_address' 2>/dev/null | head -1
}

sp_container_by_id() {
  local sp_id="${1:?sp id required}"
  local moniker

  moniker="$(sp_moniker_by_id "$sp_id")"
  if [[ "$moniker" =~ ^sp-[0-9]+$ ]]; then
    printf '%s\n' "$moniker"
    return 0
  fi

  if [ "$sp_id" -gt 0 ] 2>/dev/null; then
    printf 'sp-%s\n' "$((sp_id - 1))"
    return 0
  fi

  return 1
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

run_successor_swap_cmd() {
  local container="${1:?container required}"
  shift
  docker exec "$container" moca-sp "$@" 2>&1 || true
}

PRIMARY_PAUSED=0
BUCKET_NAME="$(generate_bucket_name "e2e-obj-failover")"
BUCKET_URL="moca://${BUCKET_NAME}"
OBJECT_NAME="failover-object.txt"
OBJECT_URL="${BUCKET_URL}/${OBJECT_NAME}"
SOURCE_FILE="$(create_test_file "/tmp/${BUCKET_NAME}-${OBJECT_NAME}" "storage failover $(date)")"
DOWNLOAD_FILE="/tmp/${BUCKET_NAME}-${OBJECT_NAME}.downloaded"
PRIMARY_ONLY_DOWNLOAD_FILE="/tmp/${BUCKET_NAME}-${OBJECT_NAME}.primary-only"

cleanup() {
  if [ "$PRIMARY_PAUSED" = "1" ]; then
    docker unpause "$PRIMARY_SP_CONTAINER" >/dev/null 2>&1 || true
    PRIMARY_PAUSED=0
  fi
  rm -f "$SOURCE_FILE" >/dev/null 2>&1 || true
  remove_file_docker_aware "$DOWNLOAD_FILE"
  remove_file_docker_aware "$PRIMARY_ONLY_DOWNLOAD_FILE"
  exec_moca_cmd_signed object rm "$OBJECT_URL" >/dev/null 2>&1 || true
  exec_moca_cmd_signed bucket rm "$BUCKET_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_test_section "Step 1: create bucket on ${PRIMARY_SP_CONTAINER}"
bucket_out="$(moca_cmd_tx bucket create --primarySP "$PRIMARY_SP" "$BUCKET_URL" || true)"
if ! echo "$bucket_out" | grep -q "make_bucket:\|$BUCKET_NAME"; then
  echo "$bucket_out"
  echo "FAIL: bucket create did not succeed"
  exit 1
fi

print_test_section "Step 2: put object and wait for OBJECT_STATUS_SEALED"
put_out="$(exec_moca_cmd_signed object put --contentType "application/octet-stream" "$SOURCE_FILE" "$OBJECT_URL" || true)"
if ! echo "$put_out" | grep -qiE "object.*created|created on chain|upload"; then
  echo "$put_out"
  echo "FAIL: object put did not reach uploaded/sealed state"
  exit 1
fi
print_success "object put completed (SEALED)"

print_test_section "Step 3: record pre-failover family ownership"
before_bucket_head="$(exec_moca_cmd bucket head "$BUCKET_URL" 2>&1 || true)"
if ! echo "$before_bucket_head" | grep -q "bucket_name:\"$BUCKET_NAME\""; then
  echo "$before_bucket_head"
  echo "FAIL: bucket head did not return the created bucket"
  exit 1
fi

BUCKET_FAMILY_ID="$(printf '%s\n' "$before_bucket_head" | awk -F': ' '/^virtual_group_family_id:/ {print $2; exit}')"
BEFORE_PRIMARY_SP_ID="$(printf '%s\n' "$before_bucket_head" | awk -F': ' '/^primary SP ID:/ {print $2; exit}')"
if [ -z "$BUCKET_FAMILY_ID" ] || [ -z "$BEFORE_PRIMARY_SP_ID" ]; then
  echo "$before_bucket_head"
  echo "FAIL: could not resolve bucket family ID / primary SP ID before failover"
  exit 1
fi
assert_eq "$BEFORE_PRIMARY_SP_ID" "$PRIMARY_SP_ID" "bucket primary SP ID matches target SP before failover"

GVG_COUNT="$(gvg_count_by_family "$BUCKET_FAMILY_ID")"
SUCCESSOR_SP_ID=""
while IFS= read -r candidate_sp_id; do
  [ -n "$candidate_sp_id" ] || continue
  SUCCESSOR_CONTAINER="$(sp_container_by_id "$candidate_sp_id" || true)"
  [ -n "$SUCCESSOR_CONTAINER" ] || continue
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SUCCESSOR_CONTAINER}$"; then
    SUCCESSOR_SP_ID="$candidate_sp_id"
    break
  fi
done <<EOF
$(gvg_secondary_sp_ids_by_family "$BUCKET_FAMILY_ID")
EOF

if [ -z "$SUCCESSOR_SP_ID" ]; then
  echo "FAIL: could not find a running successor SP in family ${BUCKET_FAMILY_ID}"
  exit 1
fi

SUCCESSOR_CONTAINER="$(sp_container_by_id "$SUCCESSOR_SP_ID")"
SUCCESSOR_OPERATOR="$(sp_operator_by_id "$SUCCESSOR_SP_ID")"
if [ -z "$SUCCESSOR_OPERATOR" ] || [ "$SUCCESSOR_OPERATOR" = "null" ]; then
  echo "FAIL: could not resolve successor operator for SP ID ${SUCCESSOR_SP_ID}"
  exit 1
fi
print_success "selected successor ${SUCCESSOR_CONTAINER} (sp_id=${SUCCESSOR_SP_ID}) for manual failover"

print_test_section "Step 4: force the primary SP into on-chain exiting status"
submit_forced_exit_proposal "$PRIMARY_SP"
if ! wait_for_sp_status "$PRIMARY_SP" "STATUS_FORCED_EXITING" 180; then
  echo "FAIL: primary SP never entered STATUS_FORCED_EXITING"
  exit 1
fi
print_success "primary SP entered STATUS_FORCED_EXITING"

print_test_section "Step 5: pause primary SP container"
docker pause "$PRIMARY_SP_CONTAINER" >/dev/null
PRIMARY_PAUSED=1
sleep 3
print_success "primary container paused"

print_test_section "Step 6: verify forced primary endpoint is unavailable"
remove_file_docker_aware "$PRIMARY_ONLY_DOWNLOAD_FILE"
if primary_get_out="$(timed_object_get 20 object get --spEndpoint "$PRIMARY_SP_ENDPOINT" "$OBJECT_URL" "$PRIMARY_ONLY_DOWNLOAD_FILE")"; then
  echo "$primary_get_out"
  echo "FAIL: object get unexpectedly succeeded when forced to use paused primary endpoint ${PRIMARY_SP_ENDPOINT}"
  exit 1
fi
remove_file_docker_aware "$PRIMARY_ONLY_DOWNLOAD_FILE"
print_success "forced primary endpoint download failed as expected"

print_test_section "Step 7: manually reserve swap-in on successor"
swapin_out="$(run_successor_swap_cmd "$SUCCESSOR_CONTAINER" swapIn --config /root/.moca-sp/config.toml --vgf "$BUCKET_FAMILY_ID" --gvgId 0 --targetSP "$PRIMARY_SP_ID")"
echo "$swapin_out"
require_sp_tx_success "swapIn" "$swapin_out"

if [ "$GVG_COUNT" != "0" ]; then
  print_test_section "Step 8: recover family on successor"
  recover_out="$(run_successor_swap_cmd "$SUCCESSOR_CONTAINER" recover-vgf --config /root/.moca-sp/config.toml --vgf "$BUCKET_FAMILY_ID")"
  echo "$recover_out"
  if printf '%s\n' "$recover_out" | grep -qiE 'panic|fatal|error'; then
    echo "FAIL: recover-vgf reported an error"
    exit 1
  fi
else
  print_test_section "Step 8: skip recover-vgf for empty family"
  print_success "family ${BUCKET_FAMILY_ID} has no GVGs; recover-vgf not needed"
fi

print_test_section "Step 9: complete swap-in on successor"
complete_swapin_out="$(run_successor_swap_cmd "$SUCCESSOR_CONTAINER" completeSwapIn --config /root/.moca-sp/config.toml --vgf "$BUCKET_FAMILY_ID" --gvgId 0)"
echo "$complete_swapin_out"
require_sp_tx_success "completeSwapIn" "$complete_swapin_out"

print_test_section "Step 10: wait for family primary to switch to successor"
NEW_PRIMARY_SP_ID="$(wait_for_gvg_primary_sp_change "$BUCKET_FAMILY_ID" "$BEFORE_PRIMARY_SP_ID" 180)"
assert_eq "$NEW_PRIMARY_SP_ID" "$SUCCESSOR_SP_ID" "family primary switched to the selected successor SP"

print_test_section "Step 11: verify object get succeeds after manual failover"
remove_file_docker_aware "$DOWNLOAD_FILE"
get_out="$(timed_object_get 60 object get "$OBJECT_URL" "$DOWNLOAD_FILE" || true)"
if [ ! -f "$DOWNLOAD_FILE" ]; then
  echo "$get_out"
  echo "FAIL: object get did not produce a downloaded file after manual failover"
  exit 1
fi

SOURCE_SHA="$(sha256_file "$SOURCE_FILE")"
DOWNLOAD_SHA="$(sha256_file_docker_aware "$DOWNLOAD_FILE" || true)"
assert_eq "$DOWNLOAD_SHA" "$SOURCE_SHA" "downloaded object matches original sha256"

print_test_section "Step 12: resume original primary container"
docker unpause "$PRIMARY_SP_CONTAINER" >/dev/null
PRIMARY_PAUSED=0
print_success "primary container resumed"

trap - EXIT
cleanup
echo "PASS: storage object manual failover test completed"
