#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ZSTD="$ROOT/tools/zstd/zstd"

[[ -x "$ZSTD" ]] || {
  echo "ASSERT failed: bundled universal zstd is missing" >&2
  exit 1
}

architectures="$(lipo -archs "$ZSTD")"
assert_contains "$architectures" "x86_64" "zstd should include an Intel slice"
assert_contains "$architectures" "arm64" "zstd should include an Apple silicon slice"

dependencies="$(otool -L "$ZSTD")"
assert_contains "$dependencies" "/usr/lib/libSystem.B.dylib" "zstd should only need the macOS system runtime"
if [[ "$dependencies" == *Homebrew* || "$dependencies" == *opt/homebrew* || "$dependencies" == *libzstd* || "$dependencies" == *liblzma* || "$dependencies" == *liblz4* ]]; then
  echo "ASSERT failed: bundled zstd has a non-system runtime dependency" >&2
  exit 1
fi

x86_load="$(otool -arch x86_64 -l "$ZSTD")"
arm_load="$(otool -arch arm64 -l "$ZSTD")"
assert_contains "$x86_load" "version 10.12" "Intel zstd should support macOS 10.12"
assert_contains "$arm_load" "minos 11.0" "arm64 zstd should target the first Apple silicon macOS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'Cyder universal zstd round trip\n' >"$TMP/input"
"$ZSTD" -q -f "$TMP/input" -o "$TMP/input.zst"
"$ZSTD" -q -d -f "$TMP/input.zst" -o "$TMP/output"
cmp "$TMP/input" "$TMP/output"

CYDER_OGOM="$ROOT"
CYDER_SUPPORT="$TMP/support"
source "$ROOT/scripts/cyder-common.sh"
assert_eq "$(cyder_find_zstd)" "$ZSTD" "Cyder should prefer its bundled zstd over PATH"

mkdir -p "$TMP/archive/wine-x86_64/bin" "$TMP/extracted"
printf '%s\n' '#!/bin/sh' 'echo wine fixture' >"$TMP/archive/wine-x86_64/bin/wine"
chmod +x "$TMP/archive/wine-x86_64/bin/wine"
tar -C "$TMP/archive" -cf - wine-x86_64 | "$ZSTD" -q -o "$TMP/engine.tar.zst"
# Restrict PATH to macOS system tools: extraction must not discover Homebrew.
PATH=/usr/bin:/bin cyder_tar_extract "$TMP/engine.tar.zst" "$TMP/extracted"
cmp "$TMP/archive/wine-x86_64/bin/wine" "$TMP/extracted/wine-x86_64/bin/wine"

echo "PASS test-universal-zstd"
