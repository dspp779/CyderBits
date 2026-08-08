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
  assert test -f "$eng/lib/dxmt/i386-windows/d3d11.dll"
  assert test -f "$eng/lib/dxmt/i386-windows/dxgi.dll"
  assert test -f "$eng/lib/dxmt/x86_64-unix/winemetal.so"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "v0.80" "version pin file must record DXMT version"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "$GOOD_SHA" "version pin file must record checksum"
done

# Tarball without i386 must fail closed.
STAGE64="$TMP/stage64"
mkdir -p \
  "$STAGE64/x86_64-windows" \
  "$STAGE64/x86_64-unix"
printf 'd3d11\n' >"$STAGE64/x86_64-windows/d3d11.dll"
printf 'dxgi\n' >"$STAGE64/x86_64-windows/dxgi.dll"
printf 'so\n' >"$STAGE64/x86_64-unix/winemetal.so"
(
  cd "$STAGE64"
  tar -czf "$TMP/no-i386.tar.gz" .
)
NO_I386_SHA="$(shasum -a 256 "$TMP/no-i386.tar.gz" | awk '{print $1}')"
E4="$TMP/engine4"
mkdir -p "$E4"
if CYDER_DXMT_SHA256="$NO_I386_SHA" bash "$SCRIPT" --engine "$E4" --tarball "$TMP/no-i386.tar.gz" 2>"$TMP/no-i386.err"; then
  echo "expected failure for tarball missing i386" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/no-i386.err")" "i386" "fetch must reject tarball without i386 payload"
assert test ! -e "$E4/lib/dxmt/x86_64-unix/winemetal.so"

# Dry-run with --tarball must not mutate engine; command echoes go to stderr only.
E5="$TMP/engine5"
mkdir -p "$E5"
CYDER_DXMT_SHA256="$GOOD_SHA" bash "$SCRIPT" --engine "$E5" --tarball "$TMP/good.tar.gz" --dry-run \
  >"$TMP/dry.stdout" 2>"$TMP/dry.stderr"
assert test ! -e "$E5/lib/dxmt/x86_64-unix/winemetal.so"
if [[ -s "$TMP/dry.stdout" ]]; then
  echo "ASSERT failed: dry-run must not print command echoes to stdout" >&2
  cat "$TMP/dry.stdout" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/dry.stderr")" "+ mkdir" "dry-run should echo planned commands to stderr"
assert_contains "$(cat "$TMP/dry.stderr")" "Dry run complete" "dry-run should report completion on stderr"

echo "PASS test-cyder-dxmt-fetch"
