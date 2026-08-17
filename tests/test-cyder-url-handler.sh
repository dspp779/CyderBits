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
assert_contains "$COMMON" 'cyder_reg_read_uri_scheme' "common must parse wine registry sections"
assert_contains "$URI_SWIFT" 'CyderURIHandlerManager' "swift uri handler manager must exist"
assert_contains "$URI_SWIFT" 'absoluteString' "design requires preserving uri absoluteString"
assert_contains "$APP" 'application(_ application: NSApplication, open urls' "app must handle url open events"
assert_contains "$APP" 'enqueueOrLaunchURIs' "app must queue uri launches"
assert_contains "$SETTINGS" 'URI 協定' "settings must include uri handler tab"
assert_contains "$SETTINGS" 'beginURIHandlerScan' "settings must scan uri handlers lazily on tab select"
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

echo "PASS test-cyder-url-handler"
