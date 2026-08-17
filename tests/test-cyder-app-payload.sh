#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

build_script="$(cat "$ROOT/scripts/create-cyder-app.sh")"
common_script="$(cat "$ROOT/scripts/cyder-common.sh")"
copy_script="$(cat "$ROOT/scripts/cyder-copy-engine-artifact.sh")"
assert_contains "$build_script" 'arm64-apple-macosx11.0' \
  "CyderSwift arm64 deployment target must support macOS 11"
assert_contains "$build_script" 'x86_64-apple-macosx11.0' \
  "CyderSwift x86_64 deployment target must support macOS 11"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the runtime signing helper"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-macos-compat.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the macOS compatibility helper"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-catalina-bootstrap.command" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the visible Catalina first-run bootstrap"
assert_not_contains "$build_script" 'CyderLegacyUI.app' \
  "Cyder.app must not package the removed Catalina applet"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-macos-wrapper.sh" "$MACOS/Cyder"' \
  "Cyder.app entrypoint must be the OS-version wrapper"
assert_contains "$build_script" '<string>10.15</string>' \
  "Info.plist LSMinimumSystemVersion must match the Wine engine floor"
assert_contains "$build_script" '<key>CyderRecommendedGamesDirectory</key>' \
  "Info.plist must declare the recommended ~/Games location"
assert_contains "$build_script" '<key>NSDocumentsFolderUsageDescription</key>' \
  "Info.plist must explain Documents folder access"
assert_contains "$build_script" '<key>NSDesktopFolderUsageDescription</key>' \
  "Info.plist must explain Desktop folder access"
assert_contains "$build_script" '<key>NSDownloadsFolderUsageDescription</key>' \
  "Info.plist must explain Downloads folder access"
assert_contains "$build_script" '<key>NSRemovableVolumesUsageDescription</key>' \
  "Info.plist must explain on-demand removable-volume access"
assert_contains "$build_script" '<key>NSNetworkVolumesUsageDescription</key>' \
  "Info.plist must explain on-demand network-volume access"
assert_contains "$build_script" '<key>CFBundleTypeIconFile</key>' \
  "Info.plist must declare a document icon for .exe"
assert_contains "$build_script" '<key>CFBundleURLTypes</key>' \
  "Info.plist must declare custom URL schemes"
assert_contains "$build_script" '<string>gamaniagames</string>' \
  "Info.plist must declare gamaniagames url scheme"
assert_contains "$build_script" 'cyder_uri_handler.swift' \
  "CyderSwift build must include the uri handler module"
assert_contains "$build_script" '<key>UTImportedTypeDeclarations</key>' \
  "Info.plist must import the Windows executable UTI with an icon"
assert_contains "$build_script" '<key>UTTypeIconFile</key>' \
  "imported Windows executable UTI must reference AppIcon"
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
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-ensure-graphics.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the graphics payload ensurer"
assert_contains "$build_script" 'cp "$SCRIPT_DIR/cyder-migrate-graphics-prefix.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the graphics prefix migration helper"
assert_contains "$build_script" 'chmod +x "$RES/ogom-scripts/cyder-ensure-graphics.sh"' \
  "Cyder.app must mark ensure-graphics executable"
assert_contains "$build_script" 'chmod +x "$RES/ogom-scripts/cyder-migrate-graphics-prefix.sh"' \
  "Cyder.app must mark migrate-graphics executable"
assert_contains "$build_script" 'GRAPHICS_ARTIFACTS=' \
  "Cyder.app packaging must copy Resources/graphics artifacts"
assert_not_contains "$build_script" 'dxvk2-version.txt' \
  "Cyder.app packaging must not require the deferred DXVK 2 graphics sidecar"
assert_contains "$build_script" 'cp "$GRAPHICS_ARTIFACTS"/dxvk-*.tar.zst "$RES/graphics/"' \
  "Cyder.app packaging must copy only the supported DXVK payload"
