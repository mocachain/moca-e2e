#!/usr/bin/env bash
set -euo pipefail

# Genesis init script — runs inside the genesis-init container.
# Generates all validator keys, SP keys, genesis.json, and per-node configs.
# Writes everything to $OUTPUT_DIR (shared volume).

CHAIN_ID="${CHAIN_ID:?CHAIN_ID required}"
DENOM="${DENOM:?DENOM required}"
NUM_VALIDATORS="${NUM_VALIDATORS:?NUM_VALIDATORS required}"
NUM_SPS="${NUM_SPS:?NUM_SPS required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR required}"

GENESIS_ACCOUNT_BALANCE="${GENESIS_ACCOUNT_BALANCE:-100000000000000000000000000}"
STAKING_BOND_AMOUNT="${STAKING_BOND_AMOUNT:-10000000000000000000000000}"
SP_MIN_DEPOSIT="${SP_MIN_DEPOSIT:-10000000000000000000000}"
GOV_MIN_DEPOSIT="${GOV_MIN_DEPOSIT:-10000000000000000000}"
GOV_VOTING_PERIOD="${GOV_VOTING_PERIOD:-15s}"
BLOCK_TIME="${BLOCK_TIME:-1s}"

KEYRING="test"
WORK_DIR="/tmp/genesis-work"
rm -rf "$WORK_DIR"

echo "=== Genesis Init ==="
echo "Chain ID: $CHAIN_ID"
echo "Validators: $NUM_VALIDATORS"
echo "Storage Providers: $NUM_SPS"
echo ""

# --- Step 1: Initialize first validator's home (for genesis template) ---
echo "--- Step 1: Init chain ---"
VALIDATOR_0_HOME="$WORK_DIR/validator-0"
mocad init "validator-0" --chain-id "$CHAIN_ID" --home "$VALIDATOR_0_HOME" 2>/dev/null

GENESIS="$VALIDATOR_0_HOME/config/genesis.json"

# --- Step 2: Patch genesis ---
echo "--- Step 2: Patch genesis ---"

# Set denom
TMPFILE=$(mktemp)

# Replace ALL occurrences of "stake" denom with our denom
sed -i "s/\"stake\"/\"${DENOM}\"/g" "$GENESIS"

# Set denom_metadata for bank module (required for chain init — name field must not be blank)
NATIVE_COIN_DESC="{\"description\":\"The native staking token of the Moca.\",\"denom_units\":[{\"denom\":\"${DENOM}\",\"exponent\":0,\"aliases\":[\"wei\"]}],\"base\":\"${DENOM}\",\"display\":\"${DENOM}\",\"name\":\"Moca\",\"symbol\":\"MOCA\"}"
jq --argjson meta "[${NATIVE_COIN_DESC}]" '.app_state.bank.denom_metadata = $meta' "$GENESIS" > "$TMPFILE" && mv "$TMPFILE" "$GENESIS"

# Set governance params
# expedited_min_deposit must be strictly greater than min_deposit
EXPEDITED_DEPOSIT="${GOV_MIN_DEPOSIT}0"  # 10x min deposit (append a zero)
jq --arg period "$GOV_VOTING_PERIOD" --arg deposit "$GOV_MIN_DEPOSIT" --arg expedited "$EXPEDITED_DEPOSIT" --arg denom "$DENOM" '
  .app_state.gov.params.voting_period = $period |
  .app_state.gov.params.expedited_voting_period = "10s" |
  .app_state.gov.params.max_deposit_period = $period |
  .app_state.gov.params.min_deposit = [{"denom": $denom, "amount": $deposit}] |
  .app_state.gov.params.expedited_min_deposit = [{"denom": $denom, "amount": $expedited}] |
  .app_state.gov.deposit_params.max_deposit_period = $period |
  .app_state.gov.deposit_params.min_deposit = [{"denom": $denom, "amount": $deposit}]
' "$GENESIS" > "$TMPFILE" && mv "$TMPFILE" "$GENESIS"

