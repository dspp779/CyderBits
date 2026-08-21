#!/usr/bin/env bash
# Create a thin macOS .app that launches a Windows EXE through Cyder.app.
# Does not embed Wine; the wrapper exits immediately after handing off to Cyder.
set -euo pipefail

usage() {
  echo "Usage: cyder-create-mac-launcher.sh --exe UNIX.exe --cyder-app Cyder.app --output Game.app [--name NAME] [--icon-png icon.png] [--bundle-id ID]" >&2
  exit 1
}

EXE=""
CYDER_APP=""
OUTPUT=""
NAME=""
ICON_PNG=""
BUNDLE_ID="local.cyder.launcher"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe) EXE="${2:-}"; shift 2 ;;
    --cyder-app) CYDER_APP="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --icon-png) ICON_PNG="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$EXE" && -f "$EXE" ]] || {
  echo "Missing or unreadable --exe" >&2
  exit 1
}
[[ -n "$CYDER_APP" && -d "$CYDER_APP" ]] || {
  echo "Missing --cyder-app bundle" >&2
  exit 1
}
[[ -n "$OUTPUT" ]] || usage

EXE="$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")"
CYDER_APP="$(cd "$CYDER_APP" && pwd)"

if [[ -z "$NAME" ]]; then
  NAME="$(basename "$EXE" .exe)"
fi

OUTPUT="${OUTPUT%.app}.app"
mkdir -p "$(dirname "$OUTPUT")"
if [[ -e "$OUTPUT" ]]; then
  rm -rf "$OUTPUT"
fi

CONTENTS="$OUTPUT/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

# Escape for embedding in the launcher script.
escape_sh() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}
CYDER_ESCAPED="$(escape_sh "$CYDER_APP")"
EXE_ESCAPED="$(escape_sh "$EXE")"

plist_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}
NAME_PLIST="$(plist_escape "$NAME")"
BUNDLE_ID_PLIST="$(plist_escape "$BUNDLE_ID")"

cat >"$MACOS/CyderGame" <<EOF
#!/bin/bash
set -euo pipefail
CYDER_APP='$CYDER_ESCAPED'
EXE='$EXE_ESCAPED'

cyder_launcher_alert() {
  local title="\$1" message="\$2"
  /usr/bin/osascript -e "display alert \\"\${title}\\" message \\"\${message}\\" as warning" >/dev/null 2>&1 || true
}

if [[ ! -d "\$CYDER_APP" ]]; then
  cyder_launcher_alert "找不到 Cyder" \\
    "這個捷徑綁定的 Cyder.app 已不存在或已搬移：
\$CYDER_APP

請開啟目前的 Cyder，在遊戲庫對該遊戲選擇「更新 macOS 應用程式」。"
  exit 1
fi

if [[ ! -f "\$EXE" ]]; then
  cyder_launcher_alert "找不到遊戲檔案" \\
    "這個捷徑指向的 EXE 已不存在（常見原因：重建了 Windows 遊戲環境，或遊戲已解除安裝）。

\$EXE

請在 Cyder 遊戲庫重新安裝／加入遊戲後，再選擇「更新 macOS 應用程式」。"
  # Open Cyder so the user can recover from Preferences / the library.
  if ! /usr/bin/open -n -a "\$CYDER_APP" >/dev/null 2>&1; then
    cyder_launcher_alert "無法開啟 Cyder" \\
      "遊戲檔案已遺失，且無法自動開啟 Cyder.app。

請手動開啟 Cyder，在遊戲庫重新安裝／加入遊戲後，再選擇「更新 macOS 應用程式」。"
  fi
  exit 1
fi

# Do not exec open: LSUIElement wrappers must catch Launch Services failures
# and show an alert (otherwise Finder launches fail with no Dock icon / UI).
if ! /usr/bin/open -n -a "\$CYDER_APP" "\$EXE"; then
  cyder_launcher_alert "無法啟動遊戲" \\
    "無法透過 Cyder 開啟這個遊戲（常見原因：Cyder.app 損壞、隔離屬性，或權限不足）。

Cyder：\$CYDER_APP
遊戲：\$EXE

請重新開啟 Cyder.app，或在遊戲庫選擇「更新 macOS 應用程式」。"
  exit 1
fi
EOF
chmod +x "$MACOS/CyderGame"

# Icon: prefer the cached PE extract (--icon-png). If the game library has not
# extracted an icon yet, the wrapper would otherwise ship with no custom icon;
# fall back to Cyder.app's AppIcon.icns so Launchpad/Finder always show something.
ICON_KEYS=""
HAS_ICON=0
if [[ -n "$ICON_PNG" && -f "$ICON_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/cyder-launcher-icon.XXXXXX")/AppIcon.iconset"
  mkdir -p "$ICONSET"
  build_size() {
    local px="$1" out="$2"
    sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET/$out" >/dev/null 2>&1
  }
  if build_size 16 icon_16x16.png \
    && build_size 32 icon_16x16@2x.png \
    && build_size 32 icon_32x32.png \
    && build_size 64 icon_32x32@2x.png \
    && build_size 128 icon_128x128.png \
    && build_size 256 icon_128x128@2x.png \
    && build_size 256 icon_256x256.png \
    && build_size 512 icon_256x256@2x.png \
    && build_size 512 icon_512x512.png \
    && build_size 1024 icon_512x512@2x.png \
    && iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" >/dev/null 2>&1; then
    HAS_ICON=1
  fi
  rm -rf "$(dirname "$ICONSET")"
fi
if [[ "$HAS_ICON" -eq 0 ]]; then
  CYDER_ICON="$CYDER_APP/Contents/Resources/AppIcon.icns"
  if [[ -f "$CYDER_ICON" ]]; then
    cp "$CYDER_ICON" "$RES/AppIcon.icns"
    HAS_ICON=1
  fi
fi
if [[ "$HAS_ICON" -eq 1 ]]; then
  ICON_KEYS='  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
'
fi

cat >"$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleExecutable</key>
  <string>CyderGame</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID_PLIST</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$NAME_PLIST</string>
${ICON_KEYS}  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUTPUT" >/dev/null 2>&1 || true
fi

printf '%s\n' "$OUTPUT"
