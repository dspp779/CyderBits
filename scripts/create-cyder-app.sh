#!/usr/bin/env bash
# Build Cyder.app launcher — open Windows EXE with shared prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cyder.app runtime exports must not leak into build (OGOM → Resources/, HOMEBREW_PREFIX=/nonexistent).
unset HOMEBREW_PREFIX OGOM WINE_INSTALL ENTITLEMENTS_PLIST
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${OGOM}/dist"
CYDER_APP_VERSION="${CYDER_APP_VERSION:-0.3.0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-archive)
      [[ $# -ge 2 ]] || {
        echo "--engine-archive requires PATH" >&2
        exit 1
      }
      export CYDER_BUNDLED_ENGINE_ARCHIVE="$2"
      shift 2
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [options] [OUT_DIR]

Options:
  --engine-archive PATH   Bundle this engine tarball into Cyder.app Resources
  -h, --help              Show this help

Default OUT_DIR: dist/
Without --engine-archive, uses dist/artifacts/engine-version.txt + archive from pack-engine-artifact.sh.
EOF
      exit 0
      ;;
    *)
      OUT_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "${CYDER_BUNDLED_ENGINE_ARCHIVE:-}" ]]; then
  DEFAULT_ENGINE_ARCHIVE_FILE="$OGOM/config/cyder-engine-archive.txt"
  DEFAULT_ENGINE_VERSION_FILE="$OGOM/config/cyder-engine-version.txt"
  if [[ -f "$DEFAULT_ENGINE_ARCHIVE_FILE" ]]; then
    DEFAULT_ENGINE_ARCHIVE="$(tr -d '[:space:]' <"$DEFAULT_ENGINE_ARCHIVE_FILE")"
    [[ "$DEFAULT_ENGINE_ARCHIVE" = /* ]] || DEFAULT_ENGINE_ARCHIVE="$OGOM/$DEFAULT_ENGINE_ARCHIVE"
    [[ -f "$DEFAULT_ENGINE_ARCHIVE" ]] || {
      echo "Missing pinned Cyder engine: $DEFAULT_ENGINE_ARCHIVE" >&2
      echo "Provide it at the configured path or pass --engine-archive PATH." >&2
      exit 1
    }
    export CYDER_BUNDLED_ENGINE_ARCHIVE="$DEFAULT_ENGINE_ARCHIVE"
    if [[ -f "$DEFAULT_ENGINE_VERSION_FILE" ]]; then
      export CYDER_BUNDLED_ENGINE_VERSION
      CYDER_BUNDLED_ENGINE_VERSION="$(tr -d '[:space:]' <"$DEFAULT_ENGINE_VERSION_FILE")"
    fi
  fi
fi

APP="$OUT_DIR/Cyder.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

PRESERVED_ICON=""
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  PRESERVED_ICON="$(mktemp "${TMPDIR:-/tmp}/cyder-preserved-icon.XXXXXX.icns")"
  cp "$APP/Contents/Resources/AppIcon.icns" "$PRESERVED_ICON"
elif [[ -f "$OUT_DIR/Cyder_001.app/Contents/Resources/AppIcon.icns" ]]; then
  PRESERVED_ICON="$OUT_DIR/Cyder_001.app/Contents/Resources/AppIcon.icns"
fi

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
if ! iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"; then
  echo "==> iconutil failed; building the ICNS container directly" >&2
  if perl "$SCRIPT_DIR/create-icns.pl" "$ICONSET" "$RES/AppIcon.icns"; then
    echo "==> Built AppIcon.icns with the portable fallback"
  elif [[ -n "$PRESERVED_ICON" && -f "$PRESERVED_ICON" ]]; then
    echo "==> Warning: ICNS fallback failed; reusing the previous Cyder icon" >&2
    cp "$PRESERVED_ICON" "$RES/AppIcon.icns"
  else
    echo "Failed to build AppIcon.icns and no previous Cyder icon is available" >&2
    exit 1
  fi
fi
rm -rf "$ICON_WORK"
if [[ "$PRESERVED_ICON" == "${TMPDIR:-/tmp}"/cyder-preserved-icon.*.icns ]]; then
  rm -f "$PRESERVED_ICON"
fi
[[ -f "$RES/AppIcon.icns" ]] || {
  echo "Failed to build AppIcon.icns" >&2
  exit 1
}

mkdir -p "$RES/ogom-scripts" "$RES/addons/libarchive"
cp "$SCRIPT_DIR/cyder_launcher.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-common.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-ensure-rosetta.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/env-x86_64.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-wine-mono.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-wine-gecko.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-apply-golden-settings.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-libarchive-tar.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/resolve-wine-locale.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/enable-mac-retina-hires.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-songti-replacements.reg" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-cyder-font-replacements.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-apply-settings.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-profile.sh" "$RES/ogom-scripts/"
chmod +x "$RES/ogom-scripts/cyder_launcher.sh"
chmod +x "$RES/ogom-scripts/install-cyder-font-replacements.sh"
chmod +x "$RES/ogom-scripts/cyder-apply-settings.sh"
chmod +x "$RES/ogom-scripts/cyder-profile.sh"

# shellcheck source=cyder-copy-engine-artifact.sh
source "$SCRIPT_DIR/cyder-copy-engine-artifact.sh"

copy_engine_artifact_into_app "$SCRIPT_DIR" "$RES" "$OGOM"
rsync -a "$OGOM/tools/libarchive/" "$RES/addons/libarchive/"

echo "==> Building universal MacOS/Cyder (arm64 + x86_64)"
SWIFT_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-swift.XXXXXX")"
SWIFT_SOURCES=(
  "$SCRIPT_DIR/cyder_diagnostics.swift"
  "$SCRIPT_DIR/cyder_paths.swift"
  "$SCRIPT_DIR/cyder_settings.swift"
  "$SCRIPT_DIR/cyder_launch_support.swift"
  "$SCRIPT_DIR/cyder_profiles.swift"
  "$SCRIPT_DIR/cyder_settings_ui.swift"
  "$SCRIPT_DIR/cyder_app_main.swift"
)
SWIFT_OPTIMIZATION="${CYDER_SWIFT_OPTIMIZATION:--O}"
SWIFT_MODULE_CACHE="${CYDER_SWIFT_MODULE_CACHE:-$SWIFT_BUILD_DIR/module-cache}"
if [[ -n "${CYDER_MACOS_SDK:-}" ]]; then
  SWIFT_SDK="$CYDER_MACOS_SDK"
else
  # Use the SDK selected by the active Command Line Tools.  Pinning an older
  # SDK can make SwiftShims incompatible when swiftc was updated separately.
  SWIFT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
# Resolve the SDK symlink. Some Command Line Tools updates can briefly leave
# MacOSX.sdk module metadata out of sync while the versioned SDK is usable.
SWIFT_SDK="$(cd "$SWIFT_SDK" && pwd -P)"
echo "==> Swift SDK: $SWIFT_SDK"
NATIVE_CYDER=0
if swiftc "$SWIFT_OPTIMIZATION" -sdk "$SWIFT_SDK" -module-cache-path "$SWIFT_MODULE_CACHE" -target arm64-apple-macosx12.0 -o "$SWIFT_BUILD_DIR/Cyder-arm64" "${SWIFT_SOURCES[@]}" \
  && swiftc "$SWIFT_OPTIMIZATION" -sdk "$SWIFT_SDK" -module-cache-path "$SWIFT_MODULE_CACHE" -target x86_64-apple-macosx12.0 -o "$SWIFT_BUILD_DIR/Cyder-x86_64" "${SWIFT_SOURCES[@]}" \
  && lipo -create "$SWIFT_BUILD_DIR/Cyder-arm64" "$SWIFT_BUILD_DIR/Cyder-x86_64" -output "$MACOS/CyderSwift"; then
  cp "$MACOS/CyderSwift" "$MACOS/Cyder"
  chmod +x "$MACOS/Cyder" "$MACOS/CyderSwift"
  NATIVE_CYDER=1
  rm -rf "$SWIFT_BUILD_DIR"
  echo "==> Compiled universal native Cyder launcher"
else
  rm -rf "$SWIFT_BUILD_DIR"
  echo "==> Warning: universal Swift build failed; using bash launcher (double-click .exe may not pass path)" >&2
  cat > "$MACOS/CyderSwift" <<LAUNCHER
#!/bin/bash
set -euo pipefail
SELF="\$(cd "\$(dirname "\$0")" && pwd)"
RES="\$(cd "\$SELF/../Resources" && pwd)"

ENGINE_ARCHIVE="\$(tr -d '[:space:]' < "\$RES/engine-archive.txt" 2>/dev/null || true)"
if [[ -n "\$ENGINE_ARCHIVE" && -f "\$RES/\$ENGINE_ARCHIVE" ]]; then
  ENGINE_SRC="\$RES/\$ENGINE_ARCHIVE"
else
  ENGINE_VER="\$(tr -d '[:space:]' < "\$RES/engine-version.txt" 2>/dev/null || true)"
  if [[ -n "\$ENGINE_VER" && -f "\$RES/engine-\${ENGINE_VER}.tar.zst" ]]; then
    ENGINE_SRC="\$RES/engine-\${ENGINE_VER}.tar.zst"
  elif [[ -n "\$ENGINE_VER" && -f "\$RES/engine-wine-x86_64-\${ENGINE_VER}.tar.xz" ]]; then
    ENGINE_SRC="\$RES/engine-wine-x86_64-\${ENGINE_VER}.tar.xz"
  else
    ENGINE_SRC="\$RES/engine-payload"
  fi
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
  chmod +x "$MACOS/CyderSwift"
fi

if [[ "$NATIVE_CYDER" -eq 0 ]]; then
cat > "$MACOS/Cyder" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"

ENGINE_ARCHIVE="$(tr -d '[:space:]' < "$RES/engine-archive.txt" 2>/dev/null || true)"
if [[ -n "$ENGINE_ARCHIVE" && -f "$RES/$ENGINE_ARCHIVE" ]]; then
  ENGINE_SRC="$RES/$ENGINE_ARCHIVE"
else
  ENGINE_VER="$(tr -d '[:space:]' < "$RES/engine-version.txt" 2>/dev/null || true)"
  if [[ -n "$ENGINE_VER" && -f "$RES/engine-$ENGINE_VER.tar.zst" ]]; then
    ENGINE_SRC="$RES/engine-$ENGINE_VER.tar.zst"
  elif [[ -n "$ENGINE_VER" && -f "$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz" ]]; then
    ENGINE_SRC="$RES/engine-wine-x86_64-$ENGINE_VER.tar.xz"
  else
    ENGINE_SRC="$RES/engine-payload"
  fi
fi

export CYDER_ENGINE_SRC="$ENGINE_SRC"
export CYDER_SCRIPTS="$RES/ogom-scripts"
export CYDER_LIBARCHIVE_SRC="$RES/addons/libarchive"
export OGOM="$RES"
export WINE_INSTALL="$ENGINE_SRC"
export ENTITLEMENTS_PLIST="$RES/entitlements.plist"
export CYDER_ENTITLEMENTS="$RES/entitlements.plist"
export CYDER_APP="$(cd "$SELF/.." && pwd)"
export CYDER_BUNDLE_ID="local.cyder.app"

for raw in "$@"; do
  [[ "$raw" == "--args" || "$raw" == -psn_* ]] && continue
  path="${raw#file://}"
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *.exe ]]; then
    exec "$RES/ogom-scripts/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-exe "$path"
  fi
done

# No document was opened: launch the AppKit settings UI only when needed.
exec "$SELF/CyderSwift"
LAUNCHER
chmod +x "$MACOS/Cyder"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
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
  <string>$CYDER_APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$CYDER_APP_VERSION</string>
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
echo "CLI:  bash scripts/cyder_launcher.sh --engine-src install/wine-cx26-x86_64 /path/to/game.exe"