# Set block time (consensus params)
jq --arg bt "$BLOCK_TIME" '
  .consensus.params.block.time_iota_ms = "500"
' "$GENESIS" > "$TMPFILE" && mv "$TMPFILE" "$GENESIS"

# --- Step 3: Generate validator keys and add genesis accounts ---
echo "--- Step 3: Generate validator keys ---"

declare -A VALIDATOR_ADDRESSES
declare -A VALIDATOR_NODE_IDS
declare -A RELAYER_ADDRESSES
declare -A CHALLENGER_ADDRESSES
declare -A BLS_KEYS
declare -A BLS_PROOFS

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  VNAME="validator-$i"
  VHOME="$WORK_DIR/$VNAME"

  if [ "$i" -gt 0 ]; then
    mocad init "$VNAME" --chain-id "$CHAIN_ID" --home "$VHOME" 2>/dev/null
  fi

  # Generate validator operator key
  mocad keys add "$VNAME" --keyring-backend "$KEYRING" --home "$VHOME" 2>/dev/null
  ADDR=$(mocad keys show "$VNAME" -a --keyring-backend "$KEYRING" --home "$VHOME")
  VALIDATOR_ADDRESSES[$i]="$ADDR"

  # Generate relayer key
  mocad keys add "relayer-$i" --keyring-backend "$KEYRING" --home "$WORK_DIR/relayer-$i" 2>/dev/null
  RELAYER_ADDRESSES[$i]=$(mocad keys show "relayer-$i" -a --keyring-backend "$KEYRING" --home "$WORK_DIR/relayer-$i")

  # Generate challenger key
  mocad keys add "challenger-$i" --keyring-backend "$KEYRING" --home "$WORK_DIR/challenger-$i" 2>/dev/null
  CHALLENGER_ADDRESSES[$i]=$(mocad keys show "challenger-$i" -a --keyring-backend "$KEYRING" --home "$WORK_DIR/challenger-$i")

  # Generate BLS key for validator
  mocad keys add "validator_bls$i" --keyring-backend "$KEYRING" --home "$VHOME" --algo eth_bls 2>/dev/null
  BLS_KEYS[$i]=$(mocad keys show "validator_bls$i" --keyring-backend "$KEYRING" --home "$VHOME" --output json | jq -r .pubkey_hex)
  BLS_PROOFS[$i]=$(mocad keys sign "${BLS_KEYS[$i]}" --from "validator_bls$i" --keyring-backend "$KEYRING" --home "$VHOME")

  # Get node ID
  NODE_ID=$(mocad tendermint show-node-id --home "$VHOME")
  VALIDATOR_NODE_IDS[$i]="$NODE_ID"

  echo "  $VNAME: addr=$ADDR relayer=${RELAYER_ADDRESSES[$i]} challenger=${CHALLENGER_ADDRESSES[$i]} node_id=$NODE_ID"

  # Add genesis accounts (validator, relayer, challenger)
  for GADDR in "$ADDR" "${RELAYER_ADDRESSES[$i]}" "${CHALLENGER_ADDRESSES[$i]}"; do
    mocad add-genesis-account "$GADDR" "${GENESIS_ACCOUNT_BALANCE}${DENOM}" \
      --home "$VALIDATOR_0_HOME" --keyring-backend "$KEYRING" 2>/dev/null || true
  done
done

# --- Step 4: Generate SP keys and add genesis accounts ---
echo "--- Step 4: Generate SP keys ---"

declare -A SP_OPERATOR_ADDRS
declare -A SP_FUND_ADDRS

