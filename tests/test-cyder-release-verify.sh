#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
VERIFY="$ROOT/.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh"

assert test -f "$VERIFY"
assert_contains "$(cat "$VERIFY")" 'CYDER_VERIFY_DXVK_MIN_BYTES' \
  "verify must honor CYDER_VERIFY_DXVK_MIN_BYTES"
assert_contains "$(cat "$VERIFY")" 'tar -tv' \
  "verify must inspect tar listings"
assert_contains "$(cat "$VERIFY")" 'skip-notarization-checks' \
  "verify must support --skip-notarization-checks"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-release-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ZSTD="${CYDER_ZSTD:-}"
if [[ -z "$ZSTD" || ! -x "$ZSTD" ]]; then
  if [[ -x "$ROOT/tools/zstd/zstd" ]]; then
    ZSTD="$ROOT/tools/zstd/zstd"
  else
    ZSTD="$(command -v zstd)"
  fi
fi
assert test -x "$ZSTD"

mkdir -p "$tmp/Cyder.app/Contents/Resources/graphics"
mkdir -p "$tmp/stage"
ln -s /tmp/nonexistent-dxvk "$tmp/stage/dxvk"
( cd "$tmp/stage" && tar -cf - dxvk | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxvk-1.10.3.tar.zst" )
printf 'not-a-real-payload' | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxmt-0.80.tar.zst"
printf 'CX26.3.0-W11-Cyder012\n' >"$tmp/Cyder.app/Contents/Resources/engine-version.txt"
: >"$tmp/Cyder.app/Contents/Resources/engine-CX26-3-0-W11-Cyder012.tar.zst"
( cd "$tmp" && zip -qr Cyder.app.zip Cyder.app )

set +e
CYDER_VERIFY_DXVK_MIN_BYTES=100 CYDER_VERIFY_DXMT_MIN_BYTES=100 \
  bash "$VERIFY" --app "$tmp/Cyder.app" --zip "$tmp/Cyder.app.zip" \
  --skip-notarization-checks --baseline "$tmp/Cyder.app.zip"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "ASSERT failed: symlink/tiny graphics must fail verify" >&2
  exit 1
fi

rm -rf "$tmp/stage" "$tmp/Cyder.app/Contents/Resources/graphics"
mkdir -p "$tmp/stage/dxvk/x86_64-windows" "$tmp/stage/dxmt/x86_64-unix"
# urandom so zstd cannot shrink below the lowered verify mins
dd if=/dev/urandom of="$tmp/stage/dxvk/x86_64-windows/d3d11.dll" bs=1024 count=64 status=none
dd if=/dev/urandom of="$tmp/stage/dxmt/x86_64-unix/winemetal.so" bs=1024 count=64 status=none
mkdir -p "$tmp/Cyder.app/Contents/Resources/graphics"
( cd "$tmp/stage" && tar -cf - dxvk | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxvk-1.10.3.tar.zst" )
( cd "$tmp/stage" && tar -cf - dxmt | "$ZSTD" -q -o "$tmp/Cyder.app/Contents/Resources/graphics/dxmt-0.80.tar.zst" )
printf 'CX26.3.0-W11-Cyder012\n' >"$tmp/Cyder.app/Contents/Resources/engine-version.txt"
dd if=/dev/zero of="$tmp/Cyder.app/Contents/Resources/engine-CX26-3-0-W11-Cyder012.tar.zst" bs=1024 count=8 status=none
( cd "$tmp" && rm -f Cyder.app.zip && zip -qr Cyder.app.zip Cyder.app )

set +e
CYDER_VERIFY_DXVK_MIN_BYTES=1000 CYDER_VERIFY_DXMT_MIN_BYTES=1000 \
  bash "$VERIFY" --app "$tmp/Cyder.app" --zip "$tmp/Cyder.app.zip" \
  --skip-notarization-checks --baseline "$tmp/Cyder.app.zip"
ok_status=$?
set -e
assert test "$ok_status" -ne 0 # Size/layout alone cannot accept unsigned or unprovenanced DXMT.

echo "PASS test-cyder-release-verify"