assert_not_contains "$build_script" 'rsync -a "$GRAPHICS_ARTIFACTS/" "$RES/graphics/"' \
  "Cyder.app packaging must not copy deferred graphics artifacts"
assert_contains "$build_script" 'CYDER_ALLOW_MISSING_GRAPHICS' \
  "Cyder.app packaging must fail closed on missing graphics unless explicitly allowed"
assert_not_contains "$build_script" 'install-dxvk-prefix.sh' \
  "Cyder.app must not bundle obsolete DXVK prefix PE provisioner"
assert_not_contains "$build_script" 'cyder-oem-sync-dxvk.sh' \
  "Cyder.app must not bundle the obsolete OEM DXVK sidecar repair helper"
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
assert_contains "$build_script" 'codesign --verify --strict "$path"' \
  "Cyder.app packaging must strictly verify each signed nested Mach-O"
assert_contains "$build_script" 'codesign --verify --deep --strict --verbose=2 "$APP"' \
  "Cyder.app packaging must strictly verify the final signed bundle"
assert_contains "$copy_script" 'xattr -c "$dest_archive"' \
  "engine archive payload must not retain quarantine from the source"
assert_contains "$copy_script" 'engine-artifact-sha256.txt' \
  "engine payload must include a fingerprint for same-label refreshes"
assert_not_contains "$build_script" 'moltenvk-wait-poll' \
  "Cyder.app must not build or bundle the engine-owned MoltenVK shim"
assert_not_contains "$common_script" 'cyder_ensure_moltenvk_wait_poll_shim' \
  "runtime must not mutate the installed engine with an App overlay"
assert_contains "$common_script" 'if [[ ! -f "$dest/.cyder-engine-signed" ]]' \
  "existing engines must be signed once before launch"
assert_contains "$common_script" "printf 'signed\\n' >\"\$dest/.cyder-engine-signed\"" \
  "successful engine signing must leave a marker"
assert_contains "$common_script" '.cyder-engine-artifact-sha256' \
  "installed engine must retain the bundled artifact fingerprint"

assert test -x "$ROOT/tools/winetricks/winetricks"
assert test -x "$ROOT/tools/zstd/zstd"
assert_contains "$(head -20 "$ROOT/tools/winetricks/winetricks")" "WINETRICKS_VERSION=20260125" \
  "bundled Winetricks version should be pinned"
oem_build_script="$(cat "$ROOT/scripts/create-cyder-maplestory-oem-app.sh")"
assert_contains "$oem_build_script" 'Set :CFBundleExecutable CyderMapleStoryOEM' \
  "OEM packaging should set a distinct CFBundleExecutable"
assert_contains "$oem_build_script" 'cp "$SCRIPT_DIR/cyder_maplestory_oem_main.sh" "$MACOS/CyderMapleStoryOEM"' \
  "OEM packaging should rename its primary launcher executable"
assert_contains "$oem_build_script" 'rm -f "$MACOS/Cyder"' \
  "OEM packaging should remove the inherited base launcher"
assert_contains "$oem_build_script" 'for helper in CyderOEMBootstrap CyderMapleStoryOEM; do' \
  "OEM signing should include the renamed launcher"
assert_contains "$oem_build_script" 'CYDER_GRAPHICS_BACKEND_PATH' \
  "OEM packaging should validate the Cyder graphics backend hook"
assert_contains "$oem_build_script" 'external Resources/graphics' \
  "OEM packaging should keep graphics payloads external to the engine"
assert_not_contains "$oem_build_script" 'DXVK_SRC' \
  "OEM packaging must not inject a DXVK tree into the engine"
assert_not_contains "$oem_build_script" 'cyder-oem-sync-dxvk.sh' \
  "OEM packaging must not retain the removed DXVK repair path"
if [[ "$oem_build_script" == *'*/MacOS/Cyder |'* ]]; then
  echo "ASSERT failed: OEM payload signing should no longer whitelist the old Cyder launcher path" >&2
  exit 1
fi

echo "PASS test-cyder-app-payload"
