#!/usr/bin/env bash
# moca-cmd sidecar: idle container that tests exec into via `docker exec moca-cmd moca-cmd ...`.
# Bootstraps config.toml + keystore at startup from the public Hardhat #0 test key
# (same account that genesis-init seeds under the name `testaccount`).
set -euo pipefail

HOME_DIR="${HOME_DIR:-/root/.moca-cmd}"
RPC_HOST="${RPC_HOST:-validator-0}"
RPC_PORT="${RPC_PORT:-26657}"
EVM_RPC_PORT="${EVM_RPC_PORT:-8545}"
CHAIN_ID="${CHAIN_ID:-moca_5151-1}"

# Well-known Hardhat/Anvil account #0. Matches testaccount seeded into genesis
# by scripts/init-genesis.sh (mnemonic: "test test...junk").
TEST_PRIVATE_KEY="${TEST_PRIVATE_KEY:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
TEST_PASSWORD="${TEST_PASSWORD:-mc}"

mkdir -p "$HOME_DIR/config"

# moca-cmd reads config from $HOME/config/config.toml (subdir, not $HOME/config.toml).
cat > "$HOME_DIR/config/config.toml" <<EOF
rpcAddr = "http://${RPC_HOST}:${RPC_PORT}"
chainId = "${CHAIN_ID}"
evmRpcAddr = "http://${RPC_HOST}:${EVM_RPC_PORT}"
EOF

PASSWORD_FILE="$HOME_DIR/password.txt"
KEY_FILE="$HOME_DIR/key.txt"
printf '%s' "$TEST_PASSWORD" > "$PASSWORD_FILE"
printf '%s' "$TEST_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$PASSWORD_FILE" "$KEY_FILE"

if [ ! -f "$HOME_DIR/account/defaultKey" ]; then
  echo "Importing testaccount into moca-cmd keystore..."
  moca-cmd --home "$HOME_DIR" --passwordfile "$PASSWORD_FILE" \
    account import "$KEY_FILE" || {
      echo "ERROR: failed to import testaccount key" >&2
      exit 1
    }
fi

echo "=== moca-cmd ready ==="
echo "HOME_DIR=$HOME_DIR"
echo "default account: $(cat "$HOME_DIR/account/defaultKey" 2>/dev/null || echo 'UNKNOWN')"
echo "Use: docker exec moca-cmd moca-cmd <args>"

exec tail -f /dev/null
