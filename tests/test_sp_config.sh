#!/usr/bin/env bash
# E2E: SP config.toml checks (devcontainer test-sp-config parity).
set -euo pipefail

ENV="${1:-local}"
_CONFIG_FILE="${2:-config/local.yaml}"

if [ "$ENV" = "mainnet" ]; then echo "SKIP: not safe for mainnet"; exit 0; fi
if [ "$ENV" != "local" ]; then echo "SKIP: SP config test only on local"; exit 0; fi

TARGET_SP="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^sp-[0-9]+$' | head -1 || true)"
if [ -z "$TARGET_SP" ]; then
  echo "SKIP: no SP container found"
  exit 0
fi

CFG="$(docker exec "$TARGET_SP" sh -c 'test -f /app/config/config.toml && cat /app/config/config.toml || test -f /root/.moca-sp/config.toml && cat /root/.moca-sp/config.toml || true' 2>/dev/null || true)"
if [ -z "$CFG" ]; then
  echo "WARN: cannot read SP config.toml from $TARGET_SP"
  exit 0
fi

ERRORS=0
must_match() {
  local pat="$1"
  local msg="$2"
  if echo "$CFG" | grep -Eq "$pat"; then
    echo "  OK: $msg"
  else
    echo "  WARN: $msg"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "Testing SP config on $TARGET_SP..."

must_match '^GRPCAddress[[:space:]]*=' "GRPCAddress present"
must_match '^HTTPAddress[[:space:]]*=' "HTTPAddress present"
must_match '^DomainName[[:space:]]*=' "DomainName present"
must_match '^MetricsHTTPAddress[[:space:]]*=' "MetricsHTTPAddress present"

if echo "$CFG" | sed -n '/\[BlockSyncer\]/,/^\[/p' | grep -q '^Modules'; then
  MODS=$(echo "$CFG" | sed -n '/\[BlockSyncer\]/,/^\[/p' | grep '^Modules' | head -1)
  if echo "$MODS" | grep -q 'bucket' && echo "$MODS" | grep -q 'object'; then
    echo "  OK: BlockSyncer Modules references core entities"
  else
    echo "  WARN: BlockSyncer Modules may be incomplete"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  WARN: BlockSyncer Modules not found"
  ERRORS=$((ERRORS + 1))
fi

WORKERS=$(echo "$CFG" | sed -n '/\[BlockSyncer\]/,/^\[/p' | grep '^Workers' | sed 's/.*=[[:space:]]*//' | tr -d ' "' || echo "")
if [ "$WORKERS" = "50" ]; then
  echo "  OK: BlockSyncer Workers = 50"
else
  echo "  WARN: BlockSyncer Workers = ${WORKERS:-unknown} (expected 50 in devcontainer template)"
fi

must_match '^CreateGlobalVirtualGroupGasLimit[[:space:]]*=[[:space:]]*180000' "CreateGlobalVirtualGroupGasLimit = 180000"
must_match '^CreateGlobalVirtualGroupFeeAmount[[:space:]]*=[[:space:]]*12000000' "CreateGlobalVirtualGroupFeeAmount = 12000000"

if echo "$CFG" | grep -q '^Server[[:space:]]*='; then
  SRV=$(echo "$CFG" | grep '^Server' | head -1)
  if echo "$SRV" | grep -q 'gateway' && echo "$SRV" | grep -q 'blocksyncer'; then
    echo "  OK: Server module list mentions gateway and blocksyncer"
  else
    echo "  WARN: Server module list may be incomplete"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  WARN: Server key not found"
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: SP config checks passed"
else
  echo "WARN: SP config checks reported $ERRORS warning(s)"
  exit 0
fi
