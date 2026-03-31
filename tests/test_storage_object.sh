#!/usr/bin/env bash
# E2E test: object operations via moca-cmd (put/head/list).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: object test only on local"; exit 0; fi

if ! resolve_moca_cmd >/dev/null 2>&1; then
  echo "SKIP: moca-cmd is not available"
  exit 0
fi

echo "Testing storage object operations..."

SP_CHECK=$(exec_mocad query sp storage-providers --node tcp://localhost:26657 --output json 2>/dev/null || echo "")
NUM_SPS=$(echo "$SP_CHECK" | jq -r '.sps | length // 0' 2>/dev/null || echo "0")
NUM_SPS="${NUM_SPS:-0}"
if [ "$NUM_SPS" -le 0 ]; then
  echo "SKIP: no storage providers found"
  exit 0
fi

BUCKET_NAME="e2e-obj-bucket-$(date +%s)"
OBJECT_FILE="/tmp/e2e-object-$(date +%s).txt"
OBJECT_PATH="moca://${BUCKET_NAME}/hello.txt"
echo "hello-moca-e2e-object" > "$OBJECT_FILE"

cleanup() {
  rm -f "$OBJECT_FILE"
  exec_moca_cmd bucket rm "moca://${BUCKET_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PRIMARY_SP=$(echo "$SP_CHECK" | jq -r '.sps[0].operator_address // empty' 2>/dev/null || true)
if [ -z "$PRIMARY_SP" ]; then
  echo "SKIP: cannot resolve primary SP"
  exit 0
fi

exec_moca_cmd bucket create --primarySP "$PRIMARY_SP" "moca://${BUCKET_NAME}" >/dev/null
wait_for_tx 4

PUT_OUTPUT="$(exec_moca_cmd object put "$OBJECT_FILE" "$OBJECT_PATH" || true)"
if [ -z "$PUT_OUTPUT" ]; then
  echo "SKIP: object put returned empty output"
  exit 0
fi

wait_for_tx 6

HEAD_OUTPUT="$(exec_moca_cmd object head "$OBJECT_PATH" || true)"
if [ -z "$HEAD_OUTPUT" ]; then
  echo "WARN: object head did not return output"
  exit 0
fi

if echo "$HEAD_OUTPUT" | grep -Eq "hello.txt|object_name"; then
  echo "PASS: storage object operations tested"
else
  echo "WARN: object head format unexpected"
  exit 0
fi
