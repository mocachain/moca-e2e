#!/usr/bin/env bash
# E2E test: send a bank transfer and verify balances change
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "bank transfer test"
require_test_key

echo "Testing bank transfer..."

# Sender = test key, receiver = a random fresh address
SENDER=$(get_key_address "$TEST_KEY")
echo "  Sender ($TEST_KEY): $SENDER"

# Generate a fresh receiver address to avoid state dependency
RECEIVER="0x$(openssl rand -hex 20)"
echo "  Receiver (fresh): $RECEIVER"

# Query sender balance before
SENDER_BEFORE=$(get_balance "$SENDER")
echo "  Sender balance before: $SENDER_BEFORE $DENOM"

# Send 1 MOCA (1e18 amoca)
SEND_AMOUNT="1000000000000000000"
echo "  Sending ${SEND_AMOUNT} ${DENOM}..."
tx_out="$(cosmos_tx bank send "$TEST_KEY" "$RECEIVER" "${SEND_AMOUNT}${DENOM}" --from "$TEST_KEY")"
tx_hash="$(printf '%s\n' "$tx_out" | sed -n 's/^txhash:[[:space:]]*//p' | tail -1)"
[ -n "$tx_hash" ] || { echo "$tx_out"; echo "FAIL: could not parse tx hash"; exit 1; }
wait_for_tx "$tx_hash" 20 || { echo "$tx_out"; echo "FAIL: tx $tx_hash was not found before timeout"; exit 1; }

# Query balances after
SENDER_AFTER=$(get_balance "$SENDER")
RECEIVER_AFTER=$(get_balance "$RECEIVER")
echo "  Sender balance after:   $SENDER_AFTER $DENOM"
echo "  Receiver balance after: $RECEIVER_AFTER $DENOM"

# Verify receiver got the tokens
assert_ne "$RECEIVER_AFTER" "0" "Receiver has balance" || exit 1
assert_ne "$SENDER_AFTER" "$SENDER_BEFORE" "Sender balance changed" || exit 1

echo "PASS: Bank transfer successful"
