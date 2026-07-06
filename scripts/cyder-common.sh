#!/usr/bin/env bash
# Shared paths and helpers for Cyder shell launcher.
set -euo pipefail

CYDER_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyder_init_paths() {
  local here="$1"
  if [[ -d "$here/engine-payload" ]]; then
    CYDER_OGOM="$here"
    CYDER_SCRIPTS="${CYDER_SCRIPTS:-$here/ogom-scripts}"
    CYDER_ENGINE_SRC="${CYDER_ENGINE_SRC:-$here/engine-payload}"
    CYDER_ENTITLEMENTS="${CYDER_ENTITLEMENTS:-$here/entitlements.plist}"
  else
    CYDER_OGOM="$(cd "$here/.." && pwd)"
    CYDER_SCRIPTS="${CYDER_SCRIPTS:-$CYDER_OGOM/scripts}"
    CYDER_ENGINE_SRC="${CYDER_ENGINE_SRC:-$CYDER_OGOM/install/wine-x86_64}"
    CYDER_ENTITLEMENTS="${CYDER_ENTITLEMENTS:-$CYDER_OGOM/config/entitlements.plist}"
  fi
  CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
  CYDER_ENGINES="$CYDER_SUPPORT/Engines"
  CYDER_ENGINE_NAME="wine-x86_64"
  CYDER_SHARED_PREFIX="${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/SharedPrefix}"
  CYDER_BOOTSTRAP_MARKER="$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
  CYDER_DOWNLOADS="$CYDER_SUPPORT/downloads"
  CYDER_EXE_ASSOC_DECLINED="$CYDER_SUPPORT/.exe-assoc-declined"
  CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.app}"
  if [[ -d "$here/engine-payload" ]]; then
    CYDER_APP="${CYDER_APP:-$(cd "$here/.." && pwd)}"
  fi
}

cyder_run() {
  echo "+ $*"
  "$@"
}

cyder_abs_path() {
  local p="$1"
  p="${p#file://}"
  p="${p/#\~/$HOME}"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  elif [[ -f "$p" ]]; then
    echo "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  else
    echo "$p"
  fi
}

cyder_choose_exe() {
  local chosen
  if ! chosen="$(osascript -e 'set f to choose file with prompt "選擇 Windows 遊戲執行檔 (.exe)" of type {"com.microsoft.windows-executable", "exe", "public.executable"}
POSIX path of f' 2>/dev/null)"; then
    echo "已取消選檔" >&2
    exit 1
  fi
  printf '%s\n' "$chosen"
}

cyder_resolve_wine_locale() {
  bash "$CYDER_SCRIPTS/resolve-wine-locale.sh"
}

cyder_wine_locale_exports() {
  local loc
  loc="$(cyder_resolve_wine_locale)"
  export LANG="$loc" LC_ALL="$loc"
}

cyder_resolve_exe_from_args() {
  local a p ext
  for a in "$@"; do
    p="$(cyder_abs_path "$a")"
    ext="$(echo "${p##*.}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" == "exe" && -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

cyder_wine_bin_for_dry_run() {
  local engine_src="$1"
  local installed="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
  if [[ -f "$installed" ]]; then
    echo "$installed"
  else
    echo "$(cyder_abs_path "$engine_src")/bin/wine"
  fi
}

cyder_ensure_shared_engine() {
  local engine_src="$1"
  local dest="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local marker="$dest/bin/wine"
  if [[ -f "$marker" ]]; then
    echo "Shared engine present: $dest" >&2
    echo "$dest"
    return 0
  fi
  echo "Installing shared engine -> $dest" >&2
  mkdir -p "$CYDER_ENGINES"
  engine_src="$(cyder_abs_path "$engine_src")"
  local bundled="$engine_src/lib/wine/x86_64-unix/libfreetype.6.dylib"
  if [[ ! -f "$bundled" || -L "$bundled" ]]; then
    local bundle_sh="$CYDER_SCRIPTS/bundle-wine-dylibs.sh"
    if [[ -f "$bundle_sh" ]]; then
      cyder_run bash "$bundle_sh" "$engine_src"
    fi
  fi
  [[ -d "$dest" ]] && rm -rf "$dest"
  cyder_run rsync -a "$engine_src/" "$dest/"
  local sign_sh="$CYDER_SCRIPTS/sign-wine.sh"
  local env_sh="$CYDER_SCRIPTS/env-x86_64.sh"
  if [[ -f "$sign_sh" ]]; then
    if [[ -f "$env_sh" ]]; then
      cyder_run bash -c "source \"$env_sh\" && WINE_INSTALL=\"$dest\" ENTITLEMENTS_PLIST=\"$CYDER_ENTITLEMENTS\" bash \"$sign_sh\" --root \"$dest\""
    else
      cyder_run bash "$sign_sh" --root "$dest" --entitlements "$CYDER_ENTITLEMENTS"
    fi
  fi
  echo "$dest"
}

cyder_init_bottle() {
  local wine_bin="$1"
  local bottle="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  if [[ -f "$bottle/system.reg" ]]; then
    echo "Bottle exists: $bottle" >&2
    return 0
  fi
  echo "Creating bottle: $bottle" >&2
  mkdir -p "$bottle"
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINEDLLOVERRIDES="mshtml=" WINESERVER="$wineserver"
    cyder_run arch -x86_64 "$wine_bin" wineboot -u
  )
  local dos="$bottle/dosdevices"
  mkdir -p "$dos"
  rm -f "$dos/c:" "$dos/z:"
  ln -sf ../drive_c "$dos/c:"
  ln -sf / "$dos/z:"
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINESERVER="$wineserver"
    arch -x86_64 "$wineserver" -k 2>/dev/null || true
  )
}

