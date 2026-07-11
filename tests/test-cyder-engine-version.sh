#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

label="$(CYDER_ENGINE_VERSION_LABEL='wine crossover 26.2.0 (wine 11.0)' cyder_format_engine_version_from_wine /nonexistent 2>/dev/null || true)"
assert_eq "$label" "wine crossover 26.2.0 (wine 11.0)" "crossover label should include source and CX version"

slug="$(cyder_engine_version_slug_from_label "$label")"
assert_eq "$slug" "crossover-26.2.0-wine-11.0" "crossover slug should be filesystem-safe"

sik_label="wine sikarugir 10.0 (revision 6)"
sik_slug="$(cyder_engine_version_slug_from_label "$sik_label")"
assert_contains "$sik_slug" "sikarugir-10" "sikarugir slug should preserve vendor and wine version"

STAGE="$TMP/stage/wine-x86_64"
mkdir -p "$STAGE/bin"
printf '%s\n' '#!/bin/sh' >"$STAGE/bin/wine"
chmod +x "$STAGE/bin/wine"
cyder_write_engine_version_file "$STAGE" "$label"
assert test -f "$STAGE/version"
assert_eq "$(cyder_read_engine_version_file "$STAGE")" "$label" "version file round-trip"

TARBALL="$TMP/engine.tar.xz"
command -v xz >/dev/null || { echo "SKIP: xz not installed"; exit 0; }
(
  cd "$TMP/stage"
  tar -cf - wine-x86_64 | xz -c >"$TARBALL"
)
from_tar="$(cyder_engine_version_from_tarball "$TARBALL")"
assert_eq "$from_tar" "$label" "version should be readable from tarball"

echo "PASS test-cyder-engine-version"
