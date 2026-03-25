#!/usr/bin/env bash
set -euo pipefail

# Compares state hash exports from two architecture runs.
# If app_hash matches at all checkpoint heights, the state machine is deterministic.
#
# Usage: ./compare-state.sh <state-amd64.json> <state-arm64.json>

FILE_A="${1:?Usage: $0 <state-file-a> <state-file-b>}"
FILE_B="${2:?Usage: $0 <state-file-a> <state-file-b>}"

if [ ! -f "$FILE_A" ] || [ ! -f "$FILE_B" ]; then
  echo "Error: both state files must exist"
  exit 1
fi

ARCH_A=$(jq -r '.metadata.architecture' "$FILE_A")
ARCH_B=$(jq -r '.metadata.architecture' "$FILE_B")

echo "=== State Hash Comparison ==="
echo "  File A: $FILE_A ($ARCH_A)"
echo "  File B: $FILE_B ($ARCH_B)"
echo ""

# Get all checkpoint heights from both files
HEIGHTS_A=$(jq -r '.checkpoints[].height' "$FILE_A" | sort -n)
HEIGHTS_B=$(jq -r '.checkpoints[].height' "$FILE_B" | sort -n)

PASS=0
FAIL=0
WARN=0

for HEIGHT in $HEIGHTS_A; do
  HASH_A=$(jq -r --argjson h "$HEIGHT" '.checkpoints[] | select(.height == $h) | .app_hash' "$FILE_A")
  HASH_B=$(jq -r --argjson h "$HEIGHT" '.checkpoints[] | select(.height == $h) | .app_hash' "$FILE_B")
  TXS_A=$(jq -r --argjson h "$HEIGHT" '.checkpoints[] | select(.height == $h) | .num_txs' "$FILE_A")
  TXS_B=$(jq -r --argjson h "$HEIGHT" '.checkpoints[] | select(.height == $h) | .num_txs' "$FILE_B")

  if [ -z "$HASH_B" ] || [ "$HASH_B" = "null" ]; then
    echo "  Height $HEIGHT: SKIP (not in $ARCH_B)"
    WARN=$((WARN + 1))
    continue
  fi

  if [ "$TXS_A" != "0" ] || [ "$TXS_B" != "0" ]; then
    echo "  Height $HEIGHT: WARN — contains transactions (A:$TXS_A, B:$TXS_B), comparison may be invalid"
    WARN=$((WARN + 1))
  fi

  if [ "$HASH_A" = "$HASH_B" ]; then
    echo "  Height $HEIGHT: MATCH  app_hash=$HASH_A"
    PASS=$((PASS + 1))
  else
    echo "  Height $HEIGHT: MISMATCH"
    echo "    $ARCH_A: $HASH_A"
    echo "    $ARCH_B: $HASH_B"
    FAIL=$((FAIL + 1))

    # Also compare sub-hashes for diagnostics
    echo "    --- Detailed comparison ---"
    for FIELD in validators_hash consensus_hash data_hash last_results_hash; do
      VA=$(jq -r --argjson h "$HEIGHT" ".checkpoints[] | select(.height == \$h) | .${FIELD}" "$FILE_A")
      VB=$(jq -r --argjson h "$HEIGHT" ".checkpoints[] | select(.height == \$h) | .${FIELD}" "$FILE_B")
      STATUS="MATCH"
      if [ "$VA" != "$VB" ]; then STATUS="MISMATCH"; fi
      echo "    $FIELD: $STATUS (A:$VA B:$VB)"
    done
  fi
done

echo ""
echo "=== Results: $PASS matched, $FAIL mismatched, $WARN warnings ==="

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "DETERMINISM CHECK FAILED"
  echo "The $ARCH_A and $ARCH_B builds produce different app state."
  echo "This indicates an architecture-dependent non-determinism bug"
  echo "(likely in CGO, BLST, or floating-point code)."
  exit 1
fi

echo ""
echo "DETERMINISM CHECK PASSED"
echo "The $ARCH_A and $ARCH_B builds produce identical app state."
