#!/usr/bin/env bash
# Assertion and output helpers for E2E tests.

assert_gt() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" -gt "$expected" ] 2>/dev/null; then
    echo "  OK: $msg ($actual > $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected > $expected)"
    return 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  OK: $msg ($actual == $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected $expected)"
    return 1
  fi
}

assert_ne() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" != "$expected" ]; then
    echo "  OK: $msg ($actual != $expected)"
  else
    echo "  FAIL: $msg (got $actual, expected != $expected)"
    return 1
  fi
}

print_test_section() {
  echo ""
  echo "=== $* ==="
}

print_success() {
  echo "  OK: $*"
}

wait_for_block() {
  local seconds="${1:-3}"
  sleep "$seconds"
}
