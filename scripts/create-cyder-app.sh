#!/usr/bin/env bash
# Build Cyder.app launcher — open Windows EXE with shared prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cyder.app runtime exports must not leak into build (OGOM → Resources/, HOMEBREW_PREFIX=/nonexistent).
unset HOMEBREW_PREFIX OGOM WINE_INSTALL ENTITLEMENTS_PLIST
source "$SCRIPT_DIR/env-x86_64.sh"

OUT_DIR="${OGOM}/dist"
CYDER_VERSION_FILE="$SCRIPT_DIR/../config/cyder-app-version.txt"
[[ -r "$CYDER_VERSION_FILE" ]] || {
  echo "Missing Cyder app version file: $CYDER_VERSION_FILE" >&2
  exit 1
}
CYDER_APP_VERSION="${CYDER_APP_VERSION:-$(tr -d '[:space:]' <"$CYDER_VERSION_FILE")}"
# Release identity by default; export SIGN_IDENTITY=- for an unsigned local build.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Chun Ho Kwok (3U9565WWM2)}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi
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
  # mktemp on macOS requires the X's at the end of the template.
  PRESERVED_ICON="$(mktemp "${TMPDIR:-/tmp}/cyder-preserved-icon.XXXXXX")"
  cp "$APP/Contents/Resources/AppIcon.icns" "$PRESERVED_ICON"
elif [[ -f "$OUT_DIR/Cyder_001.app/Contents/Resources/AppIcon.icns" ]]; then
  PRESERVED_ICON="$OUT_DIR/Cyder_001.app/Contents/Resources/AppIcon.icns"
fi

APPICON_ZIP="$OGOM/logo/AppIcons.zip"
APPICON_DIR="$OGOM/logo/AppIcons/Assets.xcassets/AppIcon.appiconset"
LOGO_PNG="$OGOM/logo/cyder-logo.png"
if [[ ! -d "$APPICON_DIR" && -f "$APPICON_ZIP" ]]; then
  echo "==> Extracting ${APPICON_ZIP#$OGOM/}"
  unzip -qo "$APPICON_ZIP" -d "$OGOM/logo"
fi

echo "==> Creating $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$ENTITLEMENTS_PLIST" "$RES/entitlements.plist"

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyder-icon.XXXXXX")"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
if [[ -d "$APPICON_DIR" ]]; then
  echo "==> Building AppIcon.icns from logo/AppIcons appiconset"
  # Map Xcode appiconset PNGs onto iconutil's required iconset names.
  while IFS=' ' read -r src name; do
    [[ -f "$APPICON_DIR/$src" ]] || {
      echo "Missing app icon source: $APPICON_DIR/$src" >&2
      exit 1
    }
    cp "$APPICON_DIR/$src" "$ICONSET/$name"
  done <<'MAP'
16.png icon_16x16.png
32.png icon_16x16@2x.png
32.png icon_32x32.png
64.png icon_32x32@2x.png
128.png icon_128x128.png
256.png icon_128x128@2x.png
256.png icon_256x256.png
512.png icon_256x256@2x.png
512.png icon_512x512.png
1024.png icon_512x512@2x.png
MAP
else
  [[ -f "$LOGO_PNG" ]] || {
    echo "Missing app logo at logo/cyder-logo.png (and no logo/AppIcons appiconset)" >&2
    exit 1
  }
  echo "==> Building AppIcon.icns from ${LOGO_PNG#$OGOM/}"
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
fi
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
if [[ "$PRESERVED_ICON" == "${TMPDIR:-/tmp}"/cyder-preserved-icon.* ]]; then
  rm -f "$PRESERVED_ICON"
fi
[[ -f "$RES/AppIcon.icns" ]] || {
  echo "Failed to build AppIcon.icns" >&2
  exit 1
}

