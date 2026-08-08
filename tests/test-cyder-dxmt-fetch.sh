#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

SCRIPT="$ROOT/scripts/fetch-dxmt.sh"
assert test -x "$SCRIPT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxmt-fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Bad checksum must fail before mutating engine.
E1="$TMP/engine1"
mkdir -p "$E1"
printf 'not-dxmt\n' >"$TMP/bad.tar.gz"
if bash "$SCRIPT" --engine "$E1" --tarball "$TMP/bad.tar.gz" 2>"$TMP/err"; then
  echo "expected checksum failure" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/err")" "checksum" "fetch must reject bad checksum"
assert test ! -e "$E1/lib/dxmt/x86_64-unix/winemetal.so"

# Minimal fake upstream layout → normalize into lib/dxmt.
STAGE="$TMP/stage"
mkdir -p \
  "$STAGE/x86_64-windows" \
  "$STAGE/i386-windows" \
  "$STAGE/x86_64-unix"
printf 'd3d11\n' >"$STAGE/x86_64-windows/d3d11.dll"
printf 'dxgi\n' >"$STAGE/x86_64-windows/dxgi.dll"
printf 'd3d11-32\n' >"$STAGE/i386-windows/d3d11.dll"
printf 'dxgi-32\n' >"$STAGE/i386-windows/dxgi.dll"
printf 'so\n' >"$STAGE/x86_64-unix/winemetal.so"
printf 'MIT\n' >"$STAGE/LICENSE"
(
  cd "$STAGE"
  tar -czf "$TMP/good.tar.gz" .
)
# Rewrite script pin for test by computing sha of good.tar.gz is wrong —
# instead: test uses a wrapper env CYDER_DXMT_SHA256 override supported by fetch-dxmt.sh.
GOOD_SHA="$(shasum -a 256 "$TMP/good.tar.gz" | awk '{print $1}')"
E2="$TMP/engine2"
E3="$TMP/engine3"
mkdir -p "$E2" "$E3"
CYDER_DXMT_SHA256="$GOOD_SHA" CYDER_DXMT_VERSION=v0.80-test \
  bash "$SCRIPT" --engine "$E2" --also-engine "$E3" --tarball "$TMP/good.tar.gz"

for eng in "$E2" "$E3"; do
  assert test -f "$eng/lib/dxmt/x86_64-windows/d3d11.dll"
  assert test -f "$eng/lib/dxmt/x86_64-windows/dxgi.dll"
  assert test -f "$eng/lib/dxmt/x86_64-unix/winemetal.so"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "v0.80" "version pin file must record DXMT version"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "$GOOD_SHA" "version pin file must record checksum"
done

echo "PASS test-cyder-dxmt-fetch"
