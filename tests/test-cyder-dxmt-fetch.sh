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
# Deliberately not the real MIT text: fetch-dxmt.sh must always overwrite
# whatever (if anything) the upstream tarball provides with the pinned
# v0.80 MIT LICENSE, never trust/pass through the archive's own file.
printf 'STAGE-PROVIDED-LICENSE-MUST-BE-OVERWRITTEN\n' >"$STAGE/LICENSE"
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
  assert test -f "$eng/lib/dxmt/LICENSE"
  assert_contains "$(cat "$eng/lib/dxmt/LICENSE")" "MIT License" \
    "installed DXMT payload must always carry the pinned v0.80 MIT LICENSE"
  assert_contains "$(cat "$eng/lib/dxmt/LICENSE")" "Feifan He" \
    "installed LICENSE must carry the upstream DXMT copyright notice"
  assert_not_contains "$(cat "$eng/lib/dxmt/LICENSE")" "STAGE-PROVIDED-LICENSE-MUST-BE-OVERWRITTEN" \
    "fetch-dxmt.sh must overwrite any upstream-provided LICENSE with the pinned MIT text"
  assert_contains "$(cat "$eng/lib/dxmt/version")" "license MIT" \
    "version pin file should note the bundled license"
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

# Tarball with i386 d3d11 but missing i386 dxgi must fail before replacing a good install.
STAGE_NO32DXGI="$TMP/stage-no32dxgi"
mkdir -p \
  "$STAGE_NO32DXGI/x86_64-windows" \
  "$STAGE_NO32DXGI/i386-windows" \
  "$STAGE_NO32DXGI/x86_64-unix"
printf 'd3d11\n' >"$STAGE_NO32DXGI/x86_64-windows/d3d11.dll"
printf 'dxgi\n' >"$STAGE_NO32DXGI/x86_64-windows/dxgi.dll"
printf 'd3d11-32\n' >"$STAGE_NO32DXGI/i386-windows/d3d11.dll"
printf 'so\n' >"$STAGE_NO32DXGI/x86_64-unix/winemetal.so"
(
  cd "$STAGE_NO32DXGI"
  tar -czf "$TMP/no-i386-dxgi.tar.gz" .
)
NO_I386_DXGI_SHA="$(shasum -a 256 "$TMP/no-i386-dxgi.tar.gz" | awk '{print $1}')"
E6="$TMP/engine6"
mkdir -p \
  "$E6/lib/dxmt/x86_64-windows" \
  "$E6/lib/dxmt/i386-windows" \
  "$E6/lib/dxmt/x86_64-unix"
printf 'existing-d3d11\n' >"$E6/lib/dxmt/x86_64-windows/d3d11.dll"
printf 'existing-dxgi\n' >"$E6/lib/dxmt/x86_64-windows/dxgi.dll"
printf 'existing-d3d11-32\n' >"$E6/lib/dxmt/i386-windows/d3d11.dll"
printf 'existing-dxgi-32\n' >"$E6/lib/dxmt/i386-windows/dxgi.dll"
printf 'existing-so\n' >"$E6/lib/dxmt/x86_64-unix/winemetal.so"
printf 'existing-version\n' >"$E6/lib/dxmt/version"
if CYDER_DXMT_SHA256="$NO_I386_DXGI_SHA" bash "$SCRIPT" --engine "$E6" --tarball "$TMP/no-i386-dxgi.tar.gz" 2>"$TMP/no-i386-dxgi.err"; then
  echo "expected failure for tarball missing i386 dxgi" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/no-i386-dxgi.err")" "i386-windows/dxgi.dll" \
  "fetch must reject tarball missing i386 dxgi"
assert test -f "$E6/lib/dxmt/i386-windows/dxgi.dll"
assert_contains "$(cat "$E6/lib/dxmt/i386-windows/dxgi.dll")" "existing-dxgi-32" \
  "fetch must not replace good lib/dxmt when payload is incomplete"
assert_contains "$(cat "$E6/lib/dxmt/version")" "existing-version" \
  "fetch must not replace version pin when payload is incomplete"

