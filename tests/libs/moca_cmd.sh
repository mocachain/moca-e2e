#!/usr/bin/env bash
# moca-cmd helpers for E2E tests.

# MOCA_CMD_HOME: keystore home for moca-cmd (separate from mocad keyring)
# MOCA_CMD_PASSWORD_FILE: password file for the keystore
MOCA_CMD_HOME="${MOCA_CMD_HOME:-}"
MOCA_CMD_PASSWORD_FILE="${MOCA_CMD_PASSWORD_FILE:-}"
MOCA_CMD_BIN="${MOCA_CMD_BIN:-}"

resolve_moca_cmd() {
  # The docker moca-cmd sidecar (see PR that adds it) is keyed to local validator-0
  # and the localnet testaccount. Never use it against remote networks — its keystore
  # + config only match ENV=local.
  if [ "${ENV:-local}" = "local" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moca-cmd$'; then
    echo "docker:moca-cmd"
    return 0
  fi
  if [ -n "$MOCA_CMD_BIN" ] && [ -x "$MOCA_CMD_BIN" ]; then
    echo "local:$MOCA_CMD_BIN"
    return 0
  fi
  if command -v moca-cmd >/dev/null 2>&1; then
    echo "local:moca-cmd"
    return 0
  fi
  return 1
}

# exec_moca_cmd: run moca-cmd with network flags (read-only queries, no signing).
# -p is safe to pass unconditionally: moca-cmd only reads the password file when
# IsQueryCmd=false (see client_moca.go NewClient); queries skip parseKeystore.
exec_moca_cmd() {
  local target bin
  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    local container="${target#docker:}"
    docker exec "$container" moca-cmd -p /root/.moca-cmd/password.txt "$@" 2>/dev/null
    return $?
  fi
  bin="${target#local:}"
  local net_args=()
  if [ "${ENV:-local}" != "local" ]; then
    [ -n "${RPC:-}" ] && net_args+=(--rpcAddr "$RPC")
    [ -n "${CHAIN_ID:-}" ] && net_args+=(--chainId "$CHAIN_ID")
    [ -n "${EVM_RPC:-}" ] && net_args+=(--evmRpcAddr "$EVM_RPC")
  fi
  [ -n "$MOCA_CMD_HOME" ] && net_args+=(--home "$MOCA_CMD_HOME")
  [ -n "$MOCA_CMD_PASSWORD_FILE" ] && net_args+=(-p "$MOCA_CMD_PASSWORD_FILE")
  "$bin" "${net_args[@]}" "$@" 2>/dev/null
}

# exec_moca_cmd_signed: run moca-cmd with network flags + keystore (for write operations)
# IMPORTANT: do NOT pass --host — moca-cmd resolves SP endpoints from chain automatically
exec_moca_cmd_signed() {
  local target bin
  target="$(resolve_moca_cmd 2>/dev/null)" || return 127
  if [[ "$target" == docker:* ]]; then
    local container="${target#docker:}"
    docker exec "$container" moca-cmd -p /root/.moca-cmd/password.txt "$@" 2>/dev/null
    return $?
  fi
  bin="${target#local:}"
  local args=()
  if [ "${ENV:-local}" != "local" ]; then
    [ -n "${RPC:-}" ] && args+=(--rpcAddr "$RPC")
    [ -n "${CHAIN_ID:-}" ] && args+=(--chainId "$CHAIN_ID")
    [ -n "${EVM_RPC:-}" ] && args+=(--evmRpcAddr "$EVM_RPC")
  fi
  [ -n "$MOCA_CMD_HOME" ] && args+=(--home "$MOCA_CMD_HOME")
  [ -n "$MOCA_CMD_PASSWORD_FILE" ] && args+=(-p "$MOCA_CMD_PASSWORD_FILE")
  "$bin" "${args[@]}" "$@" 2>/dev/null
}

# moca_cmd_tx: signed call that additionally waits for the sender's mempool
# to drain before returning. Prevents nonce-race on back-to-back signed calls
# (moca-cmd queries Cosmos auth sequence at "latest", which lags pending txs;
# some ops — like `bucket create --tags=…` — also emit an extra implicit tx
# whose hash isn't printed, so a plain-hash wait misses it).
#
# Echoes moca-cmd output to stdout, returns moca-cmd's rc. Sets rc=1 if
# mempool didn't drain in 5s (chain stuck / tx got dropped) or, when
# CHECK_TX_STATUS=1, the tx receipt shows status=0x0.
moca_cmd_tx() {
  local out rc hash status
  out=$(exec_moca_cmd_signed "$@")
  rc=$?
  hash=$(extract_evm_tx_hash "$out")
  if [ -n "$hash" ]; then
    if ! wait_for_evm_tx "$hash" 5 >/dev/null 2>&1; then
      echo "  ERROR: wait_for_evm_tx timed out waiting for mempool to drain after $hash" >&2
      rc=1
    fi
    if [ "${CHECK_TX_STATUS:-0}" = "1" ]; then
      status=$(curl -sf -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_getTransactionReceipt","params":["'"$hash"'"]}' \
        "${EVM_RPC:-http://localhost:8545}" 2>/dev/null | jq -r '.result.status // empty' 2>/dev/null)
      if [ "$status" = "0x0" ]; then
        echo "  ERROR: tx $hash REVERTED on-chain (status=0x0)" >&2
        rc=1
      fi
    fi
  fi
  printf '%s\n' "$out"
  return $rc
}
