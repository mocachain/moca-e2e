#!/usr/bin/env bash
# E2E test: the standard Ethereum precompiles (0x01-0x11) are reachable on a
# running node, and the bank module refuses to send funds to their addresses.
#
# moca builds its own EVM precompile map. cosmos/evm resolves every call target
# through that map and expects the standard set to be in it, so if the map only
# holds moca's own precompiles every call to ecrecover/sha256/... fails with
# "precompiled contract not stored in memory" (mocachain/moca#555). The unit
# tests cover the keeper; this test covers the JSON-RPC and tx path on a node.
#
# Sections:
#   1. eth_call to 0x01-0x05 with fixed vectors (every env, no key needed)
#   2. eth_call to the Prague BLS precompiles (only on cosmos/evm-based moca,
#      whose chain config enables Prague; v1.x evmos-based nodes expose Berlin)
#   3. a tx to 0x02 mines with status 1, and a contract reaches sha256 and
#      ecrecover from inside its own execution (needs cast + test key)
#   4. bank send to a standard precompile address is rejected
#
# Expected outputs were produced with go-ethereum's vm.PrecompiledContractsPrague
# (the implementation cosmos/evm executes) and cross-checked against devnet-2.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libs/core.sh
source "$SCRIPT_DIR/libs/core.sh"
# shellcheck source=libs/assertions.sh
source "$SCRIPT_DIR/libs/assertions.sh"

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# --- Fixed vectors --------------------------------------------------------
HELLO=0x68656c6c6f # "hello"
SHA256_HELLO=0x2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
RIPEMD160_HELLO=0x000000000000000000000000108f07b8382412612c048d07d13f814118445acd
# modexp: base_len=1, exp_len=1, mod_len=1, 3^2 mod 5 = 4
MODEXP_IN=0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001030205
MODEXP_OUT=0x04
# ecrecover: keccak256("hello") signed by the key 0x4c0883a6...2318 (a
# throwaway vector key, never funded). Input = hash || v || r || s.
EC_HASH=0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
EC_V=28
EC_R=0xbc81bfc04b658485b9820cf4fac760c84f0fc628da21c9e64ed8aaede215e633
EC_S=0x76cc1bfb23f9869c5b71a4069b48fce3ab0caaebc6bfb7a81cb12ac3b9b2f7b1
EC_SIGNER=0x2c7536e3605d9c16a7a3d7b1898e529396a65c23
ECRECOVER_IN="${EC_HASH}000000000000000000000000000000000000000000000000000000000000001c${EC_R#0x}${EC_S#0x}"
ECRECOVER_OUT=0x000000000000000000000000${EC_SIGNER#0x}
# EIP-2537 BLS12-381 G1ADD / G2ADD: infinity + infinity = infinity. The point
# at infinity is all-zero, so the output is 128 (G1) / 256 (G2) zero bytes.
# An *empty account* at the same address returns "0x", which keeps this
# vector from passing on a chain where the precompile is simply absent.
zeros() { printf '%0*d' "$(( $1 * 2 ))" 0; } # <n> bytes of zero, hex
G1ADD_IN="0x$(zeros 256)"
G1ADD_OUT="0x$(zeros 128)"
G2ADD_IN="0x$(zeros 512)"
G2ADD_OUT="0x$(zeros 256)"

precompile_addr() { printf '0x%040x' "$1"; }

# eth_call_to <addr> <data>: prints the hex result, or "ERROR: <message>".
eth_call_to() {
  local to="$1" data="$2" resp
  resp=$(curl -sf -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"${to}\",\"data\":\"${data}\"},\"latest\"]}" \
    "$EVM_RPC" 2>/dev/null) || { echo "ERROR: eth_call request failed"; return 0; }
  if [ "$(echo "$resp" | jq -r 'has("error")')" = "true" ]; then
    echo "ERROR: $(echo "$resp" | jq -r '.error.message // .error')"
  else
    echo "$resp" | jq -r '.result // "null"' | tr 'A-F' 'a-f'
  fi
}

check_call() {
  local name="$1" idx="$2" data="$3" expected="$4" addr got
  addr=$(precompile_addr "$idx")
  got=$(eth_call_to "$addr" "$data")
  if [ "$got" = "$(echo "$expected" | tr 'A-F' 'a-f')" ]; then
    echo "  OK: ${name} (${addr}) returned the expected output"
  else
    fail "${name} (${addr}): got '${got}', expected '${expected}'"
  fi
}

# --- Which standard set does this chain enable? ----------------------------
# cosmos/evm-based moca (v2+) serves /cosmos/evm/vm/v1/params and runs on
# cosmos/evm's default chain config, which enables every fork through Prague
# at genesis (the chain config is app-level there, not a param). evmos-based
# v1.x serves /evmos/evm/v1/params instead and only wires Berlin (0x01-0x09).
PRAGUE_EXPECTED=0
if curl -sf "${REST}/cosmos/evm/vm/v1/params" >/dev/null 2>&1; then
  PRAGUE_EXPECTED=1
  echo "  EVM: cosmos/evm (Prague precompiles 0x0a-0x11 expected)"
else
  echo "  EVM: evmos-based (no /cosmos/evm/vm/v1/params), Berlin precompiles only"
fi

print_test_section "Standard precompiles via eth_call (0x01-0x05)"
check_call ecrecover 1 "$ECRECOVER_IN" "$ECRECOVER_OUT"
check_call sha256 2 "$HELLO" "$SHA256_HELLO"
check_call ripemd160 3 "$HELLO" "$RIPEMD160_HELLO"
check_call identity 4 "$HELLO" "$HELLO"
check_call modexp 5 "$MODEXP_IN" "$MODEXP_OUT"

print_test_section "Prague precompiles via eth_call (0x0b, 0x0d)"
if [ "$PRAGUE_EXPECTED" = "1" ]; then
  check_call bls12_g1add 11 "$G1ADD_IN" "$G1ADD_OUT"
  check_call bls12_g2add 13 "$G2ADD_IN" "$G2ADD_OUT"
else
  echo "  NOTE: chain does not enable Prague; 0x0a-0x11 not checked"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: ${FAILURES} precompile call(s) returned the wrong result"
  exit 1
fi

# --- Write path: tx to a precompile + contract-routed calls -----------------
require_write_enabled "EVM precompile write test"
require_test_key

if ! command -v cast &>/dev/null; then
  skip "cast (Foundry) not installed"
fi

# Private key: from metadata (local), the validator container, or the keyring.
PRIVKEY=""
METADATA="$(dirname "$SCRIPT_DIR")/test-results/metadata.json"
if [ -f "$METADATA" ]; then
  PRIVKEY=$(jq -r '.test_account.evm_privkey // empty' "$METADATA" 2>/dev/null || echo "")
fi
if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  PRIVKEY=$(docker exec "$VALIDATOR_CONTAINER" cat /shared/metadata.json 2>/dev/null | jq -r '.test_account.evm_privkey // empty' 2>/dev/null || echo "")
fi
if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  PRIVKEY=$(exec_mocad keys unsafe-export-eth-key "$TEST_KEY" --keyring-backend test 2>/dev/null || echo "")
fi
if [ -z "$PRIVKEY" ] || [ "$PRIVKEY" = "null" ]; then
  skip "cannot export private key for $TEST_KEY"
fi
PRIVKEY="0x${PRIVKEY#0x}"
SENDER=$(cast wallet address "$PRIVKEY")
echo "  Sender: $SENDER"

print_test_section "Transaction to the sha256 precompile mines"
SEND_OUT=$(evm_tx "$(precompile_addr 2)" "$HELLO" --value 0 \
  --private-key "$PRIVKEY" --rpc-url "$EVM_RPC" --chain-id "$EVM_CHAIN_ID" --json) || {
  echo "  FAIL: cast send to 0x02 failed: $SEND_OUT"
  exit 1
}
TX_HASH=$(echo "$SEND_OUT" | jq -r '.transactionHash // empty')
[ -n "$TX_HASH" ] || { echo "  FAIL: no tx hash: $SEND_OUT"; exit 1; }
wait_for_evm_tx "$TX_HASH" 15 || { echo "  FAIL: tx $TX_HASH not mined within 15s"; exit 1; }
STATUS=$(cast receipt "$TX_HASH" --rpc-url "$EVM_RPC" --json | jq -r '.status')
assert_eq "$STATUS" "0x1" "tx to sha256 precompile succeeded" || exit 1

print_test_section "Contract-routed calls reach sha256 and ecrecover"
# PrecompileForwarder, solc 0.7.6, optimizer runs=200, metadata-hash none:
#   contract PrecompileForwarder {
#       function sha256Via(bytes calldata data) external view returns (bytes32) {
#           (bool ok, bytes memory out) = address(0x02).staticcall(data);
#           require(ok, "sha256 precompile call failed");
#           return abi.decode(out, (bytes32));
#       }
#       function ecrecoverVia(bytes32 hash, uint8 v, bytes32 r, bytes32 s) external pure returns (address) {
#           return ecrecover(hash, v, r, s);
#       }
#   }
FORWARDER_BYTECODE="0x608060405234801561001057600080fd5b50610265806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c806341dfd8691461003b57806365e76bad14610089575b600080fd5b61006d6004803603608081101561005157600080fd5b5080359060ff602082013516906040810135906060013561010b565b604080516001600160a01b039092168252519081900360200190f35b6100f96004803603602081101561009f57600080fd5b8101906020810181356401000000008111156100ba57600080fd5b8201836020820111156100cc57600080fd5b803590602001918460018302840111640100000000831117156100ee57600080fd5b50909250905061017b565b60408051918252519081900360200190f35b600060018585858560405160008152602001604052604051808581526020018460ff1681526020018381526020018281526020019450505050506020604051602081039080840390855afa158015610167573d6000803e3d6000fd5b5050604051601f1901519695505050505050565b600080600060026001600160a01b031685856040518083838082843760405192019450600093509091505080830381855afa9150503d80600081146101dc576040519150601f19603f3d011682016040523d82523d6000602084013e6101e1565b606091505b509150915081610238576040805162461bcd60e51b815260206004820152601d60248201527f73686132353620707265636f6d70696c652063616c6c206661696c6564000000604482015290519081900360640190fd5b80806020019051602081101561024d57600080fd5b50519594505050505056fea164736f6c6343000706000a"

DEPLOY_OUT=$(evm_tx --private-key "$PRIVKEY" --rpc-url "$EVM_RPC" --chain-id "$EVM_CHAIN_ID" \
  --json --create "$FORWARDER_BYTECODE") || {
  echo "  FAIL: forwarder deployment failed: $DEPLOY_OUT"
  exit 1
}
DEPLOY_HASH=$(echo "$DEPLOY_OUT" | jq -r '.transactionHash // empty')
[ -n "$DEPLOY_HASH" ] || { echo "  FAIL: no tx hash from deployment: $DEPLOY_OUT"; exit 1; }
wait_for_evm_tx "$DEPLOY_HASH" 15 || { echo "  FAIL: deploy tx $DEPLOY_HASH not mined within 15s"; exit 1; }
FORWARDER=$(cast receipt "$DEPLOY_HASH" --rpc-url "$EVM_RPC" --json | jq -r '.contractAddress // empty')
[ -n "$FORWARDER" ] && [ "$FORWARDER" != "null" ] || { echo "  FAIL: no contract address in receipt"; exit 1; }
echo "  Forwarder deployed at: $FORWARDER"

GOT=$(cast call "$FORWARDER" "sha256Via(bytes)(bytes32)" "$HELLO" --rpc-url "$EVM_RPC" 2>&1 || true)
assert_eq "$(echo "$GOT" | tr 'A-F' 'a-f')" "$SHA256_HELLO" "sha256 via contract STATICCALL" || FAILURES=$((FAILURES + 1))

GOT=$(cast call "$FORWARDER" "ecrecoverVia(bytes32,uint8,bytes32,bytes32)(address)" \
  "$EC_HASH" "$EC_V" "$EC_R" "$EC_S" --rpc-url "$EVM_RPC" 2>&1 || true)
assert_eq "$(echo "$GOT" | tr 'A-F' 'a-f')" "$EC_SIGNER" "ecrecover via contract" || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: ${FAILURES} contract-routed precompile call(s) failed"
  exit 1
fi

# --- Bank blocklist: precompile addresses must not receive funds ------------
print_test_section "Bank refuses to send funds to precompile addresses"

# expect_bank_send_rejected <addr>: a `bank send` to addr must be refused with
# the bank module's blocklist error. A broadcast that is accepted (tx hash with
# code 0, or a mined tx) is the failure this guards against.
expect_bank_send_rejected() {
  local addr="$1" out json hash code attempt=0
  while :; do
    attempt=$((attempt + 1))
    out=$(_cosmos_broadcast bank send "$TEST_KEY" "$addr" "1${DENOM}" --from "$TEST_KEY") || true
    if printf '%s' "$out" | grep -qiE "account sequence mismatch|incorrect account sequence" && [ "$attempt" -lt 5 ]; then
      sleep 2
      continue
    fi
    break
  done
  if printf '%s' "$out" | grep -q "is not allowed to receive funds"; then
    echo "  OK: bank send to ${addr} rejected (blocked address)"
    return 0
  fi
  json=$(printf '%s\n' "$out" | grep -E '^\{' | head -1 || true)
  hash=$(printf '%s' "$json" | jq -r '.txhash // empty' 2>/dev/null || true)
  code=$(printf '%s' "$json" | jq -r '.code // empty' 2>/dev/null || true)
  if [ -n "$hash" ] && { [ -z "$code" ] || [ "$code" = "0" ]; }; then
    # Accepted at CheckTx — see whether it was also executed on-chain.
    if wait_for_cosmos_tx "$hash" 15 2>/dev/null; then
      fail "bank send to ${addr} was ACCEPTED and executed (tx ${hash})"
    else
      fail "bank send to ${addr} was accepted at CheckTx (tx ${hash}) but failed on-chain without the blocklist error"
    fi
    return 1
  fi
  fail "bank send to ${addr} failed for an unexpected reason: ${out}"
  return 1
}

# 0x01-0x09 are blocked on every moca version (Berlin set).
expect_bank_send_rejected "$(precompile_addr 1)" || true
expect_bank_send_rejected "$(precompile_addr 9)" || true
if [ "$PRAGUE_EXPECTED" = "1" ]; then
  # 0x0a-0x11 join the blocklist with the Prague set (mocachain/moca#555).
  expect_bank_send_rejected "$(precompile_addr 10)" || true
  expect_bank_send_rejected "$(precompile_addr 17)" || true
else
  echo "  NOTE: chain does not enable Prague; 0x0a-0x11 blocklist not checked"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: ${FAILURES} blocklist check(s) failed"
  exit 1
fi

echo "PASS: standard Ethereum precompiles are reachable and their addresses are blocked for bank sends"
