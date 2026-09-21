#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-session-lock.XXXXXX)"
cleanup() {
  if [[ -f "$TEST_DIR/state/passed" ]]; then rm -rf "$TEST_DIR";
  else echo "Preserving failed fixture: $TEST_DIR" >&2; fi
}
trap cleanup EXIT
python3 "$ROOT/tests/fixtures/cyder_session_lock.py" "$TEST_DIR/state" "$ROOT/scripts/cyder-common.sh"
test -f "$TEST_DIR/state/passed"
