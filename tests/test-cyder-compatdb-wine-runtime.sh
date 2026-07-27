#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

runtime_patch="$ROOT/patches/cyder-compatdb-runtime.patch"
fixture="$ROOT/compatdb/tests/golden/bundled-v1.cdb"
source_archive="$ROOT/tools/archives/crossover-sources-26.3.0.tar.gz"
if [[ ! -f "$source_archive" ]]; then
  source_archive="$(git -C "$ROOT" rev-parse --git-common-dir)/../tools/archives/crossover-sources-26.3.0.tar.gz"
fi

assert test -f "$runtime_patch"
assert test -f "$fixture"
assert test -f "$source_archive"

patch_text="$(cat "$runtime_patch")"
assert_contains "$patch_text" 'cyder_compat_apply_process_rules' \
  "NtCreateUserProcess should invoke the generic CompatDB hook"
assert_contains "$patch_text" 'CYDER_COMPATDB_PATH' \
  "runtime should load the session-selected immutable CDB"
assert_contains "$patch_text" 'CYDER_COMPATDB' \
  "runtime should expose the global opt-out"
assert_contains "$patch_text" 'CYDER_CDB_MAX_FILE_SIZE' \
  "runtime parser should enforce a file-size bound"
assert_contains "$patch_text" 'validate_cdb_structure' \
  "runtime should validate the complete TLV structure before applying rules"
assert_contains "$patch_text" 'CYDER_CDB_MATCH_PATH_SUFFIX' \
  "runtime should support executable path suffix matching"
assert_contains "$patch_text" 'CYDER_CDB_MATCH_FORBIDDEN_ARG' \
  "runtime should support forbidden argv tokens"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_APPEND_ARG' \
  "runtime should support typed append-argument actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_DLL_OVERRIDE' \
  "runtime should support typed process-local DLL override actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_SET_ENV' \
  "runtime should support typed set-environment actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_UNSET_ENV' \
  "runtime should support typed unset-environment actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_GRAPHICS_BACKEND' \
  "runtime should support typed graphics-backend actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_WINED3D_RENDERER' \
  "runtime should support typed WineD3D-renderer actions"
assert_contains "$patch_text" 'CYDER_CDB_ACTION_REPLACE_EXECUTABLE' \
  "runtime should support typed executable-replacement actions"
assert_contains "$patch_text" 'add_load_order_override' \
  "DLL overrides should enter Wine's in-memory load-order table"
assert_contains "$patch_text" 'CYDER_WINED3D_RENDERER' \
  "wined3d should consume the process-local renderer selection"
assert_contains "$patch_text" 'CYDER_GRAPHICS_BACKENDS_ROOT' \
  "translation backends should be capability-gated by their runtime payload"
assert_contains "$patch_text" 'CYDER_GPTK_ROOT' \
  "d3dmetal should accept an explicit GPTK runtime root"
assert_contains "$patch_text" 'CX_APPLEGPTK_LIBD3DSHARED_PATH' \
  "d3dmetal should export the GPTK shared-library path"
assert_contains "$patch_text" 'getenv( "CYDER_GRAPHICS_BACKEND" )' \
  "the environment should force a graphics backend after CompatDB rules"
assert_contains "$patch_text" 'apply_graphics_backend( &slice, &applied )' \
  "the forced graphics backend should use the normal backend activation path"
if [[ "$patch_text" == *'steamwebhelper.exe'* ]]; then
  echo "ASSERT failed: Wine runtime must not hard-code a Steam executable" >&2
  exit 1
fi

magic="$(LC_ALL=C od -An -N8 -c "$fixture" | tr -d ' \n')"
assert_eq "$magic" 'CYDRCDB\0' "runtime fixture should use the CDB v1 magic"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-compatdb-runtime.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sources/wine/dlls/ntdll/unix" "$tmp/sources/wine/dlls/wined3d"
tar -xzf "$source_archive" -C "$tmp" \
  sources/wine/dlls/ntdll/Makefile.in \
  sources/wine/dlls/ntdll/unix/process.c \
  sources/wine/dlls/ntdll/unix/loader.c \
  sources/wine/dlls/ntdll/unix/unix_private.h \
  sources/wine/dlls/wined3d/wined3d_main.c

(
  cd "$tmp/sources/wine"
  /usr/bin/patch --forward --batch --dry-run -s -p1 < "$runtime_patch"
)

echo "PASS test-cyder-compatdb-wine-runtime"