mkdir -p "$RES/ogom-scripts" "$RES/graphics" "$RES/addons/libarchive" "$RES/tools/zstd" "$RES/tools/cabextract" "$RES/licenses" "$RES/CompatDB" "$RES/Components/cnc-ddraw/7.1.0.0"
COMPATDB_COMPILED="$OGOM/compatdb/compiled/compatdb.cdb"
[[ -f "$OGOM/scripts/cyder-compatdb.py" ]] || {
  echo "Missing CompatDB tool: scripts/cyder-compatdb.py" >&2
  exit 1
}
[[ -f "$COMPATDB_COMPILED" ]] || {
  echo "Missing precompiled CompatDB: $COMPATDB_COMPILED" >&2
  echo "Run: python3 scripts/cyder-compatdb.py compile compatdb/rules -o compatdb/compiled/compatdb.cdb" >&2
  exit 1
}
cp "$COMPATDB_COMPILED" "$RES/CompatDB/compatdb.cdb"
python3 "$OGOM/scripts/cyder-compatdb.py" inspect "$RES/CompatDB/compatdb.cdb" >/dev/null
cp "$SCRIPT_DIR/cyder_launcher.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-common.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-ensure-graphics.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-migrate-graphics-prefix.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-ensure-rosetta.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-macos-compat.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-catalina-bootstrap.command" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/env-x86_64.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/sign-wine.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-wine-mono.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-wine-gecko.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-download-locked.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-prefetch-bootstrap-msi.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-apply-golden-settings.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-libarchive-tar.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/resolve-wine-locale.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/enable-mac-retina-hires.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-songti-replacements.reg" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/install-cyder-font-replacements.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-apply-settings.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-edit-user-reg.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-winetricks.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-recipe.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-cnc-ddraw.sh" "$RES/ogom-scripts/"
cp "$OGOM/tools/winetricks/winetricks" "$RES/ogom-scripts/"
cp "$OGOM/tools/winetricks/COPYING" "$RES/licenses/winetricks-COPYING"
"$SCRIPT_DIR/cyder-cnc-ddraw.sh" verify \
  "$OGOM/vendor/cnc-ddraw/7.1.0.0" >/dev/null
cp "$OGOM/vendor/cnc-ddraw/7.1.0.0/cnc-ddraw.zip" \
  "$RES/Components/cnc-ddraw/7.1.0.0/"
cp "$OGOM/vendor/cnc-ddraw/7.1.0.0/manifest.json" \
  "$RES/Components/cnc-ddraw/7.1.0.0/"
cp "$OGOM/vendor/cnc-ddraw/7.1.0.0/LICENSE" \
  "$RES/Components/cnc-ddraw/7.1.0.0/"
cp "$OGOM/vendor/cnc-ddraw/7.1.0.0/LICENSE" \
  "$RES/licenses/cnc-ddraw-LICENSE"
[[ -x "$OGOM/tools/zstd/zstd" ]] || {
  echo "Missing universal zstd at tools/zstd/zstd; run scripts/build-universal-zstd.sh" >&2
  exit 1
}
cp "$OGOM/tools/zstd/zstd" "$RES/tools/zstd/zstd"
cp "$OGOM/tools/zstd/LICENSE" "$RES/licenses/zstd-LICENSE"
[[ -x "$OGOM/tools/cabextract/cabextract" ]] || {
  echo "Missing universal cabextract at tools/cabextract/cabextract; run scripts/build-universal-cabextract.sh" >&2
  exit 1
}
cp "$OGOM/tools/cabextract/cabextract" "$RES/tools/cabextract/cabextract"
if [[ -f "$OGOM/tools/cabextract/COPYING" ]]; then
  cp "$OGOM/tools/cabextract/COPYING" "$RES/licenses/cabextract-COPYING"
fi

cp "$SCRIPT_DIR/cyder-profile.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-extract-exe-icon.sh" "$RES/ogom-scripts/"
cp "$SCRIPT_DIR/cyder-create-mac-launcher.sh" "$RES/ogom-scripts/"
chmod +x "$RES/ogom-scripts/cyder-extract-exe-icon.sh"
chmod +x "$RES/ogom-scripts/cyder-create-mac-launcher.sh"
chmod +x "$RES/ogom-scripts/cyder_launcher.sh"
chmod +x "$RES/ogom-scripts/cyder-ensure-graphics.sh"
chmod +x "$RES/ogom-scripts/cyder-migrate-graphics-prefix.sh"
chmod +x "$RES/ogom-scripts/cyder-macos-compat.sh"
chmod +x "$RES/ogom-scripts/cyder-catalina-bootstrap.command"
chmod +x "$RES/ogom-scripts/sign-wine.sh"
chmod +x "$RES/ogom-scripts/install-cyder-font-replacements.sh"
chmod +x "$RES/ogom-scripts/cyder-apply-settings.sh"
chmod +x "$RES/ogom-scripts/cyder-edit-user-reg.sh"
chmod +x "$RES/ogom-scripts/cyder-winetricks.sh"
chmod +x "$RES/ogom-scripts/cyder-recipe.sh"
chmod +x "$RES/ogom-scripts/cyder-cnc-ddraw.sh"
chmod +x "$RES/ogom-scripts/winetricks"
chmod +x "$RES/ogom-scripts/cyder-profile.sh"
chmod +x "$RES/tools/zstd/zstd"
chmod +x "$RES/tools/cabextract/cabextract"


