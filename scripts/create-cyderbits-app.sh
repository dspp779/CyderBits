#!/usr/bin/env bash
# Build CyderBits.app — pick a Windows EXE and wrap it as a macOS app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${1:-$OGOM/dist}"
APP="$OUT_DIR/CyderBits.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

[[ -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "Missing Wine at $WINE_INSTALL — build it first." >&2
  exit 1
}

echo "==> Preparing relocatable Wine engine"
bash "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$WINE_INSTALL"
bash "$SCRIPT_DIR/sign-wine.sh"

LOGO_PNG="$OGOM/logo/cyderbits-transparent.png"
[[ -f "$LOGO_PNG" ]] || LOGO_PNG="$OGOM/logo/cyderbits.png"
[[ -f "$LOGO_PNG" ]] || {
  echo "Missing app logo at logo/cyderbits-transparent.png or logo/cyderbits.png" >&2
  exit 1
}

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$SCRIPT_DIR/cyder_create_game_app.py" "$RES/cyder_create_game_app.py"
cp "$ENTITLEMENTS_PLIST" "$RES/entitlements.plist"

echo "==> Building AppIcon.icns from ${LOGO_PNG#$OGOM/}"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyder-icon.XXXXXX")"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
while IFS=' ' read -r px name; do
  sips -z "$px" "$px" "$LOGO_PNG" --out "$ICONSET/$name" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICON_WORK"
[[ -f "$RES/AppIcon.icns" ]] || {
  echo "Failed to build AppIcon.icns" >&2
  exit 1
}

# Ship scripts needed to install/sign the shared engine on first use
mkdir -p "$RES/ogom-scripts"
cp "$SCRIPT_DIR/env-x86_64.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"
echo "==> Copying engine payload into CyderBits.app (first-run install source)"
rsync -a --delete "$WINE_INSTALL/" "$RES/engine-payload/"

cat > "$MACOS/CyderBits" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"

export CYDER_ENGINE_SRC="$RES/engine-payload"
export CYDER_SCRIPTS="$RES/ogom-scripts"

export OGOM="$RES"
export WINE_INSTALL="$RES/engine-payload"
export HOMEBREW_PREFIX="/nonexistent"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"

export PYTHONUNBUFFERED=1
python3 "$RES/cyder_create_game_app.py" --gui --engine-src "$RES/engine-payload"
LAUNCHER
chmod +x "$MACOS/CyderBits"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleExecutable</key>
  <string>CyderBits</string>
  <key>CFBundleIdentifier</key>
  <string>local.cyderbits.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CyderBits</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo ""
echo "Created $APP"
echo "Open: open \"$APP\""
echo "CLI:  python3 scripts/cyder_create_game_app.py --gui"