cyder_ensure_shared_prefix() {
  local wine_bin="$1"
  cyder_init_bottle "$wine_bin" "$CYDER_SHARED_PREFIX"
}

cyder_bootstrap_shared_prefix() {
  local wine_bin="$1"
  local engine_root="$2"
  cyder_ensure_shared_prefix "$wine_bin"
  if [[ -f "$CYDER_BOOTSTRAP_MARKER" ]]; then
    return 0
  fi
  local mono_sh="$CYDER_SCRIPTS/install-wine-mono.sh"
  if [[ -f "$mono_sh" ]]; then
    (
      export WINEPREFIX="$CYDER_SHARED_PREFIX"
      export WINE_INSTALL="$engine_root"
      export CYDER_DOWNLOADS="$CYDER_DOWNLOADS"
      bash "$mono_sh"
    )
  fi
  local tar_sh="$CYDER_SCRIPTS/install-libarchive-tar.sh"
  if [[ -f "$tar_sh" ]]; then
    WINE_INSTALL="$engine_root" bash "$tar_sh" --prefix "$CYDER_SHARED_PREFIX"
  fi
  local hires_sh="$CYDER_SCRIPTS/enable-mac-retina-hires.sh"
  if [[ -f "$hires_sh" ]]; then
    WINEPREFIX="$CYDER_SHARED_PREFIX" WINE_INSTALL="$engine_root" bash "$hires_sh"
  fi
  printf 'ok\n' >"$CYDER_BOOTSTRAP_MARKER"
}

cyder_run_wine_exe() {
  local wine_bin="$1"
  local exe="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  cyder_wine_locale_exports
  local log_dir="$CYDER_SUPPORT/Logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/last-launch.log"
  {
    echo "cmd=arch -x86_64 $wine_bin $exe"
    echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
    echo "cwd=$(dirname "$exe")"
    echo
  } >"$log_file"
  (
    export WINEPREFIX="$CYDER_SHARED_PREFIX" WINESERVER="$wineserver"
    export WINEMSYNC=1 WINEDLLOVERRIDES="mshtml="
    export PATH="${wine_bin%/wine}:$PATH"
    cd "$(dirname "$exe")"
    nohup arch -x86_64 "$wine_bin" "$exe" >>"$log_file" 2>&1 &
  )
}

cyder_bootstrap_error_dialog() {
  local log="$CYDER_SUPPORT/Logs/bootstrap-error.log"
  mkdir -p "$(dirname "$log")"
  echo "$1" >"$log"
  osascript -e 'display alert "Cyder 初始化失敗" message "請查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log" as warning' 2>/dev/null || true
}

cyder_exe_association_swift() {
  local tool="$CYDER_SCRIPTS/cyder-exe-association"
  local swift="$CYDER_SCRIPTS/cyder-exe-association.swift"
  if [[ -x "$tool" ]]; then
    "$tool" "$@"
  elif [[ -f "$swift" ]]; then
    swift "$swift" "$@"
  else
    return 1
  fi
}

cyder_exe_is_associated() {
  local out
  out="$(cyder_exe_association_swift status "$CYDER_BUNDLE_ID" 2>/dev/null | tail -1 || true)"
  [[ "$out" == "associated" ]]
}

cyder_maybe_prompt_exe_association() {
  if [[ -f "$CYDER_EXE_ASSOC_DECLINED" ]]; then
    return 0
  fi
  if cyder_exe_is_associated; then
    return 0
  fi

  local tool="$CYDER_SCRIPTS/cyder-exe-association"
  local swift="$CYDER_SCRIPTS/cyder-exe-association.swift"
  [[ -x "$tool" || -f "$swift" ]] || return 0

  local choice err_log="$CYDER_SUPPORT/Logs/assoc-dialog.log"
  mkdir -p "$CYDER_SUPPORT/Logs"
  choice="$(
    /usr/bin/osascript 2>"$err_log" <<'APPLESCRIPT' || true
display dialog "是否將所有 .exe 檔案預設以 Cyder 開啟？\n\n之後在 Finder 雙擊 .exe 即可直接啟動。" with title "Cyder" buttons {"不再詢問", "略過", "設為預設"} default button 3
APPLESCRIPT
  )"
  if [[ -z "$choice" && -s "$err_log" ]]; then
    echo "assoc dialog failed: $(cat "$err_log")" >>"$CYDER_SUPPORT/Logs/assoc-dialog.log"
  fi
  [[ -n "$choice" ]] || return 0

  case "$choice" in
    *設為預設*)
      local app_path="${CYDER_APP:-}"
      if [[ -z "$app_path" ]]; then
        osascript -e 'display alert "無法設定檔案關聯" message "找不到 Cyder.app 路徑。" as warning' 2>/dev/null || true
        return 0
      fi
      if cyder_exe_association_swift set "$CYDER_BUNDLE_ID" "$app_path" >/dev/null 2>&1; then
        return 0
      fi
      osascript -e 'display alert "無法設定檔案關聯" message "請在 Finder 對任一 .exe 按右鍵 → 打開方式 → Cyder → 全部更改。" as warning' 2>/dev/null || true
      ;;
    *不再詢問*)
      mkdir -p "$CYDER_SUPPORT"
      touch "$CYDER_EXE_ASSOC_DECLINED"
      ;;
  esac
}
