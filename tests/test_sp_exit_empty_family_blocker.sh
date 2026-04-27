#!/usr/bin/env bash
# E2E: reproduce the empty-family blocker during complete SP exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export E2E_SP_EXIT_EXPECT_EMPTY_FAMILY_BLOCK=1
exec bash "$SCRIPT_DIR/sp_exit_common" "$@"
