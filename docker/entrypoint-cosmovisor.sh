#!/usr/bin/env bash
set -euo pipefail

VALIDATOR_NAME="${VALIDATOR_NAME:?VALIDATOR_NAME required}"
MOCA_HOME="${MOCA_HOME:-/root/.mocad}"
SHARED_DIR="${SHARED_DIR:-/shared}"

echo "=== Starting validator (cosmovisor): $VALIDATOR_NAME ==="

# Always start fresh from shared init volume
if [ -d "$SHARED_DIR/$VALIDATOR_NAME" ]; then
  echo "Copying config from shared volume..."
  rm -rf "$MOCA_HOME"
  mkdir -p "$MOCA_HOME/config" "$MOCA_HOME/data" "$MOCA_HOME/keyring-test"
  cp -r "$SHARED_DIR/$VALIDATOR_NAME/config/"* "$MOCA_HOME/config/"
  cp -r "$SHARED_DIR/$VALIDATOR_NAME/keyring-test/"* "$MOCA_HOME/keyring-test/" 2>/dev/null || true
  echo '{"height":"0","round":0,"step":0}' > "$MOCA_HOME/data/priv_validator_state.json"
else
  echo "Error: shared config not found at $SHARED_DIR/$VALIDATOR_NAME"
  exit 1
fi

# Patch config.toml — bind to all interfaces
sed -i 's|laddr = "tcp://127.0.0.1:26657"|laddr = "tcp://0.0.0.0:26657"|' "$MOCA_HOME/config/config.toml"
sed -i 's|laddr = "tcp://127.0.0.1:26656"|laddr = "tcp://0.0.0.0:26656"|' "$MOCA_HOME/config/config.toml"

# Patch app.toml — enable API, gRPC, JSON-RPC on all interfaces
sed -i 's|^enable = false|enable = true|' "$MOCA_HOME/config/app.toml"
sed -i 's|address = "tcp://localhost:1317"|address = "tcp://0.0.0.0:1317"|' "$MOCA_HOME/config/app.toml"
sed -i 's|address = "localhost:9090"|address = "0.0.0.0:9090"|' "$MOCA_HOME/config/app.toml"
sed -i 's|address = "127.0.0.1:8545"|address = "0.0.0.0:8545"|' "$MOCA_HOME/config/app.toml"
sed -i 's|ws-address = "127.0.0.1:8546"|ws-address = "0.0.0.0:8546"|' "$MOCA_HOME/config/app.toml"
sed -i 's|minimum-gas-prices = ""|minimum-gas-prices = "0'"${DENOM:-amoca}"'"|' "$MOCA_HOME/config/app.toml"

# Set up cosmovisor directory structure
COSMOVISOR_DIR="$MOCA_HOME/cosmovisor"
mkdir -p "$COSMOVISOR_DIR/genesis/bin"
mkdir -p "$COSMOVISOR_DIR/upgrades"
cp /usr/local/bin/mocad "$COSMOVISOR_DIR/genesis/bin/mocad"

export DAEMON_NAME=mocad
export DAEMON_HOME="$MOCA_HOME"

echo "Starting cosmovisor..."
exec cosmovisor run start --home "$MOCA_HOME" "$@"
