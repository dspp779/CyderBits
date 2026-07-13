#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${1:-$ROOT/dist/CyderPIDTest.app}"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-pid-test.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

SDK="${CYDER_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$BUILD_DIR/module-cache"

swiftc -O -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" \
  -target arm64-apple-macosx12.0 \
  -o "$BUILD_DIR/CyderPIDTest-arm64" \
  "$SCRIPT_DIR/cyder_pid_test_launcher.swift"

swiftc -O -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" \
  -target x86_64-apple-macosx12.0 \
  -o "$BUILD_DIR/CyderPIDTest-x86_64" \
  "$SCRIPT_DIR/cyder_pid_test_launcher.swift"

lipo -create \
  "$BUILD_DIR/CyderPIDTest-arm64" \
  "$BUILD_DIR/CyderPIDTest-x86_64" \
  -output "$MACOS/CyderPIDTest"
chmod +x "$MACOS/CyderPIDTest"

cp "$ROOT/config/CyderPIDTest-Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/dist/Cyder.app/Contents/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/dist/Cyder.app/Contents/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
  plutil -insert CFBundleIconFile -string AppIcon "$CONTENTS/Info.plist"
fi

codesign --force --deep --sign - "$APP"
echo "Created $APP"