# Tarball with x86_64 d3d11 but missing x86_64 dxgi must fail before replacing a good install.
STAGE_NO64DXGI="$TMP/stage-no64dxgi"
mkdir -p \
  "$STAGE_NO64DXGI/x86_64-windows" \
  "$STAGE_NO64DXGI/i386-windows" \
  "$STAGE_NO64DXGI/x86_64-unix"
printf 'd3d11\n' >"$STAGE_NO64DXGI/x86_64-windows/d3d11.dll"
printf 'd3d11-32\n' >"$STAGE_NO64DXGI/i386-windows/d3d11.dll"
printf 'dxgi-32\n' >"$STAGE_NO64DXGI/i386-windows/dxgi.dll"
printf 'so\n' >"$STAGE_NO64DXGI/x86_64-unix/winemetal.so"
(
  cd "$STAGE_NO64DXGI"
  tar -czf "$TMP/no-x86_64-dxgi.tar.gz" .
)
NO_X86_64_DXGI_SHA="$(shasum -a 256 "$TMP/no-x86_64-dxgi.tar.gz" | awk '{print $1}')"
E7="$TMP/engine7"
mkdir -p \
  "$E7/lib/dxmt/x86_64-windows" \
  "$E7/lib/dxmt/i386-windows" \
  "$E7/lib/dxmt/x86_64-unix"
printf 'existing-d3d11\n' >"$E7/lib/dxmt/x86_64-windows/d3d11.dll"
printf 'existing-dxgi\n' >"$E7/lib/dxmt/x86_64-windows/dxgi.dll"
printf 'existing-d3d11-32\n' >"$E7/lib/dxmt/i386-windows/d3d11.dll"
printf 'existing-dxgi-32\n' >"$E7/lib/dxmt/i386-windows/dxgi.dll"
printf 'existing-so\n' >"$E7/lib/dxmt/x86_64-unix/winemetal.so"
printf 'existing-version\n' >"$E7/lib/dxmt/version"
if CYDER_DXMT_SHA256="$NO_X86_64_DXGI_SHA" bash "$SCRIPT" --engine "$E7" --tarball "$TMP/no-x86_64-dxgi.tar.gz" 2>"$TMP/no-x86_64-dxgi.err"; then
  echo "expected failure for tarball missing x86_64 dxgi" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/no-x86_64-dxgi.err")" "x86_64-windows/dxgi.dll" \
  "fetch must reject tarball missing x86_64 dxgi"
assert test -f "$E7/lib/dxmt/x86_64-windows/dxgi.dll"
assert_contains "$(cat "$E7/lib/dxmt/x86_64-windows/dxgi.dll")" "existing-dxgi" \
  "fetch must not replace good lib/dxmt when x86_64 dxgi payload is incomplete"
assert_contains "$(cat "$E7/lib/dxmt/version")" "existing-version" \
  "fetch must not replace version pin when x86_64 dxgi payload is incomplete"

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

# Dry-run WITHOUT --tarball and with nothing cached: the download itself is
# only echoed (never actually happens), so there is no local file to
# checksum/extract. Must exit 0 cleanly rather than crash on a missing file.
E8="$TMP/engine8"
CACHE8="$TMP/cache8"
mkdir -p "$E8"
# `set -e` above means this line itself fails the test if the script exits
# non-zero, so simply reaching the assertions below already proves exit 0.
CYDER_DXMT_CACHE="$CACHE8" bash "$SCRIPT" --engine "$E8" --dry-run \
  >"$TMP/dry-no-tarball.stdout" 2>"$TMP/dry-no-tarball.stderr"
assert test ! -e "$E8/lib/dxmt/x86_64-unix/winemetal.so"
assert_not_contains "$(cat "$TMP/dry-no-tarball.stderr")" "No such file or directory" \
  "dry-run without --tarball must not attempt to checksum a file that was never downloaded"
assert_contains "$(cat "$TMP/dry-no-tarball.stderr")" "Dry run" \
  "dry-run without --tarball should still report a dry-run summary"

echo "PASS test-cyder-dxmt-fetch"
