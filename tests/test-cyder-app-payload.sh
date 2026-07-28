#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

build_script="$(cat "$ROOT/scripts/create-cyder-app.sh")"
common_script="$(cat "$ROOT/scripts/cyder-common.sh")"
copy_script="$(cat "$ROOT/scripts/cyder-copy-engine-artifact.sh")"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the runtime signing helper"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-legacy-ui.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle legacy UI helpers for macOS < 12"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-legacy-ui.applescript" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle osascript progress UI for macOS < 12"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-macos-wrapper.sh" "$MACOS/Cyder"' \
  "Cyder.app entrypoint must be the OS-version wrapper"
assert_contains "$build_script" '<string>10.15</string>' \
  "Info.plist LSMinimumSystemVersion must match the Wine engine floor"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-edit-user-reg.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the fast registry editor"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder_create_game_app.py" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the PE icon extraction helper"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-winetricks.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the Winetricks launcher"
assert_contains "$build_script" 'cp "$OGOM/tools/winetricks/winetricks" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the pinned Winetricks script"
assert_contains "$build_script" 'cp "$OGOM/tools/winetricks/COPYING" "$RES/licenses/winetricks-COPYING"' \
  "Cyder.app must bundle the Winetricks license"
assert_contains "$build_script" 'cp "$OGOM/tools/zstd/zstd" "$RES/tools/zstd/zstd"' \
  "Cyder.app must bundle the universal zstd extractor"
assert_contains "$build_script" 'cp "$OGOM/tools/zstd/LICENSE" "$RES/licenses/zstd-LICENSE"' \
  "Cyder.app must bundle the zstd license"
assert_contains "$build_script" 'compatdb/compiled/compatdb.cdb' \
  "Cyder.app packaging must bundle the precompiled CompatDB artifact"
assert_contains "$build_script" 'python3 "$OGOM/scripts/cyder-compatdb.py" inspect' \
  "Cyder.app packaging must inspect the bundled runtime CompatDB"
assert_contains "$build_script" '"$SCRIPT_DIR/cyder-cnc-ddraw.sh" verify' \
  "Cyder.app packaging must verify the pinned cnc-ddraw payload"
assert_contains "$build_script" 'vendor/cnc-ddraw/7.1.0.0/cnc-ddraw.zip' \
  "Cyder.app must bundle the pinned offline cnc-ddraw archive"
assert_contains "$build_script" '"$RES/licenses/cnc-ddraw-LICENSE"' \
  "Cyder.app must expose the bundled cnc-ddraw MIT license"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-recipe.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the declarative recipe runner"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/install-dxvk-prefix.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the DXVK prefix provisioner"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-oem-sync-dxvk.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the OEM DXVK sidecar repair helper"
winetricks_launcher="$(cat "$ROOT/scripts/cyder-winetricks.sh")"
assert_contains "$winetricks_launcher" 'exec /usr/bin/arch -x86_64 /bin/sh "$winetricks" --unattended "$@"' \
  "Cyder Winetricks integration should use unattended CLI mode"
if [[ "$winetricks_launcher" == *"zenity"* || "$winetricks_launcher" == *"kdialog"* || "$winetricks_launcher" == *"Terminal"* ]]; then
  echo "ASSERT failed: Cyder Winetricks integration should not expose the upstream TUI or Terminal fallback" >&2
  exit 1
fi
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder_common.py" "$RES/ogom-scripts/"' \
  "the PE icon extraction helper must include its common module"
assert_contains "$build_script" 'xattr -cr "$APP"' \
  "Cyder.app packaging must clear nested quarantine attributes before signing"
assert_contains "$copy_script" 'xattr -c "$dest_archive"' \
  "engine archive payload must not retain quarantine from the source"
assert_contains "$common_script" 'if [[ ! -f "$dest/.cyder-engine-signed" ]]' \
  "existing engines must be signed once before launch"
assert_contains "$common_script" "printf 'signed\\n' >\"\$dest/.cyder-engine-signed\"" \
  "successful engine signing must leave a marker"

assert test -x "$ROOT/tools/winetricks/winetricks"
assert test -x "$ROOT/tools/zstd/zstd"
assert_contains "$(head -20 "$ROOT/tools/winetricks/winetricks")" "WINETRICKS_VERSION=20260125" \
  "bundled Winetricks version should be pinned"
oem_build_script="$(cat "$ROOT/scripts/create-cyder-maplestory-oem-app.sh")"
assert_contains "$oem_build_script" 'Set :CFBundleExecutable CyderMapleStoryOEM' \
  "OEM packaging should set a distinct CFBundleExecutable"
assert_contains "$oem_build_script" 'cp "$SCRIPT_DIR/cyder_maplestory_oem_main.sh" "$MACOS/CyderMapleStoryOEM"' \
  "OEM packaging should rename its primary launcher executable"
assert_contains "$oem_build_script" 'for helper in CyderOEMBootstrap CyderMapleStoryOEM; do' \
  "OEM signing should include the renamed launcher"
if [[ "$oem_build_script" == *'*/MacOS/Cyder |'* ]]; then
  echo "ASSERT failed: OEM payload signing should no longer whitelist the old Cyder launcher path" >&2
  exit 1
fi

echo "PASS test-cyder-app-payload"