# shellcheck source=cyder-copy-engine-artifact.sh
source "$SCRIPT_DIR/cyder-copy-engine-artifact.sh"

copy_engine_artifact_into_app "$SCRIPT_DIR" "$RES" "$OGOM"
GRAPHICS_ARTIFACTS="$OGOM/dist/artifacts/graphics"
if [[ -f "$GRAPHICS_ARTIFACTS/dxvk-version.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxmt-version.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxvk-artifact-sha256.txt" \
   && -f "$GRAPHICS_ARTIFACTS/dxmt-artifact-sha256.txt" ]] \
   && compgen -G "$GRAPHICS_ARTIFACTS/dxvk-*.tar.zst" >/dev/null \
   && compgen -G "$GRAPHICS_ARTIFACTS/dxmt-*.tar.zst" >/dev/null; then
  mkdir -p "$RES/graphics"
  cp "$GRAPHICS_ARTIFACTS"/dxvk-*.tar.zst "$RES/graphics/"
  cp "$GRAPHICS_ARTIFACTS"/dxvk-version.txt \
     "$GRAPHICS_ARTIFACTS"/dxvk-artifact-sha256.txt "$RES/graphics/"
  cp "$GRAPHICS_ARTIFACTS"/dxmt-*.tar.zst "$RES/graphics/"
  cp "$GRAPHICS_ARTIFACTS"/dxmt-version.txt \
     "$GRAPHICS_ARTIFACTS"/dxmt-artifact-sha256.txt "$RES/graphics/"
else
  message="Missing packaged DXVK/DXMT graphics artifacts: $GRAPHICS_ARTIFACTS"
  if [[ "${CYDER_ALLOW_MISSING_GRAPHICS:-0}" == 1 ]]; then
    echo "==> Warning: $message" >&2
  else
    echo "$message" >&2
    echo "Pack graphics first (scripts/pack-graphics-payloads.sh) or set CYDER_ALLOW_MISSING_GRAPHICS=1 for local experiments." >&2
    exit 1
  fi
fi
rsync -a "$OGOM/tools/libarchive/" "$RES/addons/libarchive/"