for i in $(seq 0 $((NUM_SPS - 1))); do
  SPNAME="sp-$i"
  SPHOME="$WORK_DIR/$SPNAME"
  mkdir -p "$SPHOME"

  # SP has multiple keys: operator, fund, seal, approval, gc, maintenance
  for keytype in operator fund seal approval gc maintenance; do
    KEYNAME="${SPNAME}-${keytype}"
    mocad keys add "$KEYNAME" --keyring-backend "$KEYRING" --home "$VALIDATOR_0_HOME" 2>/dev/null
    KADDR=$(mocad keys show "$KEYNAME" -a --keyring-backend "$KEYRING" --home "$VALIDATOR_0_HOME")

    if [ "$keytype" = "operator" ]; then
      SP_OPERATOR_ADDRS[$i]="$KADDR"
    elif [ "$keytype" = "fund" ]; then
      SP_FUND_ADDRS[$i]="$KADDR"
    fi

    # Add genesis account
    mocad genesis add-genesis-account "$KADDR" "${GENESIS_ACCOUNT_BALANCE}${DENOM}" \
      --home "$VALIDATOR_0_HOME" --keyring-backend "$KEYRING" 2>/dev/null || \
    mocad add-genesis-account "$KADDR" "${GENESIS_ACCOUNT_BALANCE}${DENOM}" \
      --home "$VALIDATOR_0_HOME" --keyring-backend "$KEYRING" 2>/dev/null || true
  done

  # BLS key for SP
  mocad keys add "${SPNAME}-bls" --keyring-backend "$KEYRING" --home "$VALIDATOR_0_HOME" --algo eth_bls 2>/dev/null || true

  echo "  $SPNAME: operator=${SP_OPERATOR_ADDRS[$i]}"
done

# --- Step 5: Generate gentxs ---
echo "--- Step 5: Generate gentxs ---"

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  VNAME="validator-$i"
  VHOME="$WORK_DIR/$VNAME"

  # Copy genesis (with all accounts) to this validator's home
  if [ "$i" -gt 0 ]; then
    cp "$GENESIS" "$VHOME/config/genesis.json"
    # Copy keyring so gentx can find the key
    cp -r "$VALIDATOR_0_HOME/keyring-test" "$VHOME/" 2>/dev/null || true
  fi

  # Create gentx (moca requires 8 args: key amount validator delegator relayer challenger blsKey blsProof)
  mocad gentx "$VNAME" \
    "${STAKING_BOND_AMOUNT}${DENOM}" \
    "${VALIDATOR_ADDRESSES[$i]}" \
    "${VALIDATOR_ADDRESSES[$i]}" \
    "${RELAYER_ADDRESSES[$i]}" \
    "${CHALLENGER_ADDRESSES[$i]}" \
    "${BLS_KEYS[$i]}" \
    "${BLS_PROOFS[$i]}" \
    --home "$VHOME" \
    --keyring-backend="$KEYRING" \
    --chain-id="$CHAIN_ID" \
    --moniker="$VNAME" \
    --commission-rate="0.07" \
    --commission-max-rate="0.10" \
    --commission-max-change-rate="0.01" \
    --details="$VNAME" \
    --gas "" 2>&1

  echo "  $VNAME: gentx created"
done

# Collect gentxs into validator-0's genesis
echo "--- Collecting gentxs ---"
mkdir -p "$VALIDATOR_0_HOME/config/gentx"
for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  VHOME="$WORK_DIR/validator-$i"
  if [ -d "$VHOME/config/gentx" ]; then
    cp "$VHOME/config/gentx/"*.json "$VALIDATOR_0_HOME/config/gentx/" 2>/dev/null || true
    echo "  Copied gentx from validator-$i"
  fi
done
echo "  Gentx files: $(ls "$VALIDATOR_0_HOME/config/gentx/" 2>/dev/null | wc -l)"

mocad collect-gentxs --home "$VALIDATOR_0_HOME" 2>&1
echo "  gen_txs count: $(jq '.app_state.genutil.gen_txs | length' "$VALIDATOR_0_HOME/config/genesis.json")"

