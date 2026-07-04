#!/usr/bin/env bash
# Build Cyder.app — pick a Windows EXE and wrap it as a macOS app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${1:-$OGOM/dist}"
APP="$OUT_DIR/Cyder.app"
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

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$SCRIPT_DIR/cyder_create_game_app.py" "$RES/cyder_create_game_app.py"
cp "$ENTITLEMENTS_PLIST" "$RES/entitlements.plist"

# Ship scripts needed to install/sign the shared engine on first use
mkdir -p "$RES/ogom-scripts"
cp "$SCRIPT_DIR/env-x86_64.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"
# Engine payload (relocatable)
echo "==> Copying engine payload into Cyder.app (first-run install source)"
rsync -a --delete "$WINE_INSTALL/" "$RES/engine-payload/"

cat > "$MACOS/Cyder" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"

# Point creator at bundled engine payload & helper scripts
export CYDER_ENGINE_SRC="$RES/engine-payload"
export CYDER_SCRIPTS="$RES/ogom-scripts"

# Minimal env for helper scripts (OGOM-less install)
export OGOM="$RES"
export WINE_INSTALL="$RES/engine-payload"
export HOMEBREW_PREFIX="/nonexistent"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"

export PYTHONUNBUFFERED=1
python3 "$RES/cyder_create_game_app.py" --gui --engine-src "$RES/engine-payload"
LAUNCHER
chmod +x "$MACOS/Cyder"

# Patch creator to use CYDER_SCRIPTS when bundling engine from app
# (ensure_shared_engine calls OGOM/scripts — override via env in python)

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleExecutable</key>
  <string>Cyder</string>
  <key>CFBundleIdentifier</key>
  <string>local.cyder.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Cyder</string>
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

codesign --force --sign - "$MACOS/Cyder" 2>/dev/null || true

echo ""
echo "Created $APP"
echo "Open: open \"$APP\""
echo "CLI:  python3 scripts/cyder_create_game_app.py --gui"
