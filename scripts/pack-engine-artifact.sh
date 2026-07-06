#!/usr/bin/env bash
# Build reusable Wine engine artifact (strip + zstd tar) for Cyder / CyderBits apps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$SCRIPT_DIR/cyder-common.sh"
source "$SCRIPT_DIR/env-x86_64.sh"

FORCE=0
DRY_RUN=0

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
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run]

Build dist/artifacts/engine-<CX26-winever>.tar.zst from install/wine-x86_64.
Set CYDER_ENGINE_VERSION to override the detected version label.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "Missing Wine at $WINE_INSTALL — build it first." >&2
  exit 1
}
command -v zstd >/dev/null 2>&1 || {
  echo "Missing zstd — install with: brew install zstd" >&2
  exit 1
}

ENGINE_VERSION="$(cyder_detect_engine_version "$WINE_INSTALL/bin/wine")" || {
  echo "Could not detect engine version from wine --version" >&2
  exit 1
}
ARTIFACTS_DIR="$(cyder_engine_artifacts_dir)"
ARCHIVE="$(cyder_engine_archive_path "$ENGINE_VERSION" "$ARTIFACTS_DIR")"
VERSION_FILE="$ARTIFACTS_DIR/engine-version.txt"
STAMP_FILE="$ARTIFACTS_DIR/.pack-stamp"

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

echo "==> Staging engine tree ($ENGINE_VERSION)"
rsync -a --delete "$WINE_INSTALL/" "$ENGINE_TREE/"
find "$ENGINE_TREE" -name '.DS_Store' -delete 2>/dev/null || true
bash "$SCRIPT_DIR/strip-wine-install.sh" "$ENGINE_TREE"
bash "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$ENGINE_TREE"
bash "$SCRIPT_DIR/sign-wine.sh" --root "$ENGINE_TREE" --entitlements "$ENTITLEMENTS_PLIST"

mkdir -p "$ARTIFACTS_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: would create $ARCHIVE from $ENGINE_TREE"
  exit 0
fi

echo "==> Compressing with zstd (-22 --ultra)"
(
  cd "$STAGING"
  tar -cf - wine-x86_64 | zstd -22 --ultra -T0 -o "$ARCHIVE"
)

printf '%s\n' "$ENGINE_VERSION" >"$VERSION_FILE"
{
  echo "version=$ENGINE_VERSION"
  echo "archive=$(basename "$ARCHIVE")"
  echo "wine=$(arch -x86_64 "$WINE_INSTALL/bin/wine" --version 2>/dev/null || true)"
  echo "packed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$STAMP_FILE"
shasum -a 256 "$ARCHIVE" >"${ARCHIVE}.sha256"

echo "==> Created $ARCHIVE ($(du -sh "$ARCHIVE" | awk '{print $1}'))"
echo "==> Version file: $VERSION_FILE"
