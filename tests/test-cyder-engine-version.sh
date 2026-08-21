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
cyder_engine_versions_equal "$label" "$slug" || {
  echo "ASSERT failed: display label and filesystem slug should identify the same engine" >&2
  exit 1
}
if cyder_engine_versions_equal "$label" "crossover-26.2.0-wine-12.0"; then
  echo "ASSERT failed: different Wine versions must not compare equal" >&2
  exit 1
fi

cyder_engine_versions_equal "CX26.3.0-W11-Cyder011" "CX26-3-0-W11-Cyder011" || {
  echo "ASSERT failed: dotted Cyder011 label must equal hyphenated install slug" >&2
  exit 1
}
assert_eq "$(cyder_engine_version_slug_from_label 'CX26.3.0-W11-Cyder011')" \
  "CX26-3-0-W11-Cyder011" \
  "Cyder011 slug must replace dots with hyphens"
# Canonical install marker is the dotted label; slug is only for archive names.
STAGE_CANON="$TMP/canon/wine-x86_64"
mkdir -p "$STAGE_CANON/bin"
printf '%s\n' '#!/bin/sh' >"$STAGE_CANON/bin/wine"
chmod +x "$STAGE_CANON/bin/wine"
printf '%s\n' 'CX26-3-0-W11-Cyder011' >"$STAGE_CANON/version"
cyder_write_engine_version_file "$STAGE_CANON" "CX26.3.0-W11-Cyder011"
assert_eq "$(cyder_read_engine_version_file "$STAGE_CANON")" \
  "CX26.3.0-W11-Cyder011" \
  "version file must store the dotted sidecar label, not the archive slug"
common_src="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common_src" 'Heal legacy installs that stored the filesystem slug' \
  "ensure must rewrite slug-form version files to the canonical sidecar label"
assert_contains "$common_src" 'Prefer Resources/engine-version.txt' \
  "bundled version lookup must prefer the app sidecar over archive-internal slugs"

# Prefer sidecar dotted label when the tarball still embeds the filesystem slug.
RES="$TMP/resources"
mkdir -p "$RES"
printf '%s\n' 'CX26.3.0-W11-Cyder011' >"$RES/engine-version.txt"
STAGE_TAR="$TMP/tar-src/wine-x86_64"
mkdir -p "$STAGE_TAR"
printf '%s\n' 'CX26-3-0-W11-Cyder011' >"$STAGE_TAR/version"
TARBALL_ZST="$TMP/engine-CX26-3-0-W11-Cyder011.tar.zst"
(
  cd "$TMP/tar-src"
  if command -v zstd >/dev/null 2>&1; then
    tar -cf - wine-x86_64 | zstd -q -o "$TARBALL_ZST"
  else
    # Fall back to xz naming path for hosts without zstd.
    TARBALL_ZST="$TMP/engine-CX26-3-0-W11-Cyder011.tar.xz"
    tar -cf - wine-x86_64 | xz -c >"$TARBALL_ZST"
  fi
)
from_src="$(CYDER_OGOM="$RES" cyder_bundled_engine_version_from_src "$TARBALL_ZST")"
assert_eq "$from_src" "CX26.3.0-W11-Cyder011" \
  "bundled version from archive must prefer Resources/engine-version.txt"

paths_src="$(cat "$ROOT/scripts/cyder_paths.swift")"
assert_contains "$paths_src" 'healInstalledEngineVersionLabelIfNeeded' \
  "Preferences must heal slug-form installed version labels"
settings_ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
assert_contains "$settings_ui" 'healInstalledEngineVersionLabelIfNeeded' \
  "engine version label refresh must heal before display"

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
