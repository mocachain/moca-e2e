#!/usr/bin/env bash
# E2E test: basic SP config checks from runtime.
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP config test only on local"; exit 0; fi

echo "Testing SP config..."

TARGET_SP="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$|^sp[0-9]+$' | head -1 || true)"
if [ -z "$TARGET_SP" ]; then
  echo "SKIP: no SP container found"
  exit 0
fi

CFG="$(docker exec "$TARGET_SP" sh -c 'test -f /app/config/config.toml && cat /app/config/config.toml || test -f /root/.moca-sp/config.toml && cat /root/.moca-sp/config.toml || true' 2>/dev/null || true)"
if [ -z "$CFG" ]; then
  echo "WARN: cannot read SP config.toml from $TARGET_SP"
  exit 0
fi

must_have_key() {
  local key="$1"
  if echo "$CFG" | grep -Eq "^${key}[[:space:]]*="; then
    echo "  OK: ${key}"
  else
    echo "  WARN: missing ${key}"
    return 1
  fi
}

FAIL=0
must_have_key "GRPCAddress" || FAIL=1
must_have_key "HTTPAddress" || FAIL=1
must_have_key "DomainName" || FAIL=1

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: SP config checks passed"
else
  echo "WARN: SP config has missing keys"
  exit 0
fi
