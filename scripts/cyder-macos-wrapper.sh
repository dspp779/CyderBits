#!/usr/bin/env bash
# MacOS/Cyder — thin entrypoint for Cyder.app.
# macOS 12+ uses the Swift UI (CyderSwift). Older hosts use bash + osascript
# progress (Retina forced off). Engine floor remains 10.15 for the current
# CX26 artifact; see cyder_apply_moltenvk_os_floor.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
SCRIPTS="$RES/ogom-scripts"

# shellcheck source=cyder-legacy-ui.sh
source "$SCRIPTS/cyder-legacy-ui.sh"

ENGINE_ARCHIVE="$(tr -d '[:space:]' <"$RES/engine-archive.txt" 2>/dev/null || true)"
if [[ -n "$ENGINE_ARCHIVE" && -f "$RES/$ENGINE_ARCHIVE" ]]; then
  ENGINE_SRC="$RES/$ENGINE_ARCHIVE"
else
  ENGINE_VER="$(tr -d '[:space:]' <"$RES/engine-version.txt" 2>/dev/null || true)"
  if [[ -n "$ENGINE_VER" && -f "$RES/engine-$ENGINE_VER.tar.zst" ]]; then
    ENGINE_SRC="$RES/engine-$ENGINE_VER.tar.zst"
  elif [[ -n "$ENGINE_VER" && -f "$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz" ]]; then
    ENGINE_SRC="$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz"
  else
    ENGINE_SRC="$RES/engine-payload"
  fi
fi

export CYDER_ENGINE_SRC="$ENGINE_SRC"
export CYDER_SCRIPTS="$SCRIPTS"
export CYDER_LIBARCHIVE_SRC="$RES/addons/libarchive"
export OGOM="$RES"
export WINE_INSTALL="$ENGINE_SRC"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"
export CYDER_ENTITLEMENTS="$RES/entitlements.plist"
export CYDER_APP="$(cd "$SELF/.." && pwd)"
export CYDER_BUNDLE_ID="local.cyder.app"

cyder_apply_moltenvk_os_floor

# Prefer Swift UI on Monterey and newer when the native binary is present.
if cyder_macos_at_least 12 0 && [[ -x "$SELF/CyderSwift" ]]; then
  if /usr/bin/file -b "$SELF/CyderSwift" 2>/dev/null | grep -q 'Mach-O'; then
    exec "$SELF/CyderSwift" "$@"
  fi
fi

# Legacy path: no Retina (hi-DPI Cocoa path is unreliable on older hosts).
export CYDER_RETINA_MODE=0

exe=""
game_args=()
saw_separator=0
for raw in "$@"; do
  [[ "$raw" == -psn_* ]] && continue
  if [[ "$saw_separator" -eq 1 ]]; then
    game_args+=("$raw")
    continue
  fi
  if [[ "$raw" == "--" ]]; then
    saw_separator=1
    continue
  fi
  path="${raw#file://}"
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *.exe && -z "$exe" ]]; then
    exe="$path"
  elif [[ -n "$exe" ]]; then
    game_args+=("$raw")
  fi
done

# Replace this process with osascript so AppleScript progress attaches to
# Cyder.app (menu-bar / script progress UI), not a detached child.
ui_script="$SCRIPTS/cyder-legacy-ui.applescript"
if [[ -f "$ui_script" ]]; then
  if [[ -n "$exe" ]]; then
    if ((${#game_args[@]} > 0)); then
      exec /usr/bin/osascript "$ui_script" "$SCRIPTS" "$ENGINE_SRC" "$exe" -- "${game_args[@]}"
    fi
    exec /usr/bin/osascript "$ui_script" "$SCRIPTS" "$ENGINE_SRC" "$exe"
  fi
  exec /usr/bin/osascript "$ui_script" "$SCRIPTS" "$ENGINE_SRC"
fi

# Fallback without the AppleScript UI bundle: direct launcher + choose-file.
if [[ -z "$exe" ]]; then
  # shellcheck source=cyder-common.sh
  source "$SCRIPTS/cyder-common.sh"
  cyder_init_paths "$RES"
  exe="$(cyder_choose_exe)"
fi
if ((${#game_args[@]} > 0)); then
  exec "$SCRIPTS/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-exe "$exe" -- "${game_args[@]}"
fi
exec "$SCRIPTS/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-exe "$exe"
