#!/usr/bin/env bash
# Contract tests for thin macOS game launchers (~/Applications/Cyder).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

HELPER="$ROOT/scripts/cyder-create-mac-launcher.sh"
launcher="$(cat "$ROOT/scripts/cyder_mac_launcher.swift")"
library="$(cat "$ROOT/scripts/cyder_game_library.swift")"
ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
paths="$(cat "$ROOT/scripts/cyder_paths.swift")"
pack="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert test -f "$HELPER"
assert test -x "$HELPER"
helper_src="$(cat "$HELPER")"
assert_contains "$helper_src" 'open -n -a' \
  "mac launcher must hand off to Cyder via open -n -a"
assert_contains "$helper_src" 'LSUIElement' \
  "mac launcher wrapper must stay out of the Dock"
assert_contains "$helper_src" 'AppIcon.icns' \
  "mac launcher must fall back to Cyder AppIcon when PE icon is missing"
assert_contains "$helper_src" 'fall back to Cyder.app' \
  "mac launcher should document the Cyder icon fallback"
assert_contains "$helper_src" 'CyderGame' \
  "mac launcher executable name must match CyderBits convention"

assert_contains "$launcher" "CyderMacLauncherInstaller" \
  "Swift should expose a mac launcher installer"
assert_contains "$launcher" "LSRegisterURL" \
  "created launchers must register with Launch Services"
assert_contains "$launcher" "local.cyder.launcher." \
  "launcher bundle ids must be namespaced under local.cyder.launcher"

assert_contains "$paths" "macLaunchersRoot" \
  "paths should declare ~/Applications/Cyder"
assert_contains "$paths" 'Applications/Cyder' \
  "mac launchers should live under a Cyder subdirectory"

assert_contains "$library" "macAppPath" \
  "game library records should track the created .app path"
assert_contains "$library" "setMacAppPath" \
  "library store should persist mac launcher paths"

assert_contains "$ui" "加入 macOS 應用程式" \
  "game library context menu should offer Add to macOS Applications"
assert_contains "$ui" "更新 macOS 應用程式" \
  "game library should relabel when a launcher already exists"
assert_contains "$ui" "installMacAppForSelectedGame" \
  "context menu action should install the mac launcher"

assert_contains "$pack" 'cyder-create-mac-launcher.sh' \
  "Cyder.app must bundle the mac launcher helper"
assert_contains "$pack" 'cyder_mac_launcher.swift' \
  "CyderSwift build must compile the mac launcher module"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mac-launcher-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fake_exe="$tmp/game.exe"
touch "$fake_exe"
fake_exe="$(cd "$(dirname "$fake_exe")" && pwd)/$(basename "$fake_exe")"
fake_cyder="$tmp/Cyder.app"
mkdir -p "$fake_cyder/Contents/MacOS" "$fake_cyder/Contents/Resources"
fake_cyder="$(cd "$fake_cyder" && pwd)"
printf 'icns' >"$fake_cyder/Contents/Resources/AppIcon.icns"
out="$("$HELPER" \
  --exe "$fake_exe" \
  --cyder-app "$fake_cyder" \
  --output "$tmp/My Game.app" \
  --name "My Game" \
  --bundle-id "local.cyder.launcher.profile-test")"
assert_eq "$out" "$tmp/My Game.app" "helper should print the created app path"
assert test -x "$tmp/My Game.app/Contents/MacOS/CyderGame"
launcher_body="$(cat "$tmp/My Game.app/Contents/MacOS/CyderGame")"
assert_contains "$launcher_body" "open -n -a" "launcher script must call open -n -a"
assert_contains "$launcher_body" "$fake_exe" "launcher script must embed the EXE path"
assert_contains "$launcher_body" "$fake_cyder" "launcher script must embed the Cyder.app path"
icon_path="$tmp/My Game.app/Contents/Resources/AppIcon.icns"
[[ -f "$icon_path" ]] || {
  echo "ASSERT failed: launcher must include an icon (Cyder fallback when no --icon-png)" >&2
  exit 1
}

echo "PASS test-cyder-mac-launcher"
