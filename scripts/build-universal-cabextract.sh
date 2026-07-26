#!/usr/bin/env bash
# Build a dependency-free universal cabextract CLI for Winetricks component extraction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="1.11"
SOURCE_SHA256="b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6"
SOURCE_URL="https://www.cabextract.org.uk/cabextract-${VERSION}.tar.gz"
SOURCE_URL_BACKUP="https://github.com/kyz/cabextract/archive/refs/tags/v${VERSION}.tar.gz"
OUT="${1:-$ROOT/tools/cabextract/cabextract}"
SOURCE_ARCHIVE="${CABEXTRACT_SOURCE_ARCHIVE:-$ROOT/tools/archives/cabextract-${VERSION}.tar.gz}"

mkdir -p "$ROOT/dist/tmp"
BUILD_ROOT="$(mktemp -d "$ROOT/dist/tmp/cyder-cabextract.XXXXXX")"

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT/tools/archives"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  SOURCE_ARCHIVE="$BUILD_ROOT/cabextract-${VERSION}.tar.gz"
  curl -L --fail --silent --show-error -o "$SOURCE_ARCHIVE" "$SOURCE_URL" || \
  curl -L --fail --silent --show-error -o "$SOURCE_ARCHIVE" "$SOURCE_URL_BACKUP"
fi

actual_sha="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$SOURCE_SHA256" ]] || {
  echo "cabextract source checksum mismatch" >&2
  echo "Expected: $SOURCE_SHA256" >&2
  echo "Actual:   $actual_sha" >&2
  exit 2
}

build_slice() {
  local arch="$1" host="$2" minimum="$3" output="$4"
  local slice_dir="$BUILD_ROOT/src-$arch"
  mkdir -p "$slice_dir"
  tar -xzf "$SOURCE_ARCHIVE" -C "$slice_dir" --strip-components=1

  (
    cd "$slice_dir"
    ./configure \
      --host="$host" \
      --disable-dependency-tracking \
      CC="clang -arch $arch -mmacosx-version-min=$minimum" \
      CFLAGS="-O2" >/dev/null
    make -j"$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" >/dev/null
  )

  cp "$slice_dir/cabextract" "$output"
}

build_slice x86_64 x86_64-apple-darwin 10.15 "$BUILD_ROOT/cabextract-x86_64"
build_slice arm64 aarch64-apple-darwin 11.0 "$BUILD_ROOT/cabextract-arm64"

mkdir -p "$(dirname "$OUT")"
lipo -create "$BUILD_ROOT/cabextract-x86_64" "$BUILD_ROOT/cabextract-arm64" -output "$OUT"
strip -x "$OUT"
chmod 0755 "$OUT"
codesign --force --sign - "$OUT"

slice_dir="$BUILD_ROOT/src-x86_64"
cp "$slice_dir/COPYING" "$(dirname "$OUT")/COPYING"

file "$OUT"
"$OUT" --version
echo "Created $OUT"
echo "x86_64 minimum macOS: 10.15"
echo "arm64 minimum macOS: 11.0"
