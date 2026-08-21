#!/usr/bin/env bash
# Apply validated Cyder UI settings to the active shared Wine prefix.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$_SCRIPT_DIR/cyder-common.sh"
unset _SCRIPT_DIR

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
retina="${CYDER_RETINA_MODE:-0}"
dpi="${CYDER_DPI:-96}"
smoothing="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"

[[ "$retina" == 0 || "$retina" == 1 ]] || retina=0
[[ "$dpi" =~ ^[0-9]+$ ]] && (( dpi >= 72 && dpi <= 480 )) || dpi=96
case "$smoothing" in off|grayscale|cleartype-rgb|cleartype-bgr) ;; *) smoothing=cleartype-rgb ;; esac

mingliu_target="${CYDER_FONT_MINGLIU_TARGET:-}"
songti_target="${CYDER_FONT_SONGTI_TARGET:-}"
if [[ -z "$mingliu_target" || -z "$songti_target" ]]; then
  legacy="${CYDER_FONT_PRESET:-songti}"
  { read -r _def_ming; read -r _def_song; } < <(cyder_migrate_font_targets_from_preset "$legacy")
  mingliu_target="${mingliu_target:-$_def_ming}"
  songti_target="${songti_target:-$_def_song}"
  unset _def_ming _def_song
fi
cyder_font_target_is_valid "$mingliu_target" || mingliu_target="$(cyder_detect_default_mingliu_target)"
cyder_font_target_is_valid "$songti_target" || songti_target=songti

case "$smoothing" in
  off)
    smooth=0; smooth_type=1; gamma=0; orientation=1 ;;
  grayscale)
    smooth=2; smooth_type=1; gamma=0; orientation=1 ;;
  cleartype-rgb)
    smooth=2; smooth_type=2; gamma=1400; orientation=1 ;;
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
face_for() {
  # Strip trailing newline from shared helper for wine reg /d values.
  cyder_font_face_for_target "$1" | tr -d '\n'
}
font_ledger_line() {
  local name="$1" key="font-$name" value
  value="$(state_value "$key" 2>/dev/null || true)"
  [[ -n "$value" ]] || return 0
  printf 'font-%s\t%s\n' "$name" "$value"
}

if [[ "$retina" == 1 ]]; then
  apply_reg_if_changed retina "$retina" add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f
else
  apply_reg_if_changed retina "$retina" add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d n /f
fi
apply_reg_if_changed dpi "$dpi" add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f
apply_reg_if_changed smoothing "$smooth" add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d "$smooth" /f
apply_reg_if_changed smoothing-type "$smooth_type" add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d "$smooth_type" /f
apply_reg_if_changed smoothing-gamma "$gamma" add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d "$gamma" /f
apply_reg_if_changed smoothing-orientation "$orientation" add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d "$orientation" /f

font_key='HKCU\Software\Wine\Fonts\Replacements'
ming_face="$(face_for "$mingliu_target")"
song_face="$(face_for "$songti_target")"

disabled_state="$(state_value font-disabled-section 2>/dev/null || true)"
legacy_section="$(state_value font-section 2>/dev/null || true)"
if [[ "${CYDER_FORCE_SETTINGS:-0}" == 1 ]] || [[ "$disabled_state" == disabled ]] || [[ "$legacy_section" == disabled ]]; then
  "${WINE[@]}" reg delete 'HKCU\Software\Wine\Fonts\Replacements(disabled)' /f 2>/dev/null || true
  state_update font-disabled-section absent
fi

for name in MingLiU PMingLiU 細明體 新細明體 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
  if [[ "$mingliu_target" == mingliu ]]; then
    delete_reg_if_changed "font-$name" "$font_key" /v "$name" /f
  else
    apply_reg_if_changed "font-$name" "$ming_face" add "$font_key" /v "$name" /t REG_SZ /d "$ming_face" /f
  fi
done
for name in @PMingLiU @細明體; do
  if [[ "$mingliu_target" == mingliu ]]; then
    delete_reg_if_changed "font-$name" "$font_key" /v "$name" /f
  else
    apply_reg_if_changed "font-$name" "@$ming_face" add "$font_key" /v "$name" /t REG_SZ /d "@$ming_face" /f
  fi
done

for name in SimSun NSimSun 宋体 新宋体; do
  apply_reg_if_changed "font-$name" "$song_face" add "$font_key" /v "$name" /t REG_SZ /d "$song_face" /f
done
for name in @SimSun @宋体; do
  apply_reg_if_changed "font-$name" "@$song_face" add "$font_key" /v "$name" /t REG_SZ /d "@$song_face" /f
done

state_dir="$(dirname "$STATE_FILE")"
mkdir -p "$state_dir"
state_tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
{
  if [[ "$retina" == 1 ]]; then
    printf 'retina\t1\n'
  else
    printf 'retina\t0\n'
  fi
  printf 'dpi\t%s\n' "$dpi"
  printf 'smoothing\t%s\n' "$smooth"
  printf 'smoothing-type\t%s\n' "$smooth_type"
  printf 'smoothing-gamma\t%s\n' "$gamma"
  printf 'smoothing-orientation\t%s\n' "$orientation"
  printf 'font-mingliu-target\t%s\n' "$mingliu_target"
  printf 'font-songti-target\t%s\n' "$songti_target"
  disabled_ledger="$(state_value font-disabled-section 2>/dev/null || true)"
  [[ -n "$disabled_ledger" ]] && printf 'font-disabled-section\t%s\n' "$disabled_ledger"
  for name in MingLiU PMingLiU 細明體 新細明體 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
    font_ledger_line "$name"
  done
  for name in @PMingLiU @細明體; do
    font_ledger_line "$name"
  done
  for name in SimSun NSimSun 宋体 新宋体; do
    font_ledger_line "$name"
  done
  for name in @SimSun @宋体; do
    font_ledger_line "$name"
  done
} >"$state_tmp"
mv -f "$state_tmp" "$STATE_FILE"

echo "Applied Cyder settings: Retina=$retina DPI=$dpi mingliu=$mingliu_target songti=$songti_target smoothing=$smoothing"
