#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/fixtures/cyder_settings_access_harness.swift" "$TMP/main.swift"
swiftc -module-cache-path "$TMP/cache" "$ROOT/scripts/cyder_paths.swift" "$ROOT/scripts/cyder_gptk.swift" "$ROOT/scripts/cyder_settings.swift" "$ROOT/tests/fixtures/cyder_settings_diagnostics_stub.swift" "$TMP/main.swift" -o "$TMP/test"
CYDER_SUPPORT="$TMP/support" "$TMP/test" "$TMP"
# Exercise the actual shell entry before argument dispatch with an unreadable
# preferences source. --help cannot launch Wine; timeout owns only this fixture.
mkdir -p "$TMP/independent"
mkfifo "$TMP/independent/settings.json"
python3 - "$ROOT/scripts/cyder_launcher.sh" "$TMP/independent" <<'PYTEST'
import os, subprocess, sys
env=dict(os.environ, CYDER_SUPPORT=sys.argv[2], CYDER_WINE_SETTINGS_INDEPENDENT='1')
result=subprocess.run(['bash',sys.argv[1],'--help'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,text=True)
assert result.returncode == 0 and 'Usage:' in result.stdout
print('PASS settings-independent native shell entry with FIFO preferences (no Wine)')
PYTEST
