#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

build_script="$(cat "$ROOT/scripts/create-cyder-app.sh")"
common_script="$(cat "$ROOT/scripts/cyder-common.sh")"
copy_script="$(cat "$ROOT/scripts/cyder-copy-engine-artifact.sh")"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the runtime signing helper"
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
assert_contains "$(head -20 "$ROOT/tools/winetricks/winetricks")" "WINETRICKS_VERSION=20260125" \
  "bundled Winetricks version should be pinned"

echo "PASS test-cyder-app-payload"
