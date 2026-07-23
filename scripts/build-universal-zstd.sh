#!/usr/bin/env bash
# Build a dependency-free universal zstd CLI for Cyder engine extraction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="1.5.7"
SOURCE_SHA256="37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"
SOURCE_URL="https://github.com/facebook/zstd/archive/refs/tags/v${VERSION}.tar.gz"
OUT="${1:-$ROOT/tools/zstd/zstd}"
SOURCE_ARCHIVE="${ZSTD_SOURCE_ARCHIVE:-$ROOT/tools/archives/zstd-v${VERSION}.tar.gz}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cyder-zstd.XXXXXX")"

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  SOURCE_ARCHIVE="$BUILD_ROOT/zstd-v${VERSION}.tar.gz"
  curl -L --fail --silent --show-error -o "$SOURCE_ARCHIVE" "$SOURCE_URL"
fi

actual_sha="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$SOURCE_SHA256" ]] || {
  echo "zstd source checksum mismatch" >&2
  echo "Expected: $SOURCE_SHA256" >&2
  echo "Actual:   $actual_sha" >&2
  exit 2
}

source_root="$BUILD_ROOT/source"
mkdir -p "$source_root"
tar -xzf "$SOURCE_ARCHIVE" -C "$source_root" --strip-components=1

build_slice() {
  local arch="$1" minimum="$2" output="$3"
  make -C "$source_root/programs" clean >/dev/null
  make -C "$source_root/programs" -j"$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" \
    zstd-release \
    CC="clang -arch $arch -mmacosx-version-min=$minimum" \
    HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 ZSTD_LEGACY_SUPPORT=0
  cp "$source_root/programs/zstd" "$output"
}

build_slice x86_64 10.12 "$BUILD_ROOT/zstd-x86_64"
build_slice arm64 11.0 "$BUILD_ROOT/zstd-arm64"
mkdir -p "$(dirname "$OUT")"
lipo -create "$BUILD_ROOT/zstd-x86_64" "$BUILD_ROOT/zstd-arm64" -output "$OUT"
strip -x "$OUT"
chmod 0755 "$OUT"
codesign --force --sign - "$OUT"

cp "$source_root/LICENSE" "$(dirname "$OUT")/LICENSE"

file "$OUT"
otool -L "$OUT"
"$OUT" --version
echo "Created $OUT"
echo "x86_64 minimum macOS: 10.12"
echo "arm64 minimum macOS: 11.0 (first macOS release supporting Apple silicon)"
