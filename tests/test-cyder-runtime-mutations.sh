#!/usr/bin/env bash
# Formal settings and runtime functions; inert dylibs, no Wine or library load.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${CYDER_TEST_SOURCE_SCRIPTS:-$ROOT/scripts}"
TEMP="$(mktemp -d /private/tmp/cy-runtime-mutations.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
export CYDER_SUPPORT="$TEMP/support" CYDER_RUNTIME_ROOT="$TEMP/runtime"
export CYDER_ENGINES="$TEMP/runtime/Engines" CYDER_ENGINE_NAME=fixture
export CYDER_SCRIPTS="$SCRIPTS" CYDER_MOCK_MACOS=13.0
engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
unix="$engine/lib/wine/x86_64-unix"
mkdir -p "$CYDER_SUPPORT" "$unix"
printf '%s\n' '{"schemaVersion":13,"graphicsBackend":"default","moltenvkVariant":"1.2.10"}' > "$CYDER_SUPPORT/settings.json"
touch "$unix/libMoltenVK-1.4.2.dylib" "$unix/libMoltenVK-1.2.10.dylib"
printf '%s\n' 'cyder-moltenvk-timeline-wait-poll' > "$unix/libMoltenVK.dylib"
ln -s libMoltenVK-1.4.2.dylib "$unix/libMoltenVK.real.dylib"
# Only the Mach-O validation tool is a fixture; formal mutation logic is used.
otool() { printf '%s\n' '@loader_path/libMoltenVK.real.dylib'; }
source "$SCRIPTS/cyder-common.sh"
cyder_load_saved_settings
[[ "$CYDER_MOLTENVK_VARIANT_PREFERENCE" == 1.2.10 ]]
[[ "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.4.2.dylib ]] || {
  echo 'FAIL reading saved settings modified shared runtime' >&2; exit 1;
}
printf '%s\n' 'PASS formal settings read selects preference without modifying engine'
export CYDER_EXECUTION_RUNTIME_MUTATION=0
status=0
cyder_apply_moltenvk_variant_from_preference "$engine" || status=$?
[[ "$status" == 75 && "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.4.2.dylib ]]
before="$(stat -f '%i' "$unix/libMoltenVK.real.dylib")"
cyder_apply_moltenvk_variant "$engine" 1.4.2
[[ "$(stat -f '%i' "$unix/libMoltenVK.real.dylib")" == "$before" ]]
printf '%s\n' 'PASS prefix-only runtime: changes refused, matching link preserved without replacement'
export CYDER_EXECUTION_RUNTIME_MUTATION=1
cyder_apply_moltenvk_variant_from_preference "$engine"
[[ "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.2.10.dylib ]]
if cyder_game_environment_key_is_allowed CYDER_MOLTENVK_VARIANT_PREFERENCE; then exit 1; fi
printf '%s\n' 'PASS global runtime: explicit mutation applies preference; per-game override refused'
