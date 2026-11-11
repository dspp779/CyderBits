#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /private/tmp/cyder-ddraw-operation.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/fixtures/cyder_directdraw_operation_harness.swift" "$TMP/main.swift"
swiftc -module-cache-path "$TMP/cache" "$ROOT/scripts/cyder_process_runner.swift" \
  "$ROOT/scripts/cyder_directdraw_operation.swift" "$TMP/main.swift" -o "$TMP/test"
"$TMP/test" "$TMP/state"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1]); source=(root/'scripts/cyder_game_library_ui.swift').read_text()
options=source.split('private final class CyderDirectDrawOptions: NSObject {',1)[1].split('\nfinal class CyderGameSettingsWindowController:',1)[0]
assert 'readDataToEndOfFile' not in options and 'waitUntilExit' not in options
assert 'self.observationGeneration == generation' in options
assert 'CyderDirectDrawOperations.shared.cancelRead(operationID)' in options
controller=source.split('final class CyderGameSettingsWindowController:',1)[1]
for method in ('func windowWillClose(', 'private func stopModal('):
    body=controller.split(method,1)[1].split('\n    }',1)[0]
    assert 'directDraw.cancelPendingRead()' in body,method
assert '"$SCRIPT_DIR/cyder_directdraw_operation.swift"' in (root/'scripts/create-cyder-app.sh').read_text()
print('PASS production adapter: close/modal hooks, generation guard, shared owner and shipped source wiring')
PY
