#!/usr/bin/env bash
# Build Cyder.app launcher — open Windows EXE with shared prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cyder.app runtime exports must not leak into build (OGOM → Resources/, HOMEBREW_PREFIX=/nonexistent).
unset HOMEBREW_PREFIX OGOM WINE_INSTALL ENTITLEMENTS_PLIST
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${1:-$OGOM/dist}"
APP="$OUT_DIR/Cyder.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

LOGO_PNG="$OGOM/logo/cyder-logo.png"
[[ -f "$LOGO_PNG" ]] || {
  echo "Missing app logo at logo/cyder-logo.png" >&2
  exit 1
}

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

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

mkdir -p "$RES/ogom-scripts" "$RES/addons/libarchive"
cp "$SCRIPT_DIR/cyder_launcher.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-common.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/env-x86_64.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-wine-mono.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-libarchive-tar.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/resolve-wine-locale.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/enable-mac-retina-hires.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-exe-association.swift" "$RES/ogom-scripts/"
if swiftc -O -o "$RES/ogom-scripts/cyder-exe-association" "$SCRIPT_DIR/cyder-exe-association.swift" 2>/dev/null; then
  echo "==> Compiled cyder-exe-association helper"
else
  echo "==> Warning: swiftc failed; app will use cyder-exe-association.swift (slower first launch)" >&2
fi
chmod +x "$RES/ogom-scripts/cyder_launcher.sh"

# shellcheck source=cyder-copy-engine-artifact.sh
source "$SCRIPT_DIR/cyder-copy-engine-artifact.sh"
copy_engine_artifact_into_app "$SCRIPT_DIR" "$RES" "$OGOM"
rsync -a "$OGOM/tools/libarchive/" "$RES/addons/libarchive/"

if ZSTD_BIN="$(command -v zstd 2>/dev/null || true)" && [[ -n "$ZSTD_BIN" && -x "$ZSTD_BIN" ]]; then
  echo "==> Bundling zstd for engine extract"
  mkdir -p "$RES/tools"
  cp "$ZSTD_BIN" "$RES/tools/zstd"
  chmod +x "$RES/tools/zstd"
  ZSTD_LIB_REF="$(otool -L "$ZSTD_BIN" | awk '/libzstd/ {print $1; exit}')"
  if [[ -n "$ZSTD_LIB_REF" ]]; then
    ZSTD_LIB_SRC="$ZSTD_LIB_REF"
    if [[ "$ZSTD_LIB_REF" == @rpath/* ]]; then
      ZSTD_LIB_SRC="$(cd "$(dirname "$ZSTD_BIN")/../lib" && pwd)/$(basename "$ZSTD_LIB_REF")"
    fi
    if [[ -f "$ZSTD_LIB_SRC" ]]; then
      cp -f "$ZSTD_LIB_SRC" "$RES/tools/"
      install_name_tool -change "$ZSTD_LIB_REF" "@loader_path/$(basename "$ZSTD_LIB_SRC")" "$RES/tools/zstd" 2>/dev/null || true
    fi
  fi
  codesign --force --sign - "$RES/tools/zstd" 2>/dev/null || true
else
  echo "==> Warning: zstd not found; engine extract relies on system tar" >&2
fi

echo "==> Building MacOS/Cyder (Swift front-end for Finder open-document events)"
if swiftc -O -o "$MACOS/Cyder" "$SCRIPT_DIR/cyder_app_main.swift" 2>/dev/null; then
  echo "==> Compiled cyder_app_main.swift"
else
  echo "==> Warning: swiftc failed; using bash launcher (double-click .exe may not pass path)" >&2
  cat > "$MACOS/Cyder" <<LAUNCHER
#!/bin/bash
set -euo pipefail
SELF="\$(cd "\$(dirname "\$0")" && pwd)"
RES="\$(cd "\$SELF/../Resources" && pwd)"

ENGINE_VER="\$(tr -d '[:space:]' < "\$RES/engine-version.txt" 2>/dev/null || true)"
if [[ -n "\$ENGINE_VER" && -f "\$RES/engine-\${ENGINE_VER}.tar.zst" ]]; then
  ENGINE_SRC="\$RES/engine-\${ENGINE_VER}.tar.zst"
elif [[ -n "\$ENGINE_VER" && -f "\$RES/engine-wine-x86_64-\${ENGINE_VER}.tar.xz" ]]; then
  ENGINE_SRC="\$RES/engine-wine-x86_64-\${ENGINE_VER}.tar.xz"
else
  ENGINE_SRC="\$RES/engine-payload"
fi

export CYDER_ENGINE_SRC="\$ENGINE_SRC"
export CYDER_SCRIPTS="\$RES/ogom-scripts"
export CYDER_LIBARCHIVE_SRC="\$RES/addons/libarchive"

export OGOM="\$RES"
export WINE_INSTALL="\$ENGINE_SRC"
export ENTITLEMENTS_PLIST="\$RES/entitlements.plist"
export CYDER_ENTITLEMENTS="\$RES/entitlements.plist"
export CYDER_APP="\$(cd "\$SELF/.." && pwd)"
export CYDER_BUNDLE_ID="local.cyder.app"

exec "\$RES/ogom-scripts/cyder_launcher.sh" --engine-src "\$ENGINE_SRC" "\$@"
LAUNCHER
  chmod +x "$MACOS/Cyder"
fi

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
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Windows Executable</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>exe</string>
      </array>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.microsoft.windows-executable</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo ""
echo "Created $APP"
echo "Open: open \"$APP\""
echo "CLI:  bash scripts/cyder_launcher.sh --engine-src install/wine-x86_64 /path/to/game.exe"
