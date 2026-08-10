#!/usr/bin/env bash
# Build reusable Wine engine artifact (strip + compressed tar) for Cyder / CyderBits apps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$SCRIPT_DIR/cyder-common.sh"
source "$SCRIPT_DIR/env-x86_64.sh"

FORCE=0
DRY_RUN=0
FORMAT="${CYDER_ENGINE_FORMAT:-xz}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --format)
      FORMAT="${2:-}"
      if [[ -z "$FORMAT" ]]; then
        echo "Missing value for --format" >&2
        exit 1
      fi
      shift 2
      ;;
    --zst | --zstd)
      FORMAT="zst"
      shift
      ;;
    --xz)
      FORMAT="xz"
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--zstd] [--format zstd|xz]

Build a compressed engine artifact from install/wine-cx26-x86_64 (or WINE_INSTALL).
  xz:   dist/artifacts/engine-wine-x86_64-<CX26-winever>.tar.xz (default, xz -9e)
  zstd: dist/artifacts/engine-<CX26-winever>.tar.zst (--zstd)
Set CYDER_ENGINE_VERSION to override the detected version label.
Set CYDER_ENGINE_FORMAT=zstd or pass --zstd to build with zstd -22 --ultra.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$FORMAT" in
  zstd) FORMAT="zst" ;;
esac

case "$FORMAT" in
  zst | xz) ;;
  *)
    echo "Unknown format: $FORMAT (expected zstd or xz)" >&2
    exit 1
    ;;
esac

[[ -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "Missing Wine at $WINE_INSTALL — build it first." >&2
  exit 1
}
if [[ "$FORMAT" == "zst" ]]; then
  ZSTD_BIN="$(cyder_find_zstd 2>/dev/null || true)"
  [[ -x "$ZSTD_BIN" ]] || {
    echo "Missing zstd — rebuild the bundled tool with scripts/build-universal-zstd.sh" >&2
    exit 1
  }
else
  command -v xz >/dev/null 2>&1 || {
    echo "Missing xz — install with: brew install xz" >&2
    exit 1
  }
fi

ENGINE_VERSION_LABEL="${CYDER_ENGINE_VERSION_LABEL:-}"
if [[ -z "$ENGINE_VERSION_LABEL" ]]; then
  ENGINE_VERSION_LABEL="$(cyder_detect_engine_version_label "$WINE_INSTALL/bin/wine")" || {
    echo "Could not detect engine version from wine --version" >&2
    exit 1
  }
fi
ENGINE_VERSION_SLUG="$(cyder_engine_version_slug_from_label "$ENGINE_VERSION_LABEL")"
ENGINE_VERSION="$ENGINE_VERSION_SLUG"
ARTIFACTS_DIR="$(cyder_engine_artifacts_dir)"
ARCHIVE="$(cyder_engine_archive_path_for_format "$ENGINE_VERSION" "$ARTIFACTS_DIR" "$FORMAT")"
VERSION_FILE="$ARTIFACTS_DIR/engine-version.txt"
STAMP_FILE="$ARTIFACTS_DIR/.pack-stamp"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: would pack separate DXVK/DXMT graphics payloads"
else
  bash "$SCRIPT_DIR/pack-graphics-payloads.sh" --engine "$WINE_INSTALL"
fi

if [[ -f "$ARCHIVE" && "$FORCE" -ne 1 ]]; then
  echo "Engine artifact present: $ARCHIVE"
  echo "Use --force to rebuild."
  exit 0
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cyder-engine-pack.XXXXXX")"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT
ENGINE_TREE="$STAGING/wine-x86_64"

echo "==> Staging engine tree ($ENGINE_VERSION_LABEL)"
# Fail closed: never ship Apple GPTK inside a redistributable engine artifact.
rsync -a --delete \
  --exclude 'lib64/apple_gptk' \
  --exclude 'apple_gptk' \
  --exclude 'lib/dxvk' \
  --exclude 'lib/dxmt' \
  "$WINE_INSTALL/" "$ENGINE_TREE/"
find "$ENGINE_TREE" -name '.DS_Store' -delete 2>/dev/null || true
if [[ -e "$ENGINE_TREE/lib64/apple_gptk" ]] ||
   find "$ENGINE_TREE" -type d -name 'apple_gptk' -print -quit | grep -q .; then
  echo "Refusing to pack engine that contains apple_gptk (GPTK must not be redistributed)" >&2
  exit 1
fi
cyder_write_engine_version_file "$ENGINE_TREE" "$ENGINE_VERSION_LABEL"

bash "$SCRIPT_DIR/strip-wine-install.sh" "$ENGINE_TREE"
# Preserve MoltenVK already in the install tree (VULKAN_SOURCE=existing only
# seeds it when VULKAN_MODE=with; default without would orphan-delete it).
VULKAN_MODE="${VULKAN_MODE:-with}" VULKAN_SOURCE=existing \
  bash "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$ENGINE_TREE"
bash "$SCRIPT_DIR/sign-wine.sh" --root "$ENGINE_TREE" --entitlements "$ENTITLEMENTS_PLIST"

mkdir -p "$ARTIFACTS_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: would create $ARCHIVE from $ENGINE_TREE"
  exit 0
fi

case "$FORMAT" in
  zst)
    echo "==> Compressing with zstd (-22 --ultra)"
    (
      cd "$STAGING"
      tar -cf - wine-x86_64 | "$ZSTD_BIN" -22 --ultra -T0 -o "$ARCHIVE"
    )
    ;;
  xz)
    echo "==> Compressing with xz (-9e -T0)"
    (
      cd "$STAGING"
      tar -cf - wine-x86_64 | xz -9e -T0 -c >"$ARCHIVE"
    )
    ;;
esac

# Verify the archive itself, not only the staging tree. This catches signatures
# whose embedded CMS data does not survive the final tar round trip.
VERIFY_ROOT="$STAGING/archive-verify"
mkdir -p "$VERIFY_ROOT"
case "$FORMAT" in
  zst)
    "$ZSTD_BIN" -dc "$ARCHIVE" | tar -xf - -C "$VERIFY_ROOT"
    ;;
  xz)
    tar -xJf "$ARCHIVE" -C "$VERIFY_ROOT"
    ;;
esac
verified_macho=0
while IFS= read -r -d '' signed_path; do
  if file -b "$signed_path" | grep -q 'Mach-O'; then
    codesign --verify --strict "$signed_path"
    verified_macho=$((verified_macho + 1))
  fi
done < <(find "$VERIFY_ROOT/wine-x86_64" -type f -print0)
echo "==> Verified $verified_macho Mach-O signatures after archive extraction"

printf '%s\n' "$ENGINE_VERSION_LABEL" >"$VERSION_FILE"
{
  echo "version=$ENGINE_VERSION_LABEL"
  echo "slug=$ENGINE_VERSION_SLUG"
  echo "format=$FORMAT"
  echo "archive=$(basename "$ARCHIVE")"
  if [[ -n "${CYDER_ENGINE_VERSION_LABEL:-}" ]]; then
    echo "wine=$ENGINE_VERSION_LABEL"
  else
    echo "wine=$(arch -x86_64 "$WINE_INSTALL/bin/wine" --version 2>/dev/null || true)"
  fi
  echo "packed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$STAMP_FILE"
shasum -a 256 "$ARCHIVE" >"${ARCHIVE}.sha256"

echo "==> Created $ARCHIVE ($(du -sh "$ARCHIVE" | awk '{print $1}'))"
echo "==> Version file: $VERSION_FILE"
