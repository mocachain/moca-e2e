#!/usr/bin/env bash
# Stubbed chain answers for the SP exit predicates in sp.sh. Run with make test-libs.
# shellcheck shell=bash source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TM_RPC="stub"
# shellcheck source=sp.sh
source "$SCRIPT_DIR/sp.sh"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

echo "sp_list_verdict"
check "operator listed"            present   "$(sp_list_verdict target <<<'{"sps":[{"operator_address":"target"},{"operator_address":"other"}]}')"
check "operator absent"            absent    "$(sp_list_verdict target <<<'{"sps":[{"operator_address":"other"}]}')"
check "empty list"                 absent    "$(sp_list_verdict target <<<'{"sps":[]}')"
check "listed next to a bad entry" malformed "$(sp_list_verdict target <<<'{"sps":[{"operator_address":"target"},1]}')"
check "renamed operator field"     malformed "$(sp_list_verdict target <<<'{"sps":[{"operatorAddress":"target"}]}')"
check "no sps key"                 malformed "$(sp_list_verdict target <<<'{}')"
check "not json"                   malformed "$(sp_list_verdict target <<<'rpc error: connection refused')"
check "empty answer"               malformed "$(sp_list_verdict target <<<'')"

echo "gvg_usage_verdict"
check "sp is a primary"            uses      "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":8,"secondary_sp_ids":[3,4]}]}')"
check "sp is a secondary"          uses      "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":1,"secondary_sp_ids":[3,8]}]}')"
check "string ids"                 uses      "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":"1","secondary_sp_ids":["8"]}]}')"
check "sp not used"                clear     "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":1,"secondary_sp_ids":[3,4,9]}]}')"
check "secondary list is a string" malformed "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":9,"secondary_sp_ids":"8"}]}')"
check "secondary list missing"     malformed "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[{"primary_sp_id":9}]}')"
check "no gvgs"                    malformed "$(gvg_usage_verdict 8 <<<'{"global_virtual_groups":[]}')"
check "not json"                   malformed "$(gvg_usage_verdict 8 <<<'rpc error: connection refused')"

echo "wait_for_sp_removed_from_list"
exec_mocad() {
  printf '%s\n' "${STUB_ANSWER-}"
  return "${STUB_RC:-0}"
}
run_wait() {
  if STUB_ANSWER="$1" STUB_RC="${2:-0}" wait_for_sp_removed_from_list target 0 2>/dev/null; then
    echo removed
  else
    echo waiting
  fi
}
check "removed when absent"        removed   "$(run_wait '{"sps":[{"operator_address":"other"}]}')"
check "waits while listed"         waiting   "$(run_wait '{"sps":[{"operator_address":"target"}]}')"
check "waits on a bad entry"       waiting   "$(run_wait '{"sps":[{"operator_address":"target"},1]}')"
check "waits on a renamed field"   waiting   "$(run_wait '{"sps":[{"operatorAddress":"target"}]}')"
check "waits on a failed query"    waiting   "$(run_wait '' 1)"
check "waits on an empty answer"   waiting   "$(run_wait '')"

if [ "$failures" -gt 0 ]; then
  echo "FAIL: ${failures} helper case(s)"
  exit 1
fi
echo "PASS: all helper cases"
