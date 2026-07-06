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

ENGINE_VERSION="CX26-11.0"
ENGINE_TAR="$RES/engine-${ENGINE_VERSION}.tar.zst"
command -v zstd >/dev/null || { echo "SKIP: zstd not installed"; exit 0; }
(
  cd "$TMP/stage"
  tar -cf - wine-x86_64 | zstd -22 --ultra -T0 -o "$ENGINE_TAR"
)
printf '%s\n' "$ENGINE_VERSION" >"$RES/engine-version.txt"

cyder_init_paths "$RES"
assert test -f "$CYDER_ENGINE_SRC"
assert_contains "$CYDER_ENGINE_SRC" ".tar.zst" "default engine src should be zstd tarball"

CYDER_SUPPORT="$TMP/CyderSupport"
CYDER_ENGINES="$ENGINE_ROOT"
export CYDER_SUPPORT CYDER_ENGINES
dest="$(cyder_ensure_shared_engine "$CYDER_ENGINE_SRC")"
assert test -x "$dest/bin/wine"
assert test -f "$dest/.cyder-engine-version"
assert_contains "$(cat "$dest/.cyder-engine-version")" "CX26-11.0" "installed engine version marker"

output="$(cyder_ensure_shared_engine "$CYDER_ENGINE_SRC" 2>&1)"
assert_contains "$output" "Shared engine present" "second install should skip extract"

echo "PASS test-cyder-engine-tarball"
