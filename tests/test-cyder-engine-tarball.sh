#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RES="$TMP/Resources"
ENGINE_ROOT="$TMP/Engines"
mkdir -p "$RES/ogom-scripts" "$ENGINE_ROOT"
cp "$ROOT/scripts/cyder-common.sh" "$RES/ogom-scripts/"

STAGE="$TMP/stage/wine-x86_64"
mkdir -p "$STAGE/bin"
printf '%s\n' '#!/bin/sh' 'echo wine-stub' >"$STAGE/bin/wine"
chmod +x "$STAGE/bin/wine"

ENGINE_VERSION_LABEL="wine crossover 26.2.0 (wine 11.0)"
ENGINE_VERSION_SLUG="$(cyder_engine_version_slug_from_label "$ENGINE_VERSION_LABEL")"
cyder_write_engine_version_file "$STAGE" "$ENGINE_VERSION_LABEL"

ENGINE_TAR="$RES/engine-${ENGINE_VERSION_SLUG}.tar.xz"
command -v xz >/dev/null || { echo "SKIP: xz not installed"; exit 0; }
(
  cd "$TMP/stage"
  tar -cf - wine-x86_64 | xz -c >"$ENGINE_TAR"
)
cyder_write_app_engine_metadata() {
  local res_dir="$1" archive_path="$2" version_label="$3"
  printf '%s\n' "$version_label" >"$res_dir/engine-version.txt"
  printf '%s\n' "$(basename "$archive_path")" >"$res_dir/engine-archive.txt"
}
cyder_write_app_engine_metadata "$RES" "$ENGINE_TAR" "$ENGINE_VERSION_LABEL"

# This fixture tests extraction/version lifecycle, not macOS codesign. The
# production app bundles sign-wine.sh and cyder-common invokes it here.
cyder_sign_installed_engine() {
  printf 'signed\n' >"$1/.cyder-engine-signed"
}

CYDER_SUPPORT="$TMP/CyderSupport"
CYDER_ENGINES="$ENGINE_ROOT"
CYDER_SHARED_PREFIX="$TMP/SharedPrefix"
mkdir -p "$CYDER_SHARED_PREFIX"
printf 'ok\n' >"$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
export CYDER_SUPPORT CYDER_ENGINES CYDER_SHARED_PREFIX

cyder_init_paths "$RES"
CYDER_ENGINES="$ENGINE_ROOT"
export CYDER_ENGINES
assert test -f "$CYDER_ENGINE_SRC"
assert_contains "$CYDER_ENGINE_SRC" ".tar.xz" "default engine src should be xz tarball"

dest="$(cyder_ensure_shared_engine "$CYDER_ENGINE_SRC")"
assert test -x "$dest/bin/wine"
assert test -f "$dest/version"
assert_contains "$(cat "$dest/version")" "crossover 26.2.0" "installed engine should record version file"
[[ ! -f "$dest/.cyder-engine-version" ]] || {
  echo "ASSERT failed: legacy version marker should not be written" >&2
  exit 1
}
[[ ! -f "$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1" ]] || {
  echo "ASSERT failed: fresh engine install should reset SharedPrefix" >&2
  exit 1
}

output="$(cyder_ensure_shared_engine "$CYDER_ENGINE_SRC" 2>&1)"
assert_contains "$output" "Shared engine present" "second install should skip extract"

# Bootstrap/rebuild resolution must trust matching sidecar files instead of
# opening the large bundled archive again. Corrupting the fixture proves that
# this fast path performs no tar stream decompression.
printf 'intentionally not a tar archive\n' >"$ENGINE_TAR"
output="$(cyder_resolve_shared_engine "$CYDER_ENGINE_SRC" 2>&1)"
assert_contains "$output" "Shared engine current (sidecar)" \
  "current bundled engine should resolve without reading its archive"

ENGINE_VERSION_LABEL_V2="wine crossover 26.2.0 (wine 12.0)"
ENGINE_VERSION_SLUG_V2="$(cyder_engine_version_slug_from_label "$ENGINE_VERSION_LABEL_V2")"
STAGE_V2="$TMP/stage2/wine-x86_64"
mkdir -p "$STAGE_V2/bin"
printf '%s\n' '#!/bin/sh' >"$STAGE_V2/bin/wine"
chmod +x "$STAGE_V2/bin/wine"
cyder_write_engine_version_file "$STAGE_V2" "$ENGINE_VERSION_LABEL_V2"
ENGINE_TAR_V2="$TMP/engine-v2.tar.xz"
(
  cd "$TMP/stage2"
  tar -cf - wine-x86_64 | xz -c >"$ENGINE_TAR_V2"
)
mkdir -p "$CYDER_SHARED_PREFIX"
printf 'ok\n' >"$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
cyder_ensure_shared_engine "$ENGINE_TAR_V2" >/dev/null
[[ ! -f "$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1" ]] || {
  echo "ASSERT failed: engine upgrade should reset SharedPrefix" >&2
  exit 1
}
assert_contains "$(cyder_read_installed_engine_version "$dest")" "wine 12.0" "upgraded engine version file"

echo "PASS test-cyder-engine-tarball"