echo "==> Building universal MacOS/Cyder (arm64 + x86_64)"
SWIFT_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-swift.XXXXXX")"
SWIFT_SOURCES=(
  "$SCRIPT_DIR/cyder_diagnostics.swift"
  "$SCRIPT_DIR/cyder_paths.swift"
  "$SCRIPT_DIR/cyder_sentinel.swift"
  "$SCRIPT_DIR/cyder_instance.swift"
  "$SCRIPT_DIR/cyder_uri_handler.swift"
  "$SCRIPT_DIR/cyder_gptk.swift"
  "$SCRIPT_DIR/cyder_settings.swift"
  "$SCRIPT_DIR/cyder_launch_support.swift"
  "$SCRIPT_DIR/cyder_status_item.swift"
  "$SCRIPT_DIR/cyder_profiles.swift"
  "$SCRIPT_DIR/cyder_settings_ui.swift"
  "$SCRIPT_DIR/cyder_game_library.swift"
  "$SCRIPT_DIR/cyder_bottle_shortcuts.swift"
  "$SCRIPT_DIR/cyder_game_icon.swift"
  "$SCRIPT_DIR/cyder_mac_launcher.swift"
  "$SCRIPT_DIR/cyder_game_library_ui.swift"
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
if swiftc "$SWIFT_OPTIMIZATION" -sdk "$SWIFT_SDK" -module-cache-path "$SWIFT_MODULE_CACHE" -target arm64-apple-macosx11.0 -o "$SWIFT_BUILD_DIR/Cyder-arm64" "${SWIFT_SOURCES[@]}" \
  && swiftc "$SWIFT_OPTIMIZATION" -sdk "$SWIFT_SDK" -module-cache-path "$SWIFT_MODULE_CACHE" -target x86_64-apple-macosx11.0 -o "$SWIFT_BUILD_DIR/Cyder-x86_64" "${SWIFT_SOURCES[@]}" \
  && lipo -create "$SWIFT_BUILD_DIR/Cyder-arm64" "$SWIFT_BUILD_DIR/Cyder-x86_64" -output "$MACOS/CyderSwift"; then
  chmod +x "$MACOS/CyderSwift"
  rm -rf "$SWIFT_BUILD_DIR"
  echo "==> Compiled universal native CyderSwift (macOS 11+ UI)"
else
  rm -rf "$SWIFT_BUILD_DIR"
  if [[ "${CYDER_REQUIRE_NATIVE_SWIFT:-0}" == 1 ]]; then
    echo "==> Error: release build requires universal native CyderSwift" >&2
    exit 1
  fi
  echo "==> Warning: universal Swift build failed; CyderSwift falls back to shell launcher" >&2
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

# Always ship a Bash entrypoint. Explicit EXE arguments go directly to Bash;
# no-argument launches use CyderSwift on macOS 11+ and a minimal shell
# choose-file fallback on Catalina.
cp "$SCRIPT_DIR/cyder-macos-wrapper.sh" "$MACOS/Cyder"
chmod +x "$MACOS/Cyder"

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
  <string>10.15</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
    <string>x86_64</string>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CyderRecommendedGamesDirectory</key>
  <string>~/Games</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Cyder 需要讀取遊戲執行檔及同一資料夾內的 DLL 與資料檔案。</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Cyder 需要讀取遊戲執行檔及同一資料夾內的 DLL 與資料檔案。</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Cyder 需要讀取遊戲執行檔及同一資料夾內的 DLL 與資料檔案。</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Cyder 只會在您啟動外接磁碟中的遊戲時，讀取該遊戲的執行檔、DLL 與資料檔案。</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>Cyder 只會在您啟動網路磁碟中的遊戲時，讀取該遊戲的執行檔、DLL 與資料檔案。</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Windows Executable</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeIconFile</key>
      <string>AppIcon</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>exe</string>
      </array>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.microsoft.windows-executable</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Windows Installer Package</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeIconFile</key>
      <string>AppIcon</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>msi</string>
      </array>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.microsoft.windows-installer</string>
      </array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>gamania Games Manager Protocol</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>gamaniagames</string>
      </array>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.microsoft.windows-executable</string>
      <key>UTTypeDescription</key>
      <string>Windows Executable</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeIconFile</key>
      <string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>exe</string>
        </array>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.microsoft.windows-installer</string>
      <key>UTTypeDescription</key>
      <string>Windows Installer Package</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeIconFile</key>
      <string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>msi</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A downloaded source archive can carry com.apple.quarantine.  Do not carry
# that attribute into the nested runtime payload; the app itself is signed
# immediately afterwards and may still receive quarantine when downloaded.
xattr -cr "$APP" 2>/dev/null || true

sign_macho() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  file -b "$path" | grep -q 'Mach-O' || return 0
  codesign --force --options runtime "$TIMESTAMP_FLAG" \
    --entitlements "$OGOM/config/entitlements.plist" \
    --sign "$SIGN_IDENTITY" \
    "$path"
  # Stabilize Developer ID CMS data before the file is sealed into the app.
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --options runtime "$TIMESTAMP_FLAG" \
      --entitlements "$OGOM/config/entitlements.plist" \
      --sign "$SIGN_IDENTITY" \
      "$path"
  fi
  codesign --verify --strict "$path"
}

# Sign nested helpers before the main executable / bundle (inside-out).
sign_macho "$APP/Contents/Resources/tools/zstd/zstd"
sign_macho "$APP/Contents/Resources/tools/cabextract/cabextract"
sign_macho "$APP/Contents/MacOS/CyderSwift"
sign_macho "$APP/Contents/MacOS/Cyder"
while IFS= read -r -d '' path; do
  case "$path" in
    */MacOS/Cyder | */MacOS/CyderSwift | */tools/zstd/zstd | */tools/cabextract/cabextract) continue ;;
  esac
  sign_macho "$path"
done < <(find "$APP/Contents" -type f -print0)


codesign --force --options runtime "$TIMESTAMP_FLAG" \
  --entitlements "$OGOM/config/entitlements.plist" \
  --sign "$SIGN_IDENTITY" \
  "$APP"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --options runtime "$TIMESTAMP_FLAG" \
    --entitlements "$OGOM/config/entitlements.plist" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Created $APP"
echo "Open: open \"$APP\""
echo "CLI:  bash scripts/cyder_launcher.sh --engine-src install/wine-cx26-x86_64 /path/to/game.exe"
