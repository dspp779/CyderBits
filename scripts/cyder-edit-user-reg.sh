#!/usr/bin/env bash
# Fast settings path: edit Cyder-owned values in user.reg with native BSD sed.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$_SCRIPT_DIR/cyder-common.sh"
unset _SCRIPT_DIR

WINEPREFIX="${WINEPREFIX:?WINEPREFIX is required}"
USER_REG="$WINEPREFIX/user.reg"
SETTING="${CYDER_FAST_SETTING:-all}"
[[ -f "$USER_REG" ]] || { echo "user.reg is missing: $USER_REG" >&2; exit 1; }

retina="${CYDER_RETINA_MODE:-1}"
dpi="${CYDER_DPI:-192}"
smoothing="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"

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

[[ "$retina" == 0 || "$retina" == 1 ]] || retina=1
[[ "$dpi" =~ ^[0-9]+$ ]] && (( dpi >= 72 && dpi <= 480 )) || dpi=192
case "$smoothing" in off|grayscale|cleartype-rgb|cleartype-bgr) ;; *) smoothing=cleartype-rgb ;; esac

REPL_SET_NAMES=()
REPL_SET_VALUES=()
REPL_DEL_NAMES=()

face_for() {
  cyder_font_face_for_target "$1" | tr -d '\n'
}

queue_set() {
  REPL_SET_NAMES+=("$1")
  REPL_SET_VALUES+=("$2")
}

queue_del() {
  REPL_DEL_NAMES+=("$1")
}

