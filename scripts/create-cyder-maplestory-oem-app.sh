#!/usr/bin/env bash
# Package the MapleStory OEM flavor around the shared Cyder app builder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${CYDER_OEM_APP_OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/Cyder-maplestory-oem25.app"
BASE_APP="$OUT_DIR/Cyder.app"
EXPECTED_SHA256="be890c31d65d5777204fc9614d19d6fedba1410625594b330dc985cbf96f1e23"
BASE_ARCHIVE="${CYDER_OEM_ENGINE_ARCHIVE:-}"
if [[ -z "$BASE_ARCHIVE" ]]; then
  for candidate in \
    "$ROOT/dist/artifacts/maplestory-oem25/engine-maplestory-oem25.0.1.38865.tar.xz" \
    "$ROOT/../../dist/artifacts/maplestory-oem25/engine-maplestory-oem25.0.1.38865.tar.xz"
  do
    if [[ -f "$candidate" ]]; then
      BASE_ARCHIVE="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      break
    fi
  done
fi
# Redistributable DXVK PE payload (D3D11/DXGI). Prefer a Cyder-built tree.
DXVK_SRC="${CYDER_OEM_DXVK_SRC:-}"
if [[ -z "$DXVK_SRC" ]]; then
  # Prefer worktree install/, then parent monorepo install/ when packaging from a worktree.
  for candidate in \
    "$ROOT/install/wine-cx26-x86_64/lib/dxvk" \
    "$ROOT/install/wine-maplestory-oem25-source-x86_64/lib/dxvk" \
    "$ROOT/../../install/wine-cx26-x86_64/lib/dxvk" \
    "$ROOT/../../install/wine-maplestory-oem25-source-x86_64/lib/dxvk"
  do
    if [[ -f "$candidate/x86_64-windows/d3d11.dll" && -f "$candidate/x86_64-windows/dxgi.dll" ]]; then
      DXVK_SRC="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi

[[ -f "$BASE_ARCHIVE" ]] || {
  echo "Missing MapleStory OEM engine archive: $BASE_ARCHIVE" >&2
  exit 1
}

if [[ "${CYDER_VERIFY_ENGINE_SHA256:-0}" == 1 ]]; then
  actual_sha256="$(shasum -a 256 "$BASE_ARCHIVE" | awk '{print $1}')"
  [[ "$actual_sha256" == "$EXPECTED_SHA256" ]] || {
    echo "MapleStory OEM engine archive SHA-256 mismatch" >&2
    exit 1
  }
fi

[[ -n "$DXVK_SRC" && -f "$DXVK_SRC/x86_64-windows/d3d11.dll" ]] || {
  echo "Missing DXVK payload to inject into OEM engine (set CYDER_OEM_DXVK_SRC)" >&2
  exit 1
}

# Build a derived archive: stock CX OEM tree + lib/dxvk (do not mutate the pinned base).
ARTIFACTS_DIR="$ROOT/dist/artifacts/maplestory-oem25"
mkdir -p "$ARTIFACTS_DIR"
INJECTED_ARCHIVE="$ARTIFACTS_DIR/engine-maplestory-oem25.0.1.38865+dxvk.tar.xz"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cyder-oem-dxvk.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

echo "==> Injecting DXVK into OEM engine archive"
echo "    base=$BASE_ARCHIVE"
echo "    dxvk=$DXVK_SRC"
tar -xJf "$BASE_ARCHIVE" -C "$STAGING"
ENGINE_TREE="$STAGING/wine-x86_64"
[[ -x "$ENGINE_TREE/bin/wine" ]] || {
  echo "OEM archive missing wine-x86_64/bin/wine" >&2
  exit 1
}
mkdir -p "$ENGINE_TREE/lib/dxvk"
rm -rf "$ENGINE_TREE/lib/dxvk"
cp -R "$DXVK_SRC" "$ENGINE_TREE/lib/dxvk"
[[ -f "$ENGINE_TREE/lib/dxvk/x86_64-windows/d3d11.dll" ]] || {
  echo "DXVK inject failed: missing d3d11.dll" >&2
  exit 1
}
# Keep the stock version label so an already-bootstrapped OEM bottle is not reset
# on upgrade; sidecar installs still pick up DXVK via the new archive on re-extract
# or via the post-pack sidecar sync below.
(
  cd "$STAGING"
  # Prefer xz for create-cyder-app compatibility with .tar.xz resources.
  if command -v xz >/dev/null 2>&1; then
    tar -cf - wine-x86_64 | xz -T0 -c >"$INJECTED_ARCHIVE"
  else
    tar -cJf "$INJECTED_ARCHIVE" wine-x86_64
  fi
)
ARCHIVE="$INJECTED_ARCHIVE"
echo "==> Wrote $ARCHIVE ($(du -h "$ARCHIVE" | awk '{print $1}'))"

export CYDER_APP_VERSION="${CYDER_APP_VERSION:-0.9.4-maplestory-oem25}"
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

# Sync DXVK into the already-installed OEM sidecar without resetting the bottle.
SIDECAR="${CYDER_OEM_SIDECAR_ENGINE:-$HOME/.cyder/runtime/Engines/maplestory-oem25}"
if [[ -d "$SIDECAR/bin" ]]; then
  echo "==> Syncing DXVK into installed sidecar: $SIDECAR"
  mkdir -p "$SIDECAR/lib"
  rm -rf "$SIDECAR/lib/dxvk"
  cp -R "$DXVK_SRC" "$SIDECAR/lib/dxvk"
fi

echo "Created $APP"
echo "Engine archive includes lib/dxvk from $DXVK_SRC"
