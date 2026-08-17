#!/usr/bin/env bash
# Package the MapleStory OEM flavor around the shared Cyder app builder.
#
# The OEM engine archive is built separately by
# cyder-wine-engine/scripts/pack-maplestory-oem25-engine.sh.  Graphics PE
# payloads remain App resources and are installed by cyder-ensure-graphics.sh;
# this script must not inject or repair lib/dxvk inside the engine archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${CYDER_OEM_APP_OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/Cyder-maplestory-oem25.app"
BASE_APP="$OUT_DIR/Cyder.app"

ARCHIVE="${CYDER_OEM_ENGINE_ARCHIVE:-}"
ARCHIVE_PIN="$ROOT/config/cyder-oem-engine-archive.txt"
VERSION_PIN="$ROOT/config/cyder-oem-engine-version.txt"
if [[ -z "$ARCHIVE" && -f "$ARCHIVE_PIN" ]]; then
  ARCHIVE="$(tr -d '[:space:]' <"$ARCHIVE_PIN")"
  [[ "$ARCHIVE" = /* ]] || ARCHIVE="$ROOT/$ARCHIVE"
fi
ENGINE_VERSION="${CYDER_OEM_ENGINE_VERSION:-}"
if [[ -z "$ENGINE_VERSION" && -f "$VERSION_PIN" ]]; then
  ENGINE_VERSION="$(tr -d '[:space:]' <"$VERSION_PIN")"
fi

[[ -f "$ARCHIVE" ]] || {
  echo "Missing MapleStory OEM engine archive: $ARCHIVE" >&2
  echo "Build it with cyder-wine-engine/scripts/pack-maplestory-oem25-engine.sh or set CYDER_OEM_ENGINE_ARCHIVE." >&2
  exit 1
}
[[ -n "$ENGINE_VERSION" ]] || {
  echo "Missing OEM engine version label (set CYDER_OEM_ENGINE_VERSION or $VERSION_PIN)" >&2
  exit 1
}

if [[ "${CYDER_VERIFY_ENGINE_SHA256:-0}" == 1 ]]; then
  sha_file="$ARCHIVE.sha256"
  [[ -f "$sha_file" ]] || {
    echo "Missing engine SHA-256 sidecar: $sha_file" >&2
    exit 1
  }
  read -r expected_sha listed_archive <"$sha_file"
  [[ "$listed_archive" == "$(basename "$ARCHIVE")" ]] || {
    echo "Engine SHA-256 sidecar names a different archive: $listed_archive" >&2
    exit 1
  }
  actual_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    echo "MapleStory OEM engine archive SHA-256 mismatch" >&2
    echo "  expected=$expected_sha" >&2
    echo "  actual=$actual_sha" >&2
    exit 1
  }
fi

# Validate the archive before handing it to the generic app packer.  The OEM
# engine keeps CrossOver's original ntdll and carries only Cyder's compatdb
# replacement plus engine-owned MoltenVK; DXVK/DXMT are external sidecars.
VALIDATE_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cyder-oem-validate.XXXXXX")"
cleanup() { rm -rf "$VALIDATE_STAGING"; }
trap cleanup EXIT
tar -xJf "$ARCHIVE" -C "$VALIDATE_STAGING"
ENGINE_TREE="$VALIDATE_STAGING/wine-x86_64"
[[ -x "$ENGINE_TREE/bin/wine" ]] || {
  echo "OEM archive missing wine-x86_64/bin/wine" >&2
  exit 1
}
[[ -f "$ENGINE_TREE/version" ]] || {
  echo "OEM archive missing engine version label" >&2
  exit 1
}
archive_engine_version="$(tr -d '[:space:]' <"$ENGINE_TREE/version")"
[[ "$archive_engine_version" == "$ENGINE_VERSION" ]] || {
  echo "OEM engine version mismatch" >&2
  echo "  pinned=$ENGINE_VERSION" >&2
  echo "  archive=$archive_engine_version" >&2
  exit 1
}
[[ -f "$ENGINE_TREE/lib/wine/x86_64-unix/cxcompatdb.so" ]] || {
  echo "OEM archive missing Cyder cxcompatdb.so" >&2
  exit 1
}
[[ -f "$ENGINE_TREE/lib64/libMoltenVK.dylib" ]] || {
  echo "OEM archive missing engine-owned MoltenVK" >&2
  exit 1
}
for legacy_graphics_dir in "$ENGINE_TREE/lib/dxvk" "$ENGINE_TREE/lib/dxvk2" "$ENGINE_TREE/lib/dxmt"; do
  [[ ! -e "$legacy_graphics_dir" ]] || {
    echo "OEM engine must not contain legacy graphics payload: ${legacy_graphics_dir#$ENGINE_TREE/}" >&2
    exit 1
  }
done
cxcompatdb_strings="$VALIDATE_STAGING/cxcompatdb.strings"
strings "$ENGINE_TREE/lib/wine/x86_64-unix/cxcompatdb.so" >"$cxcompatdb_strings"
grep -Fq 'CYDER_GRAPHICS_BACKEND_PATH' "$cxcompatdb_strings" || {
  echo "OEM cxcompatdb.so does not expose CYDER_GRAPHICS_BACKEND_PATH support" >&2
  exit 1
}
moltenvk_strings="$VALIDATE_STAGING/moltenvk.strings"
strings "$ENGINE_TREE/lib64/libMoltenVK.dylib" >"$moltenvk_strings"
grep -Fq '1.4.0' "$moltenvk_strings" || {
  echo "OEM engine does not contain MoltenVK 1.4.0" >&2
  exit 1
}

export CYDER_APP_VERSION="${CYDER_APP_VERSION:-0.10.1-maplestory-oem25}"
export CYDER_BUNDLED_ENGINE_VERSION="${CYDER_BUNDLED_ENGINE_VERSION:-$ENGINE_VERSION}"
# Match create-cyder-app.sh: Developer ID by default; SIGN_IDENTITY=- for ad-hoc.
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Chun Ho Kwok (3U9565WWM2)}"

bash "$SCRIPT_DIR/create-cyder-app.sh" --engine-archive "$ARCHIVE" "$OUT_DIR"

[[ -d "$BASE_APP" ]] || {
  echo "Base Cyder app was not created: $BASE_APP" >&2
  exit 1
}
rm -rf "$APP"
mv "$BASE_APP" "$APP"

# Distinct Launch Services identity from official Cyder.app.
# Suggested id: local.cyder.maplestory-oem25 (keep local.* for ad-hoc / unsigned builds).
OEM_BUNDLE_ID="${CYDER_OEM_BUNDLE_ID:-local.cyder.maplestory-oem25}"
OEM_BUNDLE_NAME="${CYDER_OEM_BUNDLE_NAME:-Cyder MapleStory OEM}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $OEM_BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $OEM_BUNDLE_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable CyderMapleStoryOEM" "$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $OEM_BUNDLE_NAME" "$APP/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $OEM_BUNDLE_NAME" "$APP/Contents/Info.plist"
fi

MACOS="$APP/Contents/MacOS"
rm -f "$MACOS/Cyder"
cp "$SCRIPT_DIR/cyder_maplestory_oem_main.sh" "$MACOS/CyderMapleStoryOEM"
cp "$SCRIPT_DIR/cyder_oem_bootstrap_main.sh" "$MACOS/CyderOEMBootstrap"
chmod +x "$MACOS/CyderMapleStoryOEM" "$MACOS/CyderOEMBootstrap"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  timestamp_flag="--timestamp=none"
else
  timestamp_flag="--timestamp"
fi
sign_macho() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  file -b "$path" | grep -q 'Mach-O' || return 0
  codesign --force --options runtime "$timestamp_flag" \
    --entitlements "$ROOT/config/entitlements.plist" \
    --sign "$SIGN_IDENTITY" "$path"
}

# Shell helpers in MacOS/ must be signed before the bundle (nested code).
for helper in CyderOEMBootstrap CyderMapleStoryOEM; do
  [[ -f "$MACOS/$helper" ]] || continue
  codesign --force --options runtime "$timestamp_flag" \
    --sign "$SIGN_IDENTITY" "$MACOS/$helper"
done
sign_macho "$APP/Contents/Resources/tools/zstd/zstd"
sign_macho "$APP/Contents/Resources/tools/cabextract/cabextract"
sign_macho "$MACOS/CyderSwift"
while IFS= read -r -d '' path; do
  case "$path" in
    */MacOS/CyderMapleStoryOEM | */MacOS/CyderSwift | */MacOS/CyderOEMBootstrap | */tools/zstd/zstd | */tools/cabextract/cabextract) continue ;;
  esac
  sign_macho "$path"
done < <(find "$APP/Contents" -type f -print0)
codesign --force --options runtime "$timestamp_flag" \
  --entitlements "$ROOT/config/entitlements.plist" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Created $APP"
echo "Engine archive: $(basename "$ARCHIVE")"
echo "Engine version: $ENGINE_VERSION"
echo "Graphics payloads: external Resources/graphics (DXVK/DXMT)"