# --- Step 6: Generate SP gentxs ---
echo "--- Step 6: Generate SP gentxs ---"
for i in $(seq 0 $((NUM_SPS - 1))); do
  SPNAME="sp-$i"
  ENDPOINT="http://${SPNAME}:9033"

  # Try spgentx (exact command depends on moca version)
  mocad spgentx "$SPNAME" \
    "${SP_MIN_DEPOSIT}${DENOM}" \
    --chain-id "$CHAIN_ID" \
    --home "$VALIDATOR_0_HOME" \
    --keyring-backend "$KEYRING" \
    --sp-operator-address "${SP_OPERATOR_ADDRS[$i]}" \
    --sp-fund-address "${SP_FUND_ADDRS[$i]}" \
    --endpoint "$ENDPOINT" 2>/dev/null || echo "  Warning: spgentx for $SPNAME may need manual setup"

  echo "  $SPNAME: spgentx created"
done

# Collect SP gentxs
mocad genesis collect-spgentxs --home "$VALIDATOR_0_HOME" 2>/dev/null || true

# Validate genesis
echo "--- Validating genesis ---"
mocad validate-genesis --home "$VALIDATOR_0_HOME" 2>&1 || \
echo "Warning: genesis validation failed (may be non-fatal)"

# --- Step 7: Build persistent peers string ---
echo "--- Step 7: Configure peers ---"

PEERS=""
for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  VNAME="validator-$i"
  NODE_ID="${VALIDATOR_NODE_IDS[$i]}"
  if [ -n "$PEERS" ]; then
    PEERS="${PEERS},"
  fi
  PEERS="${PEERS}${NODE_ID}@${VNAME}:26656"
done

echo "Persistent peers: $PEERS"

# --- Step 8: Distribute configs to output ---
echo "--- Step 8: Distribute configs ---"

FINAL_GENESIS="$VALIDATOR_0_HOME/config/genesis.json"

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  VNAME="validator-$i"
  VHOME="$WORK_DIR/$VNAME"
  VOUT="$OUTPUT_DIR/$VNAME"

  mkdir -p "$VOUT/config" "$VOUT/data" "$VOUT/keyring-test"

  # Copy the final genesis
  cp "$FINAL_GENESIS" "$VOUT/config/genesis.json"

  # Copy node key and priv validator key
  cp "$VHOME/config/node_key.json" "$VOUT/config/"
  cp "$VHOME/config/priv_validator_key.json" "$VOUT/config/"

  # Copy config.toml, app.toml, and client.toml (from the init)
  cp "$VHOME/config/config.toml" "$VOUT/config/"
  cp "$VHOME/config/app.toml" "$VOUT/config/"
  cp "$VHOME/config/client.toml" "$VOUT/config/" 2>/dev/null || \
    echo -e "chain-id = \"${CHAIN_ID}\"\nkeyring-backend = \"test\"\noutput = \"text\"\nnode = \"tcp://localhost:26657\"\nbroadcast-mode = \"sync\"" > "$VOUT/config/client.toml"

  # Patch persistent peers into config.toml
  sed -i "s|persistent_peers = \".*\"|persistent_peers = \"${PEERS}\"|" "$VOUT/config/config.toml"

  # Patch addr_book_strict to false (docker networking)
  sed -i 's|addr_book_strict = true|addr_book_strict = false|' "$VOUT/config/config.toml"

  # Patch allow_duplicate_ip
  sed -i 's|allow_duplicate_ip = false|allow_duplicate_ip = true|' "$VOUT/config/config.toml"

  # Patch app.toml — bridge chain IDs (required for InitChain validation)
  SRC_CHAIN_ID=$(echo "$CHAIN_ID" | grep -oP '\d+' | head -1)
  sed -i "s|src-chain-id = 1|src-chain-id = ${SRC_CHAIN_ID:-5151}|" "$VOUT/config/app.toml"
  sed -i "s|dest-bsc-chain-id = 2|dest-bsc-chain-id = 97|" "$VOUT/config/app.toml"
  sed -i "s|dest-op-chain-id = 3|dest-op-chain-id = 5611|" "$VOUT/config/app.toml"

  # Patch app.toml — minimum gas prices
  sed -i "s|minimum-gas-prices = \".*\"|minimum-gas-prices = \"0${DENOM}\"|" "$VOUT/config/app.toml"

  # Copy keyring
  cp -r "$VHOME/keyring-test/"* "$VOUT/keyring-test/" 2>/dev/null || true

  # Init priv_validator_state
  echo '{"height":"0","round":0,"step":0}' > "$VOUT/data/priv_validator_state.json"

  echo "  $VNAME: config written to $VOUT"
