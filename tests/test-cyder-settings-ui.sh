#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-settings-ui.XXXXXX)"
cleanup() {
  local result=$?
  if [[ -n "${CYDER_TEST_EVIDENCE:-}" && -d "$TEST_DIR/support/Logs" ]]; then
    mkdir -p "$CYDER_TEST_EVIDENCE"
    cp -R "$TEST_DIR/support/Logs" "$CYDER_TEST_EVIDENCE/"
  fi
  rm -rf "$TEST_DIR"
  exit "$result"
}
trap cleanup EXIT
cp "$ROOT/tests/fixtures/cyder_settings_ui_harness.swift" "$TEST_DIR/main.swift"
python3 - "$ROOT" "$TEST_DIR" <<'PY'
import pathlib,re,subprocess,sys
root,tmp=map(pathlib.Path,sys.argv[1:])
source=(root/'scripts/create-cyder-app.sh').read_text()
files=list(dict.fromkeys(re.findall(r'\$SCRIPT_DIR/([^"\s]+\.swift)',source)))
files=[str(root/'scripts'/f) for f in files if f != 'cyder_app_main.swift']
subprocess.run(['swiftc','-module-cache-path',str(tmp/'cache')]+files+[str(tmp/'main.swift'),'-o',str(tmp/'test')],check=True)
PY
CYDER_SUPPORT="$TEST_DIR/support" CYDER_RUNTIME_ROOT="$TEST_DIR/runtime" "$TEST_DIR/test" "$TEST_DIR/state"
test -f "$TEST_DIR/state/ui-completed"
echo "PASS settings AppKit completion artifact verified"
