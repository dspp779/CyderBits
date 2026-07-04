#!/usr/bin/env bash
# Build a double-clickable BlueCG.app with relocatable Wine + game prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${1:-$OGOM/dist}"
APP="$OUT_DIR/BlueCG.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
LINK_PREFIX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link-prefix) LINK_PREFIX=1 ;;
    --output)
      OUT_DIR="$2"
      APP="$OUT_DIR/BlueCG.app"
      CONTENTS="$APP/Contents"
      MACOS="$CONTENTS/MacOS"
      RES="$CONTENTS/Resources"
      shift
      ;;
    -h|--help)
      echo "Usage: bash scripts/create-bluecg-app.sh [--output DIR] [--link-prefix]"
      echo "  --link-prefix  Symlink BlueCrossgateNew instead of copying (dev only)"
      exit 0
      ;;
  esac
  shift
done

[[ -x "$WINE_INSTALL/bin/wine" ]] || { echo "Missing wine at $WINE_INSTALL" >&2; exit 1; }
[[ -d "$BLUECG_PREFIX" ]] || { echo "Missing prefix $BLUECG_PREFIX" >&2; exit 1; }

echo "==> Bundling relocatable dylibs into Wine runtime"
bash "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$WINE_INSTALL"

echo "==> Signing Wine runtime"
bash "$SCRIPT_DIR/sign-wine.sh"

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Copying Wine runtime"
rsync -a --delete \
  --exclude 'share/wine/winmd' \
  "$WINE_INSTALL/" "$RES/wine/"

echo "==> Adding game prefix"
if [[ "$LINK_PREFIX" -eq 1 ]]; then
  ln -sfn "$BLUECG_PREFIX" "$RES/prefix"
  echo "    (symlinked prefix for development)"
else
  rsync -a --delete \
    --exclude 'dosdevices' \
    "$BLUECG_PREFIX/" "$RES/prefix/"
  # recreate dosdevices for the new location
  mkdir -p "$RES/prefix/dosdevices"
  ln -sfn ../drive_c "$RES/prefix/dosdevices/c:"
  ln -sfn / "$RES/prefix/dosdevices/z:"
fi

# entitlements for re-sign on target machine
cp "$ENTITLEMENTS_PLIST" "$RES/entitlements.plist"

cat > "$MACOS/BlueCG" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
# Resolve app bundle Contents/ even when launched from Finder
SELF="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$(cd "$SELF/.." && pwd)"
RES="$CONTENTS/Resources"
WINE_ROOT="$RES/wine"
PREFIX="$RES/prefix"

export WINEPREFIX="$PREFIX"
export LANG="${LANG:-zh_TW.UTF-8}"
export PATH="$WINE_ROOT/bin:$PATH"

# Optional: suppress Gecko dialog (banner HTML only)
# export WINEDLLOVERRIDES="mshtml="

cd "$PREFIX"
# Prefer arch -x86_64 on Apple Silicon; fall back on Intel.
if arch -x86_64 true 2>/dev/null; then
  exec arch -x86_64 "$WINE_ROOT/bin/wine" BlueLauncher.exe
else
  exec "$WINE_ROOT/bin/wine" BlueLauncher.exe
fi
LAUNCHER
chmod +x "$MACOS/BlueCG"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleExecutable</key>
  <string>BlueCG</string>
  <key>CFBundleIdentifier</key>
  <string>local.ogom.bluecg</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BlueCG</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign the app launcher script's wine binaries already signed;
# sign the outer app for Gatekeeper friendliness (ad-hoc).
codesign --force --deep --sign - \
  --entitlements "$RES/entitlements.plist" \
  --options runtime \
  "$APP" 2>/dev/null || codesign --force --sign - "$MACOS/BlueCG"

SIZE=$(du -sh "$APP" | awk '{print $1}')
echo ""
echo "Created $APP ($SIZE)"
echo "Open with: open \"$APP\""
echo "On another Mac (same path layout inside the .app is self-contained):"
echo "  xattr -cr \"$APP\" && codesign --force --deep --sign - --entitlements \"$APP/Contents/Resources/entitlements.plist\" --options runtime \"$APP\""