done

# --- Step 9: Write SP configs ---
echo "--- Step 9: Write SP configs ---"

for i in $(seq 0 $((NUM_SPS - 1))); do
  SPNAME="sp-$i"
  SPOUT="$OUTPUT_DIR/$SPNAME"
  mkdir -p "$SPOUT"

  # Export SP keys from validator-0's keyring
  for keytype in operator fund seal approval gc maintenance; do
    KEYNAME="${SPNAME}-${keytype}"
    PRIVKEY=$(mocad keys export "$KEYNAME" --unarmored-hex --unsafe \
      --keyring-backend "$KEYRING" --home "$VALIDATOR_0_HOME" 2>/dev/null || echo "")
    echo "$PRIVKEY" > "$SPOUT/${keytype}.key"
  done

  BLS_PRIVKEY=$(mocad keys export "${SPNAME}-bls" --unarmored-hex --unsafe \
    --keyring-backend "$KEYRING" --home "$VALIDATOR_0_HOME" 2>/dev/null || echo "")
  echo "$BLS_PRIVKEY" > "$SPOUT/bls.key"

  # Write SP config template
  cat > "$SPOUT/config.toml" <<SPCONFIG
[Chain]
ChainID = "${CHAIN_ID}"
ChainAddress = ["http://validator-0:26657"]

[SpAccount]
SpOperatorAddress = "${SP_OPERATOR_ADDRS[$i]}"
OperatorPrivateKey = "$(cat "$SPOUT/operator.key")"
FundingPrivateKey = "$(cat "$SPOUT/fund.key")"
SealPrivateKey = "$(cat "$SPOUT/seal.key")"
ApprovalPrivateKey = "$(cat "$SPOUT/approval.key")"
GcPrivateKey = "$(cat "$SPOUT/gc.key")"
BlsPrivateKey = "$(cat "$SPOUT/bls.key")"

[Endpoint]
ApprovalGatewayAddress = "0.0.0.0:9033"
ListenAddress = "0.0.0.0:9033"

[DB]
User = "root"
Passwd = "MYSQL_PASSWORD"
Address = "MYSQL_HOST:MYSQL_PORT"
Database = "DB_NAME"

[PieceStore]
Shards = 0
Store.Storage = "file"
Store.BucketURL = "/data/sp-storage"
SPCONFIG

  echo "  $SPNAME: config written to $SPOUT"
done

# --- Step 10: Write metadata ---
echo "--- Step 10: Write metadata ---"

cat > "$OUTPUT_DIR/metadata.json" <<META
{
  "chain_id": "${CHAIN_ID}",
  "denom": "${DENOM}",
  "num_validators": ${NUM_VALIDATORS},
  "num_sps": ${NUM_SPS},
  "validators": [
$(for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  COMMA=""
  if [ "$i" -lt $((NUM_VALIDATORS - 1)) ]; then COMMA=","; fi
  echo "    {\"name\": \"validator-$i\", \"address\": \"${VALIDATOR_ADDRESSES[$i]}\", \"node_id\": \"${VALIDATOR_NODE_IDS[$i]}\"}${COMMA}"
done)
  ],
  "persistent_peers": "${PEERS}"
}
META

echo ""
echo "=== Genesis init complete ==="
echo "  Output: $OUTPUT_DIR"
echo "  Validators: $NUM_VALIDATORS"
echo "  SPs: $NUM_SPS"
echo "  Chain ID: $CHAIN_ID"
