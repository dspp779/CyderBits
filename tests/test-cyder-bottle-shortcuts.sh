#!/usr/bin/env bash
# Contract + parser smoke for bottle Start Menu / Desktop shortcut import.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

library="$(cat "$ROOT/scripts/cyder_game_library.swift")"
scanner="$(cat "$ROOT/scripts/cyder_bottle_shortcuts.swift")"
icon="$(cat "$ROOT/scripts/cyder_game_icon.swift")"
ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
pack="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$scanner" "CyderBottleShortcutScanner" "library should expose a bottle shortcut scanner"
assert_contains "$library" "importShortcuts" "library store should import discovered shortcuts"
assert_contains "$library" "title: shortcut.displayName" \
  "shortcut import must prefer the .lnk display name over the EXE basename"
assert_contains "$library" 'title?.trimmingCharacters' \
  "game tiles must fall back to the EXE name when no shortcut title exists"
assert_contains "$scanner" "LocalBasePath" "scanner should parse Shell Link LocalBasePath"
assert_contains "$icon" "ensureExtracted" "icon store should extract PE icons without Open Panel"
assert_not_contains "$icon" "NSWorkspace.shared.icon(forFile:" \
  "game tiles must not fall back to macOS generic EXE icons"
assert_contains "$ui" "重新整理遊戲庫" "game library should expose refresh"
assert_contains "$ui" "refreshLibrary" "refresh should have a dedicated action"
assert_contains "$ui" "gearshape" "game library should expose a preferences gear"
assert_contains "$ui" "onOpenPreferences" "game library should request preferences"
assert_contains "$ui" "addCyderTitlebarButtons" "title bar should host multiple trailing buttons"
assert_contains "$ui" "func retryMissingIcons(" \
  "an already-open library must retry icon extract after Wine bootstrap"
assert_contains "$app" "retryMissingIcons(" \
  "environment setup must ask the library to retry icons when bootstrap finishes"
assert_contains "$app" "onOpenPreferences" "app should wire library preferences to settings"
assert_contains "$pack" "cyder_bottle_shortcuts.swift" \
  "app bundle must compile the shortcut scanner source"
assert_not_contains "$icon" "/usr/bin/python3" \
  "game library icon extraction must not invoke the CLT python3 stub"
assert_contains "$icon" "CyderPEIcon.extract" \
  "game icons must read PE resources without starting Wine"
assert_contains "$icon" "CyderLaunchPreparation" \
  "icon reads must use bounded physical workers and observation deadlines"
assert_contains "$icon" "pendingCompletions" \
  "overlapping requests should coalesce bounded callbacks"
assert_contains "$icon" "game-icons" \
  "native PNGs must persist under Application Support"
assert_not_contains "$icon" "Process()" \
  "browsing icons must not create native or Wine executors"
assert_not_contains "$icon" "WINEPREFIX" \
  "browsing icons must not mutate or join a Wine environment"
assert_contains "$pack" "cyder_pe_icon.swift" \
  "the app must compile its native PE resource reader"
# Pixel-level PE32/PE32+, corrupt resource, cache and stalled-reader behavior is
# covered by the formal runtime harness, not assumptions about old shell text.
bash "$ROOT/tests/test-cyder-game-icons.sh"

parsed="$(
  python3 - <<'PY'
import struct
from pathlib import Path
path = Path("tests/fixtures/shortcuts/Steam.lnk")
data = path.read_bytes()
assert data[:4] == b"L\x00\x00\x00"
flags = struct.unpack_from("<I", data, 0x14)[0]
off = 0x4C
if flags & 1:
    off += 2 + struct.unpack_from("<H", data, off)[0]
assert flags & 2, "Steam.lnk should include LinkInfo"
local_base_off = struct.unpack_from("<I", data, off + 16)[0]
p = off + local_base_off
end = data.find(b"\x00", p)
print(data[p:end].decode("latin-1"))
PY
)"
assert_contains "$parsed" "Steam\\steam.exe" "fixture Steam.lnk should resolve to steam.exe"

echo "PASS test-cyder-bottle-shortcuts"
