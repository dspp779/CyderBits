#!/usr/bin/env bash
# MacOS/Cyder — thin entrypoint for Cyder.app.
# EXE arguments always go directly to the Bash launcher. With no EXE argument,
# macOS 11+ uses the Swift preferences / game-library UI; Catalina retains only
# the shell choose-file fallback. Engine floor remains 10.15
# for the current CX26 artifact; see
# cyder_apply_moltenvk_os_floor.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
SCRIPTS="$RES/ogom-scripts"

# shellcheck source=cyder-macos-compat.sh
source "$SCRIPTS/cyder-macos-compat.sh"

ENGINE_ARCHIVE="$(tr -d '[:space:]' <"$RES/engine-archive.txt" 2>/dev/null || true)"
if [[ -n "$ENGINE_ARCHIVE" && -f "$RES/$ENGINE_ARCHIVE" ]]; then
  ENGINE_SRC="$RES/$ENGINE_ARCHIVE"
else
  ENGINE_VER="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$RES/engine-version.txt" 2>/dev/null | head -n 1 || true)"
  ENGINE_VER_SLUG="$(printf '%s' "$ENGINE_VER" | tr ' .()/' '-' | tr -s '-')"
  ENGINE_VER_SLUG="${ENGINE_VER_SLUG#-}"
  ENGINE_VER_SLUG="${ENGINE_VER_SLUG%-}"
  if [[ -n "$ENGINE_VER" && -f "$RES/engine-$ENGINE_VER.tar.zst" ]]; then
    ENGINE_SRC="$RES/engine-$ENGINE_VER.tar.zst"
  elif [[ -n "$ENGINE_VER_SLUG" && -f "$RES/engine-$ENGINE_VER_SLUG.tar.zst" ]]; then
    ENGINE_SRC="$RES/engine-$ENGINE_VER_SLUG.tar.zst"
  elif [[ -n "$ENGINE_VER" && -f "$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz" ]]; then
    ENGINE_SRC="$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz"
  elif [[ -n "$ENGINE_VER_SLUG" && -f "$RES/engine-wine-x86_64-$ENGINE_VER_SLUG.tar.xz" ]]; then
    ENGINE_SRC="$RES/engine-wine-x86_64-$ENGINE_VER_SLUG.tar.xz"
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

cyder_catalina_environment_ready() {
  # shellcheck source=cyder-common.sh
  source "$SCRIPTS/cyder-common.sh"
  cyder_init_paths "$RES"
  cyder_engine_is_ready_for_launch
}

cyder_start_catalina_bootstrap() {
  local bootstrap="$SCRIPTS/cyder-catalina-bootstrap.command"
  local support="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
  local pending="$support/catalina-pending-launch"
  if [[ ! -x "$bootstrap" ]]; then
    /usr/bin/osascript -e 'display alert "Cyder 無法初始化" message "App 缺少 Catalina 初始化工具，請重新安裝 Cyder。" as warning' 2>/dev/null || true
    return 1
  fi
  mkdir -p "$support"
  if (($# > 0)); then
    local tmp="${pending}.tmp.$$"
    umask 077
    printf '%s\0' "$@" >"$tmp"
    mv -f "$tmp" "$pending"
  else
    rm -f "$pending"
  fi
  if ! /usr/bin/open -a Terminal "$bootstrap"; then
    /usr/bin/osascript -e "display alert \"無法開啟終端機\" message \"Cyder 無法開啟 Terminal 進行首次初始化。

請手動開啟終端機並執行：
$bootstrap\" as warning" 2>/dev/null || true
    return 1
  fi
}

# Catalina / non-Mach-O CyderSwift: launch via Bash and surface failures visually.
# Finder launches of Cyder.app are LSUIElement, so stderr-only exits look like a no-op.
cyder_exec_launcher_with_alert() {
  set +e
  "$SCRIPTS/cyder_launcher.sh" "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    /usr/bin/osascript -e 'display alert "無法啟動遊戲" message "Cyder 無法啟動這個 Windows 程式。請重新開啟 Cyder.app，或查看 ~/Library/Application Support/Cyder/Logs/。" as warning' 2>/dev/null || true
  fi
  exit "$status"
}

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
  if [[ -z "$exe" && ( "$lower" == *.exe || "$lower" == *.msi \
        || "$lower" == *.bat || "$lower" == *.cmd || "$lower" == *.lnk || "$lower" == *.reg ) ]]; then
    exe="$path"
  elif [[ -n "$exe" ]]; then
    game_args+=("$raw")
  fi
done

# On macOS 11+, explicit document launches also pass through the native lifecycle
# agent so the menu-bar status remains available until the bottle is idle.
# Catalina deliberately retains the shell-only fallback.
if [[ -n "$exe" ]]; then
  if cyder_macos_at_least 11 0 && [[ -x "$SELF/CyderSwift" ]] \
     && /usr/bin/file -b "$SELF/CyderSwift" 2>/dev/null | grep -q 'Mach-O'; then
    cyder_exec_cyder_swift "$SELF/CyderSwift" "$exe" "${game_args[@]}"
  fi
  if ! cyder_macos_at_least 11 0 && ! cyder_catalina_environment_ready; then
    cyder_start_catalina_bootstrap "$exe" "${game_args[@]}"
    exit $?
  fi
  lower_exe="$(printf '%s' "$exe" | tr '[:upper:]' '[:lower:]')"
  launch_flag="--launch-exe"
  case "$lower_exe" in
    *.msi) launch_flag="--launch-msi" ;;
    *.bat|*.cmd) launch_flag="--launch-script" ;;
    *.lnk) launch_flag="--launch-lnk" ;;
    *.reg) launch_flag="--launch-reg" ;;
  esac
  if ((${#game_args[@]} > 0)); then
    cyder_exec_launcher_with_alert --engine-src "$ENGINE_SRC" "$launch_flag" "$exe" -- "${game_args[@]}"
  fi
  cyder_exec_launcher_with_alert --engine-src "$ENGINE_SRC" "$launch_flag" "$exe"
fi

# With no explicit EXE, Big Sur and newer open the preferences / game library.
# Finder may still deliver an EXE later as an AppKit openFiles event; CyderSwift
# relays that event to cyder_launcher.sh and never launches Wine itself.
if cyder_macos_at_least 11 0 && [[ -x "$SELF/CyderSwift" ]]; then
  if /usr/bin/file -b "$SELF/CyderSwift" 2>/dev/null | grep -q 'Mach-O'; then
    cyder_exec_cyder_swift "$SELF/CyderSwift" "$@"
  fi
fi

# Catalina/no-native-UI fallback: Bash with the minimal system file picker.
if [[ -z "$exe" ]]; then
  if ! cyder_catalina_environment_ready; then
    cyder_start_catalina_bootstrap
    exit $?
  fi
  exe="$(cyder_choose_exe)"
fi
cyder_exec_launcher_with_alert --engine-src "$ENGINE_SRC" --launch-exe "$exe"
