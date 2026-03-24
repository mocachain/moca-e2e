#!/usr/bin/env bash
set -euo pipefail

VALIDATOR_NAME="${VALIDATOR_NAME:?VALIDATOR_NAME required}"
MOCA_HOME="${MOCA_HOME:-/root/.mocad}"
SHARED_DIR="${SHARED_DIR:-/shared}"

echo "=== Starting validator (cosmovisor): $VALIDATOR_NAME ==="

# Copy config from shared init volume
if [ -d "$SHARED_DIR/$VALIDATOR_NAME" ]; then
  echo "Copying config from shared volume..."
  mkdir -p "$MOCA_HOME"
  cp -r "$SHARED_DIR/$VALIDATOR_NAME/config" "$MOCA_HOME/config"
  cp -r "$SHARED_DIR/$VALIDATOR_NAME/keyring-test" "$MOCA_HOME/keyring-test" 2>/dev/null || true

  mkdir -p "$MOCA_HOME/data"
  if [ -f "$SHARED_DIR/$VALIDATOR_NAME/data/priv_validator_state.json" ]; then
    cp "$SHARED_DIR/$VALIDATOR_NAME/data/priv_validator_state.json" "$MOCA_HOME/data/"
  else
    echo '{"height":"0","round":0,"step":0}' > "$MOCA_HOME/data/priv_validator_state.json"
  fi
else
  echo "Error: shared config not found at $SHARED_DIR/$VALIDATOR_NAME"
  exit 1
fi

# Set up cosmovisor directory structure
COSMOVISOR_DIR="$MOCA_HOME/cosmovisor"
mkdir -p "$COSMOVISOR_DIR/genesis/bin"
mkdir -p "$COSMOVISOR_DIR/upgrades"
cp /usr/local/bin/mocad "$COSMOVISOR_DIR/genesis/bin/mocad"

export DAEMON_NAME=mocad
export DAEMON_HOME="$MOCA_HOME"

echo "Starting cosmovisor..."
exec cosmovisor run start \
  --home "$MOCA_HOME" \
  --rpc.laddr "tcp://0.0.0.0:26657" \
  --grpc.address "0.0.0.0:9090" \
  --api.enable \
  --api.address "tcp://0.0.0.0:1317" \
  --api.swagger \
  --json-rpc.address "0.0.0.0:8545" \
  --json-rpc.ws-address "0.0.0.0:8546" \
  --json-rpc.enable \
  --minimum-gas-prices "0${DENOM:-amoca}" \
  "$@"
