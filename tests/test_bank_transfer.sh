#!/usr/bin/env bash
# E2E test: send a bank transfer and verify balances change
set -euo pipefail

ENV="${1:-local}"
CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_write_enabled "bank transfer test"

echo "Testing bank transfer..."

# Get validator-0 address (sender)
SENDER=$(exec_mocad keys show validator-0 -a --keyring-backend test)
echo "  Sender: $SENDER"

# Get testaccount address (receiver) — created with known mnemonic in genesis
RECEIVER=$(exec_mocad keys show testaccount -a --keyring-backend test 2>/dev/null || echo "")
if [ -z "$RECEIVER" ]; then
  echo "SKIP: testaccount not found in keyring"
  exit 0
fi
echo "  Receiver: $RECEIVER"

# Query balances before
SENDER_BEFORE=$(get_balance "$SENDER")
RECEIVER_BEFORE=$(get_balance "$RECEIVER")
echo "  Sender balance before:   $SENDER_BEFORE $DENOM"
echo "  Receiver balance before: $RECEIVER_BEFORE $DENOM"

# Send 1 MOCA (1e18 amoca)
SEND_AMOUNT="1000000000000000000"
echo "  Sending ${SEND_AMOUNT} ${DENOM}..."
cosmos_tx bank send validator-0 "$RECEIVER" "${SEND_AMOUNT}${DENOM}" --from validator-0
wait_for_tx 5

# Query balances after
SENDER_AFTER=$(get_balance "$SENDER")
RECEIVER_AFTER=$(get_balance "$RECEIVER")
echo "  Sender balance after:   $SENDER_AFTER $DENOM"
echo "  Receiver balance after: $RECEIVER_AFTER $DENOM"

# Verify receiver got the tokens
assert_ne "$RECEIVER_AFTER" "$RECEIVER_BEFORE" "Receiver balance changed" || exit 1

echo "PASS: Bank transfer successful"
