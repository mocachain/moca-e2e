#!/usr/bin/env bash
# Storage-oriented test helpers.

# wait_for_object_sealed: poll `moca-cmd object head <path>` until status reaches
# OBJECT_STATUS_SEALED or timeout.
#
# Not needed for the default `object put` flow — moca-cmd already waits for
# SEALED internally (cmd/cmd_object.go:808, 1h timeout). This helper is for
# callers that used --bypassSeal or need to verify an existing object's state.
#
# Timeout precedence: explicit 2nd arg > SEAL_TIMEOUT_SECONDS env > default 120.
#
# Usage: wait_for_object_sealed "$bucket/$object" [timeout_seconds]
# Returns 0 on SEALED, 1 on timeout. Prints status on failure.
wait_for_object_sealed() {
  local path="${1:?object path required}"
  local timeout="${2:-${SEAL_TIMEOUT_SECONDS:-120}}"
  local status deadline now
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    status=$(exec_moca_cmd object head "$path" 2>/dev/null | grep -oE 'object_status: OBJECT_STATUS_[A-Z_]+' | head -1)
    case "$status" in
      *OBJECT_STATUS_SEALED*) return 0 ;;
    esac
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_object_sealed: timeout after ${timeout}s; last status: ${status:-unknown}" >&2
      return 1
    fi
    sleep 3
  done
}

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
  local target
  if [ -r "$path" ]; then
    sha256_file "$path"
    return 0
  fi

  target="$(resolve_moca_cmd 2>/dev/null || true)"
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" sh -lc '
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
  local target
  rm -f "$path" >/dev/null 2>&1 || true

  target="$(resolve_moca_cmd 2>/dev/null || true)"
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" rm -f "$path" >/dev/null 2>&1 || true
    rm -f "$path" >/dev/null 2>&1 || true
  fi
}

timed_object_get() {
  local timeout_seconds="${1:?timeout seconds required}"
  shift
  local target

  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    docker exec "${target#docker:}" sh -lc '
      timeout="$1"
      shift
      exec timeout "$timeout" moca-cmd -p /root/.moca-cmd/password.txt "$@"
    ' sh "$timeout_seconds" "$@" 2>/dev/null
    return $?
  fi

  exec_moca_cmd_signed "$@"
}

generate_bucket_name() {
  local prefix="${1:-e2e-bucket}"
  echo "${prefix}-$(date +%s)-${RANDOM}"
}

generate_group_name() {
  local prefix="${1:-e2e-group}"
  echo "${prefix}-$(date +%s)-$$"
}

generate_object_name() {
  local prefix="${1:-obj}"
  local ext="${2:-.txt}"
  echo "${prefix}-$(date +%s)${ext}"
}

create_test_file() {
  local path="${1:-/tmp/e2e-test-$(date +%s).txt}"
  local content="${2:-e2e test content $(date)}"
  echo "$content" > "$path"
  echo "$path"
}

get_default_tags() {
  echo '[{"key":"key1","value":"value1"},{"key":"key2","value":"value2"}]'
}

get_updated_tags() {
  echo '[{"key":"key3","value":"value3"}]'
}

wait_for_object_visible() {
  local bucket_url="${1:?bucket url required}"
  local object_name="${2:?object name required}"
  local timeout="${3:-120}"
  local deadline now out

  deadline=$(( $(date +%s) + timeout ))
  while :; do
    out="$(exec_moca_cmd object ls "$bucket_url" 2>/dev/null || true)"
    if echo "$out" | grep -q "$object_name"; then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "  wait_for_object_visible: timeout after ${timeout}s" >&2
      return 1
    fi
    sleep 3
  done
}
