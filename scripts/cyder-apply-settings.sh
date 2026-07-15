#!/usr/bin/env bash
# Apply validated Cyder UI settings to the active shared Wine prefix.
set -euo pipefail

WINE_INSTALL="${WINE_INSTALL:-}"
WINEPREFIX="${WINEPREFIX:-}"
[[ -n "$WINE_INSTALL" && -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "WINE_INSTALL with bin/wine is required" >&2
  exit 1
}
[[ -n "$WINEPREFIX" ]] || {
  echo "WINEPREFIX is required" >&2
  exit 1
}

WINE=(arch -x86_64 "$WINE_INSTALL/bin/wine")
STATE_FILE="${CYDER_SETTINGS_STATE_FILE:-$WINEPREFIX/.cyder-settings-applied.tsv}"
retina="${CYDER_RETINA_MODE:-1}"
dpi="${CYDER_DPI:-192}"
font="${CYDER_FONT_PRESET:-songti}"
smoothing="${CYDER_FONT_SMOOTHING:-grayscale}"

[[ "$retina" == 0 || "$retina" == 1 ]] || retina=1
[[ "$dpi" =~ ^[0-9]+$ ]] && (( dpi >= 72 && dpi <= 480 )) || dpi=192
case "$font" in songti|mingliu) ;; *) font=songti ;; esac
case "$smoothing" in off|grayscale|cleartype-rgb|cleartype-bgr) ;; *) smoothing=grayscale ;; esac

case "$smoothing" in
  off)
    smooth=0; smooth_type=1; gamma=0; orientation=1 ;;
  grayscale)
    smooth=2; smooth_type=1; gamma=0; orientation=1 ;;
  cleartype-bgr)
    smooth=2; smooth_type=2; gamma=1400; orientation=0 ;;
  *)
    smooth=2; smooth_type=2; gamma=1400; orientation=1 ;;
esac

# Keep a small, prefix-local ledger so confirming unchanged settings does not
# rewrite every registry value.  This is intentionally not treated as the
# source of truth: callers can delete it to force a complete re-apply.
state_value() {
  [[ -f "$STATE_FILE" ]] || return 1
  awk -F '\t' -v key="$1" '$1 == key { print $2; found=1; exit } END { if (!found) exit 1 }' "$STATE_FILE"
}
state_update() {
  local key="$1" value="$2" state_dir state_tmp
  state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir"
  state_tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  if [[ -f "$STATE_FILE" ]]; then
    awk -F '\t' -v key="$key" '$1 != key' "$STATE_FILE" >"$state_tmp"
  fi
  printf '%s\t%s\n' "$key" "$value" >>"$state_tmp"
  mv -f "$state_tmp" "$STATE_FILE"
}
apply_reg_if_changed() {
  local key="$1" value="$2"
  shift 2
  if [[ "${CYDER_FORCE_SETTINGS:-0}" != 1 ]] && [[ "$(state_value "$key" 2>/dev/null || true)" == "$value" ]]; then
    return 0
  fi
  "${WINE[@]}" reg "$@"
  state_update "$key" "$value"
}
delete_reg_if_changed() {
  local key="$1"
  shift
  if [[ "${CYDER_FORCE_SETTINGS:-0}" != 1 ]] && [[ "$(state_value "$key" 2>/dev/null || true)" == absent ]]; then
    return 0
  fi
  if "${WINE[@]}" reg delete "$@" 2>/dev/null; then
    state_update "$key" absent
  fi
}

if [[ "$retina" == 1 ]]; then
  apply_reg_if_changed retina "$retina" add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f
else
  delete_reg_if_changed retina 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /f
fi
apply_reg_if_changed dpi "$dpi" add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f
apply_reg_if_changed smoothing "$smooth" add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d "$smooth" /f
apply_reg_if_changed smoothing-type "$smooth_type" add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d "$smooth_type" /f
apply_reg_if_changed smoothing-gamma "$gamma" add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d "$gamma" /f
apply_reg_if_changed smoothing-orientation "$orientation" add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d "$orientation" /f

if [[ "$font" == songti ]]; then
  face='Songti TC'
  apply_reg_if_changed font-MingLiU "$face" add 'HKCU\Software\Wine\Fonts\Replacements' /v MingLiU /t REG_SZ /d "$face" /f
else
  face='MingLiU'
  # Do not map MingLiU to itself; let Wine/macOS resolve an actually installed font.
  delete_reg_if_changed font-MingLiU 'HKCU\Software\Wine\Fonts\Replacements' /v MingLiU /f
fi
for name in PMingLiU 細明體 新細明體 SimSun NSimSun 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
  apply_reg_if_changed "font-$name" "$face" add 'HKCU\Software\Wine\Fonts\Replacements' /v "$name" /t REG_SZ /d "$face" /f
done
apply_reg_if_changed font-at-PMingLiU "@$face" add 'HKCU\Software\Wine\Fonts\Replacements' /v @PMingLiU /t REG_SZ /d "@$face" /f
apply_reg_if_changed font-at-細明體 "@$face" add 'HKCU\Software\Wine\Fonts\Replacements' /v @細明體 /t REG_SZ /d "@$face" /f

state_dir="$(dirname "$STATE_FILE")"
mkdir -p "$state_dir"
state_tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
{
  if [[ "$retina" == 1 ]]; then
    printf 'retina\t1\n'
  else
    printf 'retina\tabsent\n'
  fi
  printf 'dpi\t%s\n' "$dpi"
  printf 'smoothing\t%s\n' "$smooth"
  printf 'smoothing-type\t%s\n' "$smooth_type"
  printf 'smoothing-gamma\t%s\n' "$gamma"
  printf 'smoothing-orientation\t%s\n' "$orientation"
  printf 'font\t%s\n' "$font"
  if [[ "$font" == songti ]]; then
    printf 'font-MingLiU\tSongti TC\n'
  else
    printf 'font-MingLiU\tabsent\n'
  fi
  for name in PMingLiU 細明體 新細明體 SimSun NSimSun 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
    printf 'font-%s\t%s\n' "$name" "$face"
  done
  printf 'font-at-PMingLiU\t@%s\n' "$face"
  printf 'font-at-細明體\t@%s\n' "$face"
} >"$state_tmp"
mv -f "$state_tmp" "$STATE_FILE"

echo "Applied Cyder settings: Retina=$retina DPI=$dpi font=$font smoothing=$smoothing"
