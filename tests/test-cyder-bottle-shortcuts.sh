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
assert_contains "$scanner" "LocalBasePath" "scanner should parse Shell Link LocalBasePath"
assert_contains "$icon" "ensureExtracted" "icon store should extract PE icons without Open Panel"
assert_not_contains "$icon" "NSWorkspace.shared.icon(forFile:" \
  "game tiles must not fall back to macOS generic EXE icons"
assert_contains "$ui" "重新整理遊戲庫" "game library should expose refresh"
assert_contains "$ui" "refreshLibrary" "refresh should have a dedicated action"
assert_contains "$ui" "gearshape" "game library should expose a preferences gear"
assert_contains "$ui" "onOpenPreferences" "game library should request preferences"
assert_contains "$ui" "addCyderTitlebarButtons" "title bar should host multiple trailing buttons"
assert_contains "$ui" "importBottleShortcuts" "opening the library should import bottle shortcuts"
assert_contains "$app" "onOpenPreferences" "app should wire library preferences to settings"
assert_contains "$pack" "cyder_bottle_shortcuts.swift" \
  "app bundle must compile the shortcut scanner source"
assert_not_contains "$icon" "/usr/bin/python3" \
  "game library icon extraction must not invoke the CLT python3 stub"
assert_contains "$icon" "cyder-extract-exe-icon.sh" \
  "game library must call the bundled winemenubuilder helper"
assert_contains "$icon" "45" \
  "icon extraction timeout must be 45 seconds against the existing shared prefix"
assert_contains "$icon" "pendingCompletions" \
  "overlapping extract requests must queue completions instead of dropping them"
assert_contains "$icon" "failedExecutableDate" \
  "failed extracts must retry after the EXE mtime changes"
assert_contains "$icon" "game-icons" \
  "extracted PNGs must persist under Application Support for reuse"
assert_contains "$icon" '"WINEPREFIX": CyderPaths.sharedBottle.path' \
  "icon extraction must reuse the shared bottle, not initialize a second prefix"
assert_not_contains "$icon" "iconExtractPrefix" \
  "icon extraction must not create a dedicated Wine prefix"
assert_not_contains "$icon" "CYDER_ICON_EXTRACT_ISOLATED" \
  "shared-prefix extracts must not wineserver -k"
paths="$(cat "$ROOT/scripts/cyder_paths.swift")"
assert_not_contains "$paths" "iconExtractPrefix" \
  "CyderPaths must not expose a scratch Wine prefix for icons"
assert_not_contains "$paths" "MapleStory OEM" \
  "path comments must not describe the retired OEM flavor"

python3 - "$ROOT/scripts/cyder_game_icon.swift" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
marker = src.find("CyderPaths.bootstrapMarker")
read_handle = src.find("FileHandle(forReadingFrom:")
create = src.find("createFile")
write = src.find("forWritingTo:")
assert marker != -1, "bootstrapMarker guard must exist"
assert read_handle != -1, "source FileHandle open must exist"
assert create != -1 and write != -1, "staging createFile/forWritingTo must exist"
assert marker < read_handle, "bootstrapMarker check must run before opening the source FileHandle"
assert marker < create and marker < write, "bootstrapMarker check must run before staging the EXE"
PY

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
