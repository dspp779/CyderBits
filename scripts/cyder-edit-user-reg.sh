#!/usr/bin/env bash
# Fast settings path: edit Cyder-owned values in user.reg with native BSD sed.
set -euo pipefail

WINEPREFIX="${WINEPREFIX:?WINEPREFIX is required}"
USER_REG="$WINEPREFIX/user.reg"
SETTING="${CYDER_FAST_SETTING:-all}"
[[ -f "$USER_REG" ]] || { echo "user.reg is missing: $USER_REG" >&2; exit 1; }

retina="${CYDER_RETINA_MODE:-1}"
dpi="${CYDER_DPI:-192}"
smoothing="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"
font="${CYDER_FONT_PRESET:-songti}"

[[ "$retina" == 0 || "$retina" == 1 ]] || retina=1
[[ "$dpi" =~ ^[0-9]+$ ]] && (( dpi >= 72 && dpi <= 480 )) || dpi=192
case "$smoothing" in off|grayscale|cleartype-rgb|cleartype-bgr) ;; *) smoothing=cleartype-rgb ;; esac
case "$font" in songti|mingliu) ;; *) font=songti ;; esac

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

apply_font() {
  if [[ "$font" == mingliu ]]; then
    /usr/bin/sed -i '' \
      's/^\[Software\\\\Wine\\\\Fonts\\\\Replacements\]\(.*\)$/[Software\\\\Wine\\\\Fonts\\\\Replacements(disabled)]\1/' \
      "$USER_REG"
  else
    /usr/bin/sed -i '' \
      's/^\[Software\\\\Wine\\\\Fonts\\\\Replacements(disabled)\]\(.*\)$/[Software\\\\Wine\\\\Fonts\\\\Replacements]\1/' \
      "$USER_REG"
  fi
}

case "$SETTING" in
  dpi) apply_dpi ;;
  retina) apply_retina ;;
  display) apply_retina; apply_dpi ;;
  smoothing) apply_smoothing ;;
  font) apply_font ;;
  all) apply_retina; apply_dpi; apply_smoothing; apply_font ;;
  *) echo "unknown fast setting: $SETTING" >&2; exit 2 ;;
esac

echo "Applied Cyder $SETTING setting directly to $USER_REG"
