#!/usr/bin/env bash
# Formal settings and runtime functions; inert dylibs, no Wine or library load.
# Cyder 0.15 ships only MoltenVK 1.4.2. A runtime left with .real pointing at
# the retired 1.2.10 real is repaired at launch, under the same global-scope
# and running-client rules as any shared runtime change.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${CYDER_TEST_SOURCE_SCRIPTS:-$ROOT/scripts}"
TEMP="$(mktemp -d /private/tmp/cy-runtime-mutations.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
export CYDER_SUPPORT="$TEMP/support" CYDER_RUNTIME_ROOT="$TEMP/runtime"
export CYDER_ENGINES="$TEMP/runtime/Engines" CYDER_ENGINE_NAME=fixture
export CYDER_SCRIPTS="$SCRIPTS" CYDER_MOCK_MACOS=13.0
unset CYDER_MOLTENVK_VARIANT_PREFERENCE || true
engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
unix="$engine/lib/wine/x86_64-unix"
mkdir -p "$CYDER_SUPPORT" "$unix"
printf '%s\n' '{"schemaVersion":13,"graphicsBackend":"default","moltenvkVariant":"1.2.10"}' > "$CYDER_SUPPORT/settings.json"
touch "$unix/libMoltenVK-1.4.2.dylib" "$unix/libMoltenVK-1.2.10.dylib"
printf '%s\n' 'cyder-moltenvk-timeline-wait-poll' > "$unix/libMoltenVK.dylib"
ln -s libMoltenVK-1.2.10.dylib "$unix/libMoltenVK.real.dylib"
# Only the Mach-O validation tool is a fixture; formal mutation logic is used.
source "$SCRIPTS/cyder-common.sh"
cyder_macho_reexports_real() { [[ "$1" == */libMoltenVK.dylib ]]; }
cyder_load_saved_settings
[[ -z "${CYDER_MOLTENVK_VARIANT_PREFERENCE:-}" ]] || {
  echo 'FAIL the retired moltenvkVariant setting must not be read' >&2; exit 1;
}
[[ "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.2.10.dylib ]] || {
  echo 'FAIL reading saved settings modified shared runtime' >&2; exit 1;
}
printf '%s\n' 'PASS saved 1.2.10 setting is ignored and reading settings does not touch the engine'
export CYDER_EXECUTION_RUNTIME_MUTATION=0
status=0
cyder_ensure_moltenvk_real "$engine" 2>/dev/null || status=$?
[[ "$status" == 75 && "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.2.10.dylib ]]
printf '%s\n' 'PASS prefix-only runtime: repair refused without the global scope'
export CYDER_EXECUTION_RUNTIME_MUTATION=1
# The helper's process scan decides; a fixture stands in for it here (the real
# scan is covered by test-cyder-runtime-users.sh and test-cyder-native-handoff.sh).
helper="$TEMP/CyderSwift"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$TEMP_CALLS"' \
  'echo "CYDER-RUNTIME-IN-USE component=$3 pid=99 prefix=/bottles/A name=game.exe" >&2' 'exit 75' > "$helper"
chmod +x "$helper"
export CYDER_ENVIRONMENT_HELPER="$helper" TEMP_CALLS="$TEMP/calls"
status=0
output="$(cyder_ensure_moltenvk_real "$engine" 2>&1)" || status=$?
[[ "$status" == 75 && "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.2.10.dylib ]]
grep -Fq 'CYDER-RUNTIME-IN-USE component=moltenvk pid=99' <<<"$output"
[[ "$(cat "$TEMP/calls")" == "--runtime-users $engine moltenvk" ]]
printf '%s\n' 'PASS global runtime: repair refused while the engine has running Wine clients'
export CYDER_ENVIRONMENT_HELPER="$TEMP/missing"
status=0
cyder_ensure_moltenvk_real "$engine" 2>/dev/null || status=$?
[[ "$status" == 75 && "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.2.10.dylib ]]
printf '%s\n' 'PASS global runtime: without the helper an app launch refuses rather than switching unchecked'
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$TEMP_CALLS"' 'exit 0' > "$helper"
export CYDER_ENVIRONMENT_HELPER="$helper"
cyder_ensure_moltenvk_real "$engine"
[[ "$(readlink "$unix/libMoltenVK.real.dylib")" == libMoltenVK-1.4.2.dylib ]]
printf '%s\n' 'PASS global runtime: residual 1.2.10 link is pointed back at 1.4.2'
calls="$(wc -l < "$TEMP/calls" | tr -d ' ')"
before="$(stat -f '%i' "$unix/libMoltenVK.real.dylib")"
export CYDER_EXECUTION_RUNTIME_MUTATION=0
cyder_ensure_moltenvk_real "$engine"
[[ "$(stat -f '%i' "$unix/libMoltenVK.real.dylib")" == "$before" ]]
[[ "$(wc -l < "$TEMP/calls" | tr -d ' ')" == "$calls" ]]
printf '%s\n' 'PASS a correct link needs no scope, no process scan and no replacement'
rm "$unix/libMoltenVK-1.2.10.dylib"
cyder_ensure_moltenvk_real "$engine"
printf '%s\n' 'PASS a Cyder014 engine without the 1.2.10 real is a versioned layout'
if cyder_game_environment_key_is_allowed CYDER_MOLTENVK_VARIANT_PREFERENCE; then exit 1; fi
printf '%s\n' 'PASS per-game override of the retired variable is still refused'
