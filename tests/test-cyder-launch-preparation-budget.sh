#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cyder-preparation-budget.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
/usr/bin/python3 - "$ROOT" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
source=(root/'scripts/cyder_app_main.swift').read_text()
start=source.index('private enum CyderWineLaunchSequence {')
end=source.index('// A timeout ends observation',start)
# The generic sequence body is production code. This alias lets the fixture
# supply real runner outcomes without importing the full AppKit application.
prefix='import Foundation\ntypealias CyderLaunchOutcome = CyderProcessRunner.Outcome\n'
(tmp/'main.swift').write_text(prefix+source[start:end]+(root/'tests/fixtures/cyder_launch_preparation_budget_harness.swift').read_text())
PY
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_process_runner.swift" \
  "$ROOT/scripts/cyder_launch_observer.swift" "$ROOT/scripts/cyder_execution_phase.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/state"
if [[ -n "${CYDER_TEST_EVIDENCE:-}" ]]; then
  mkdir -p "$CYDER_TEST_EVIDENCE"
  cp "$TEST_DIR/state/result.json" "$CYDER_TEST_EVIDENCE/"
fi