compact_repl_sets() {
  if ((${#REPL_SET_NAMES[@]} > 0)); then
    REPL_SET_NAMES=("${REPL_SET_NAMES[@]}")
    REPL_SET_VALUES=("${REPL_SET_VALUES[@]}")
  else
    REPL_SET_NAMES=()
    REPL_SET_VALUES=()
  fi
}

compact_repl_dels() {
  if ((${#REPL_DEL_NAMES[@]} > 0)); then
    REPL_DEL_NAMES=("${REPL_DEL_NAMES[@]}")
  else
    REPL_DEL_NAMES=()
  fi
}

is_queued_del() {
  local name="$1" i
  for i in "${!REPL_DEL_NAMES[@]}"; do
    if [[ "${REPL_DEL_NAMES[$i]}" == "$name" ]]; then
      unset 'REPL_DEL_NAMES[i]'
      compact_repl_dels
      return 0
    fi
  done
  return 1
}

take_queued_set() {
  local name="$1" i
  for i in "${!REPL_SET_NAMES[@]}"; do
    if [[ "${REPL_SET_NAMES[$i]}" == "$name" ]]; then
      REPL_SET_VALUE="${REPL_SET_VALUES[$i]}"
      unset 'REPL_SET_NAMES[i]' 'REPL_SET_VALUES[i]'
      compact_repl_sets
      return 0
    fi
  done
  return 1
}

emit_pending_sets() {
  local i
  for i in "${!REPL_SET_NAMES[@]}"; do
    printf '"%s"="%s"\n' "${REPL_SET_NAMES[$i]}" "${REPL_SET_VALUES[$i]}"
  done
  REPL_SET_NAMES=()
  REPL_SET_VALUES=()
}

ensure_replacements_active() {
  /usr/bin/sed -i '' \
    's/^\[Software\\\\Wine\\\\Fonts\\\\Replacements(disabled)\]\(.*\)$/[Software\\\\Wine\\\\Fonts\\\\Replacements]\1/' \
    "$USER_REG"
}

rewrite_replacements_section() {
  local tmp in_section=0 in_disabled=0 line key
  tmp="$(mktemp "${USER_REG}.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[Software\\\\Wine\\\\Fonts\\\\Replacements\(disabled\)\] ]]; then
      in_disabled=1
      continue
    fi
    if [[ $in_disabled -eq 1 ]]; then
      if [[ "$line" =~ ^\[ ]]; then
        in_disabled=0
      else
        continue
      fi
    fi

    if [[ "$line" =~ ^\[Software\\\\Wine\\\\Fonts\\\\Replacements\] ]]; then
      in_section=1
      printf '%s\n' "$line"
      continue
    fi

    if [[ $in_section -eq 1 ]]; then
      if [[ "$line" =~ ^\[ ]]; then
        emit_pending_sets
        in_section=0
        printf '%s\n' "$line"
        continue
      fi
      if [[ "$line" =~ ^\"([^\"]+)\"= ]]; then
        key="${BASH_REMATCH[1]}"
        if is_queued_del "$key"; then
          continue
        fi
        if take_queued_set "$key"; then
          printf '"%s"="%s"\n' "$key" "$REPL_SET_VALUE"
          continue
        fi
      fi
    fi

    printf '%s\n' "$line"
  done <"$USER_REG" >"$tmp"

  if [[ $in_section -eq 1 ]]; then
    emit_pending_sets >>"$tmp"
  elif ((${#REPL_SET_NAMES[@]} > 0)); then
    {
      printf '[Software\\\\Wine\\\\Fonts\\\\Replacements] 0\n'
      emit_pending_sets
    } >>"$tmp"
  fi

  mv -f "$tmp" "$USER_REG"
}

set_reg_sz() {
  queue_set "$1" "$2"
}

del_reg_sz() {
  queue_del "$1"
}

flush_replacements() {
  ensure_replacements_active
  rewrite_replacements_section
}

apply_font_mingliu() {
  local face
  face="$(face_for "$mingliu_target")"
  for name in MingLiU PMingLiU 細明體 新細明體 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
    if [[ "$mingliu_target" == mingliu ]]; then
      del_reg_sz "$name"
    else
      set_reg_sz "$name" "$face"
    fi
  done
  for name in @PMingLiU @細明體; do
    if [[ "$mingliu_target" == mingliu ]]; then
      del_reg_sz "$name"
    else
      set_reg_sz "$name" "@$face"
    fi
  done
  flush_replacements
}

apply_font_songti() {
  local face
  face="$(face_for "$songti_target")"
  for name in SimSun NSimSun 宋体 新宋体; do
    set_reg_sz "$name" "$face"
  done
  for name in @SimSun @宋体; do
    set_reg_sz "$name" "@$face"
  done
  flush_replacements
}

apply_font() {
  apply_font_mingliu
  REPL_SET_NAMES=()
  REPL_SET_VALUES=()
  REPL_DEL_NAMES=()
  apply_font_songti
}

apply_dpi() {
  local encoded
  printf -v encoded '%08x' "$dpi"
  /usr/bin/sed -i '' \
    '/^\[Control Panel\\\\Desktop\]/,/^\[/ s/^"LogPixels"=dword:[0-9a-fA-F]\{8\}$/"LogPixels"=dword:'"$encoded"'/' \
    "$USER_REG"
}

apply_retina() {
  local value=n
  [[ "$retina" == 1 ]] && value=y
  /usr/bin/sed -i '' \
    '/^\[Software\\\\Wine\\\\Mac Driver\]/,/^\[/ s/^"RetinaMode"="[yn]"$/"RetinaMode"="'"$value"'"/' \
    "$USER_REG"
}

apply_smoothing() {
  local smooth smooth_type gamma orientation
  case "$smoothing" in
    off)           smooth=0; smooth_type=1; gamma=00000000; orientation=00000001 ;;
    grayscale)     smooth=2; smooth_type=1; gamma=00000000; orientation=00000001 ;;
    cleartype-bgr) smooth=2; smooth_type=2; gamma=00000578; orientation=00000000 ;;
    *)             smooth=2; smooth_type=2; gamma=00000578; orientation=00000001 ;;
  esac
  /usr/bin/sed -i '' \
    -e '/^\[Control Panel\\\\Desktop\]/,/^\[/ s/^"FontSmoothing"="[^"]*"$/"FontSmoothing"="'"$smooth"'"/' \
    -e '/^\[Control Panel\\\\Desktop\]/,/^\[/ s/^"FontSmoothingType"=dword:[0-9a-fA-F]\{8\}$/"FontSmoothingType"=dword:0000000'"$smooth_type"'/' \
    -e '/^\[Control Panel\\\\Desktop\]/,/^\[/ s/^"FontSmoothingGamma"=dword:[0-9a-fA-F]\{8\}$/"FontSmoothingGamma"=dword:'"$gamma"'/' \
    -e '/^\[Control Panel\\\\Desktop\]/,/^\[/ s/^"FontSmoothingOrientation"=dword:[0-9a-fA-F]\{8\}$/"FontSmoothingOrientation"=dword:'"$orientation"'/' \
    "$USER_REG"
}

case "$SETTING" in
  dpi) apply_dpi ;;
  retina) apply_retina ;;
  display) apply_retina; apply_dpi ;;
  smoothing) apply_smoothing ;;
  font) apply_font ;;
  font-mingliu) apply_font_mingliu ;;
  font-songti) apply_font_songti ;;
  all) apply_retina; apply_dpi; apply_smoothing; apply_font ;;
  *) echo "unknown fast setting: $SETTING" >&2; exit 2 ;;
esac

echo "Applied Cyder $SETTING setting directly to $USER_REG (Retina=$retina DPI=$dpi fontMingLiu=$mingliu_target fontSongti=$songti_target smoothing=$smoothing)"
