#!/usr/bin/env bash
# Package the MapleStory OEM flavor around the shared Cyder app builder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="${CYDER_OEM_ENGINE_ARCHIVE:-$ROOT/dist/artifacts/maplestory-oem25/engine-maplestory-oem25.0.1.38865.tar.xz}"
OUT_DIR="${CYDER_OEM_APP_OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/Cyder-maplestory-oem25.app"
BASE_APP="$OUT_DIR/Cyder.app"
EXPECTED_SHA256="be890c31d65d5777204fc9614d19d6fedba1410625594b330dc985cbf96f1e23"

[[ -f "$ARCHIVE" ]] || {
  echo "Missing MapleStory OEM engine archive: $ARCHIVE" >&2
  exit 1
}

if [[ "${CYDER_VERIFY_ENGINE_SHA256:-0}" == 1 ]]; then
  actual_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  [[ "$actual_sha256" == "$EXPECTED_SHA256" ]] || {
    echo "MapleStory OEM engine archive SHA-256 mismatch" >&2
    exit 1
  }
fi

export CYDER_APP_VERSION="${CYDER_APP_VERSION:-0.8.0-maplestory-oem25}"
export CYDER_BUNDLED_ENGINE_VERSION="${CYDER_BUNDLED_ENGINE_VERSION:-MapleStory OEM CrossOver 25.0.1.38865}"
# Match create-cyder-app.sh: Developer ID by default; SIGN_IDENTITY=- for ad-hoc.
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Chun Ho Kwok (3U9565WWM2)}"

bash "$SCRIPT_DIR/create-cyder-app.sh" --engine-archive "$ARCHIVE" "$OUT_DIR"

[[ -d "$BASE_APP" ]] || {
  echo "Base Cyder app was not created: $BASE_APP" >&2
  exit 1
}
rm -rf "$APP"
mv "$BASE_APP" "$APP"

MACOS="$APP/Contents/MacOS"
cp "$SCRIPT_DIR/cyder_maplestory_oem_main.sh" "$MACOS/Cyder"
cp "$SCRIPT_DIR/cyder_oem_bootstrap_main.sh" "$MACOS/CyderOEMBootstrap"
chmod +x "$MACOS/Cyder" "$MACOS/CyderOEMBootstrap"

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
for helper in CyderOEMBootstrap Cyder; do
  [[ -f "$MACOS/$helper" ]] || continue
  codesign --force --options runtime "$timestamp_flag" \
    --sign "$SIGN_IDENTITY" "$MACOS/$helper"
done
sign_macho "$APP/Contents/Resources/tools/zstd/zstd"
sign_macho "$APP/Contents/Resources/tools/cabextract/cabextract"
sign_macho "$MACOS/CyderSwift"
while IFS= read -r -d '' path; do
  case "$path" in
    */MacOS/Cyder | */MacOS/CyderSwift | */MacOS/CyderOEMBootstrap | */tools/zstd/zstd | */tools/cabextract/cabextract) continue ;;
  esac
  sign_macho "$path"
done < <(find "$APP/Contents" -type f -print0)
codesign --force --options runtime "$timestamp_flag" \
  --entitlements "$ROOT/config/entitlements.plist" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Created $APP"
