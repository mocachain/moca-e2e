#!/usr/bin/env bash
# E2E: SP config.toml checks (devcontainer test-sp-config parity).
# Every expected key must be present with a valid value; an unreadable config or any missing/invalid
# key fails the test. Gas limits and fees are the values docker/entrypoint-sp.sh patches in.
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
  echo "FAIL: cannot read SP config.toml from $TARGET_SP"
  exit 1
fi

ERRORS=0
must_match() {
  local pat="$1"
  local msg="$2"
  if echo "$CFG" | grep -Eq "$pat"; then
    echo "  OK: $msg"
  else
    echo "  FAIL: $msg"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "Testing SP config on $TARGET_SP..."

# A key counts as present only with a non-empty quoted value.
must_match "^GRPCAddress[[:space:]]*=[[:space:]]*'[^']+'" "GRPCAddress present"
must_match "^HTTPAddress[[:space:]]*=[[:space:]]*'[^']+'" "HTTPAddress present"
must_match "^DomainName[[:space:]]*=[[:space:]]*'[^']+'" "DomainName present"
must_match "^MetricsHTTPAddress[[:space:]]*=[[:space:]]*'[^']+'" "MetricsHTTPAddress present"

BS_SECTION="$(echo "$CFG" | sed -n '/\[BlockSyncer\]/,/^\[/p')"
MODS="$(echo "$BS_SECTION" | grep '^Modules' | head -1 || true)"
if [ -z "$MODS" ]; then
  echo "  FAIL: BlockSyncer Modules not found"
  ERRORS=$((ERRORS + 1))
elif echo "$MODS" | grep -q 'bucket' && echo "$MODS" | grep -q 'object'; then
  echo "  OK: BlockSyncer Modules references core entities"
else
  echo "  FAIL: BlockSyncer Modules incomplete: $MODS"
  ERRORS=$((ERRORS + 1))
fi

WORKERS="$(echo "$BS_SECTION" | grep '^Workers' | head -1 | sed 's/.*=[[:space:]]*//' | tr -d ' "' || true)"
if [ "$WORKERS" = "50" ]; then
  echo "  OK: BlockSyncer Workers = 50"
else
  echo "  FAIL: BlockSyncer Workers = ${WORKERS:-unknown} (expected 50, set by docker/entrypoint-sp.sh)"
  ERRORS=$((ERRORS + 1))
fi

# 5M since moca #332 meters real KV gas in the precompiles (the entrypoint patches every *GasLimit).
must_match '^CreateGlobalVirtualGroupGasLimit[[:space:]]*=[[:space:]]*5000000[[:space:]]*$' "CreateGlobalVirtualGroupGasLimit = 5000000"
must_match '^CreateGlobalVirtualGroupFeeAmount[[:space:]]*=[[:space:]]*12000000[[:space:]]*$' "CreateGlobalVirtualGroupFeeAmount = 12000000"

# An empty Server list runs every registered module; an explicit list must keep gateway and blocksyncer.
SRV="$(echo "$CFG" | grep '^Server[[:space:]]*=' | head -1 || true)"
if [ -z "$SRV" ]; then
  echo "  FAIL: Server key not found"
  ERRORS=$((ERRORS + 1))
elif echo "$SRV" | grep -Eq '^Server[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*$'; then
  echo "  OK: Server module list empty (all registered modules run)"
elif echo "$SRV" | grep -q 'gateway' && echo "$SRV" | grep -q 'blocksyncer'; then
  echo "  OK: Server module list mentions gateway and blocksyncer"
else
  echo "  FAIL: Server module list is neither empty nor includes gateway and blocksyncer: $SRV"
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: SP config checks reported $ERRORS failure(s)"
  exit 1
fi
echo "PASS: SP config checks passed"
