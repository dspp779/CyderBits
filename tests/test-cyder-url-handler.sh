#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$ROOT/tests/fixtures/url-handler/gamaniagames"
COMMON="$(cat "$ROOT/scripts/cyder-common.sh")"
URI_SWIFT="$(cat "$ROOT/scripts/cyder_uri_handler.swift")"
APP="$(cat "$ROOT/scripts/cyder_app_main.swift")"
SETTINGS="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
BUILD="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$COMMON" 'cyder_scan_uri_handlers' "common must expose uri handler scanner"
assert_contains "$COMMON" 'command -v rg' "URI registry scan must prefer ripgrep when available"
assert_contains "$COMMON" 'grep -F' "URI registry scan must fall back to grep -F without rg"
assert_contains "$COMMON" 'cyder_reg_read_uri_scheme' "common must parse wine registry sections"
assert_contains "$URI_SWIFT" 'CyderURIHandlerManager' "swift uri handler manager must exist"
assert_contains "$URI_SWIFT" 'urlForApplication(toOpen:' \
  "swift must query the default URL handler via NSWorkspace"
assert_contains "$URI_SWIFT" 'URL(string: "\(Self.scheme)://")' \
  "default-handler probe must use a hierarchical URL, not scheme-only gamaniagames:"
assert_not_contains "$URI_SWIFT" 'LSCopyDefaultHandlerForURLScheme' \
  "swift must not use deprecated LSCopyDefaultHandlerForURLScheme"
assert_contains "$URI_SWIFT" 'absoluteString' "design requires preserving uri absoluteString"
assert_contains "$APP" 'application(_ application: NSApplication, open urls' "app must handle url open events"
assert_contains "$APP" 'enqueueOrLaunchURIs' "app must queue uri launches"
assert_contains "$SETTINGS" 'prepareForDisplay' "settings must expose prepareForDisplay"
assert_contains "$SETTINGS" 'beginURIHandlerScan()' \
  "URI handlers must scan when preferences open and when the user rescans"
assert_not_contains "$SETTINGS" 'func tabView(_ tabView: NSTabView, didSelect' \
  "switching to the URI tab must not start a new registry scan"
assert_contains "$APP" 'documentLaunchRequested = true' "uri launches must mark a document-style launch"
assert_contains "$APP" 'URI launches are already queued' "cold-start uri launches must skip settings environment check"
assert_contains "$SETTINGS" 'URI 協定' "settings must include uri handler tab"
assert_contains "$SETTINGS" '@objc private func rescanURIHandlers()' "settings must keep a manual URI rescan action"
assert_contains "$SETTINGS" 'uriHandlerTable' "settings must list uri handlers in a table"
assert_contains "$URI_SWIFT" 'scanAsync' "uri handler scan must support async settings refresh"
assert_contains "$BUILD" 'gamaniagames' "app payload must declare gamaniagames url scheme"
assert_contains "$BUILD" 'cyder_uri_handler.swift' "app build must compile uri handler module"

output="$(bash "$ROOT/scripts/cyder_launcher.sh" --scan-uri-handlers "$FIXTURE" 2>/dev/null)"
assert_contains "$output" '"status":"valid"' "fixture must scan as valid"
assert_contains "$output" 'GGMWebStart.exe' "fixture must resolve ggm webstart exe"

# Registry unchanged → section timestamp not newer than a future baseline.
future_scan="$(bash "$ROOT/scripts/cyder_launcher.sh" --scan-uri-handlers "$FIXTURE" 2>/dev/null)"
assert_contains "$future_scan" '"sectionTimestamp":1740000100' "fixture must expose section timestamp"

# Broken command fixture
mkdir -p "$TMP/broken/drive_c/bin"
cat >"$TMP/broken/system.reg" <<'REG'
WINE REGISTRY Version 2

[Software\\Classes\\gamaniagames] 999
@="URL:gamania Games Manager Protocol"
"URL Protocol"=""

[Software\\Classes\\gamaniagames\\shell\\open\\command] 999
@="cmd.exe /c start GGMWebStart.exe %1"
REG
touch "$TMP/broken/user.reg"
broken="$(bash "$ROOT/scripts/cyder_launcher.sh" --scan-uri-handlers "$TMP/broken" 2>/dev/null)"
assert_contains "$broken" '"status":"unsupported"' "unsupported command must not be executable"

# Keyword scan must stay fast on a multi-megabyte registry (bash line-read is ~2s).
mkdir -p "$TMP/padded"
cp -R "$FIXTURE/." "$TMP/padded/"
{
  printf 'WINE REGISTRY Version 2\n\n'
  python3 -c 'print("[Dummy\\\\Pad] 1\n@=\"x\"\n" * 80000)'
  cat "$FIXTURE/system.reg"
} >"$TMP/padded/system.reg"
python3 - "$ROOT/scripts/cyder_launcher.sh" "$TMP/padded" <<'PY'
import subprocess, sys, time
from pathlib import Path
launcher, prefix = sys.argv[1], sys.argv[2]
t0 = time.perf_counter()
out = subprocess.check_output(["bash", launcher, "--scan-uri-handlers", prefix], stderr=subprocess.DEVNULL)
elapsed = time.perf_counter() - t0
if elapsed > 0.75:
    raise SystemExit(f"padded URI scan took {elapsed:.3f}s, expected under 0.75s")
if b'"status":"valid"' not in out:
    raise SystemExit("padded URI scan lost the fixture handler")
print(f"padded URI scan {elapsed:.3f}s")
PY

echo "PASS test-cyder-url-handler"
