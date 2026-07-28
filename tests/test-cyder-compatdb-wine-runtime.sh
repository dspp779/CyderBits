#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

runtime_patch="$ROOT/patches/cyder-compatdb-runtime.patch"
oem_runtime_patch="$ROOT/patches/cyder-compatdb-runtime-oem25.patch"
fixture="$ROOT/compatdb/tests/golden/bundled-v1.cdb"
graphics_env_fixture="$ROOT/tests/fixtures/cyder-compatdb-graphics-env.py"
source_archive="$ROOT/tools/archives/crossover-sources-26.3.0.tar.gz"
if [[ ! -f "$source_archive" ]]; then
  source_archive="$(git -C "$ROOT" rev-parse --git-common-dir)/../tools/archives/crossover-sources-26.3.0.tar.gz"
fi
oem_wine_source="${CYDER_OEM_WINE_SOURCE:-$ROOT/build/maplestory-oem25/sources/wine}"
if [[ ! -d "$oem_wine_source" ]]; then
  oem_wine_source="$(git -C "$ROOT" rev-parse --git-common-dir)/../build/maplestory-oem25/sources/wine"
fi

assert test -f "$runtime_patch"
assert test -f "$oem_runtime_patch"
assert test -f "$fixture"
assert test -f "$graphics_env_fixture"
assert test -f "$source_archive"
assert test -d "$oem_wine_source"

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
assert_contains "$patch_text" 'Skip CompatDB graphics_backend when App force is set' \
  "forced App backend must skip CompatDB graphics to avoid DLL/path stacking"
oem_patch_text="$(cat "$oem_runtime_patch")"
assert_contains "$oem_patch_text" 'Skip CompatDB graphics_backend when App force is set' \
  "OEM25 forced App backend must skip CompatDB graphics likewise"
assert_contains "$oem_patch_text" 'cyder_compat_apply_process_rules' \
  "OEM25 should use its compatible CompatDB process hook"
assert_contains "$oem_patch_text" 'CYDER_GPTK_ROOT' \
  "OEM25 should support the same GPTK root selection"
oem_compat_patch="$(awk '
  /^diff -ruN a\/dlls\/ntdll\/unix\/cyder_compat\.c b\// { capture = 1 }
  capture { print }
  capture && /^diff -ruN a\/dlls\/ntdll\/unix\/cyder_compat\.h b\// { exit }
' <<<"$oem_patch_text")"
assert_contains "$oem_compat_patch" 'void cyder_compat_cleanup_process_rules' \
  "OEM25 CompatDB source must include the process-rules cleanup implementation"
assert_contains "$oem_compat_patch" 'free( result->image_path );' \
  "OEM25 CompatDB source must include the complete cleanup body"
oem_process_patch="$(awk '
  /^diff -ruN a\/dlls\/ntdll\/unix\/process\.c b\// { capture = 1 }
  capture { print }
  capture && /^diff -ruN a\/dlls\/ntdll\/unix\/unix_private\.h b\// { exit }
' <<<"$oem_patch_text")"
assert_eq "$(grep -c '^+#include "cyder_compat.h"$' <<<"$oem_process_patch")" "1" \
  "OEM25 should include the CompatDB process hook once"
assert_eq "$(grep -c '^+    struct cyder_compat_result compat = {0};$' <<<"$oem_process_patch")" "1" \
  "OEM25 should allocate one CompatDB process result"
assert_eq "$(grep -c '^+    if (cyder_compat_apply_process_rules( &path, params, &compat )) params = &compat.params;$' <<<"$oem_process_patch")" "1" \
  "OEM25 should apply CompatDB process rules once"
if [[ "$patch_text" == *'steamwebhelper.exe'* ]]; then
  echo "ASSERT failed: Wine runtime must not hard-code a Steam executable" >&2
  exit 1
fi

magic="$(LC_ALL=C od -An -N8 -c "$fixture" | tr -d ' \n')"
assert_eq "$magic" 'CYDRCDB\0' "runtime fixture should use the CDB v1 magic"

forced_backend="$(python3 "$graphics_env_fixture" \
  '{"CYDER_GRAPHICS_BACKEND":"dxvk"}' d3dmetal)"
assert_eq "$forced_backend" "dxvk" \
  "the App-selected backend must win over a CompatDB child environment rule"
assert_eq "$(python3 "$graphics_env_fixture" '{"CYDER_GRAPHICS_BACKEND":"dxvk"}' d3dmetal --skip-check)" "0" \
  "App force must skip applying CompatDB graphics_backend actions"
rule_backend="$(python3 "$graphics_env_fixture" '{}' d3dmetal)"
assert_eq "$rule_backend" "d3dmetal" \
  "CompatDB should select its backend when the App did not select one"
assert_eq "$(python3 "$graphics_env_fixture" '{}' d3dmetal --skip-check)" "1" \
  "CompatDB graphics_backend applies when the App did not force a backend"

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

mkdir -p "$tmp/oem-wine/dlls/ntdll/unix" "$tmp/oem-wine/dlls/wined3d"
cp "$oem_wine_source/dlls/ntdll/Makefile.in" "$tmp/oem-wine/dlls/ntdll/"
cp "$oem_wine_source/dlls/ntdll/unix/process.c" "$tmp/oem-wine/dlls/ntdll/unix/"
cp "$oem_wine_source/dlls/ntdll/unix/loader.c" "$tmp/oem-wine/dlls/ntdll/unix/"
cp "$oem_wine_source/dlls/ntdll/unix/unix_private.h" "$tmp/oem-wine/dlls/ntdll/unix/"
cp "$oem_wine_source/dlls/wined3d/wined3d_main.c" "$tmp/oem-wine/dlls/wined3d/"
(
  cd "$tmp/oem-wine"
  /usr/bin/patch --forward --batch --dry-run -s -p1 < "$oem_runtime_patch"
  /usr/bin/patch --forward --batch -s -p1 < "$oem_runtime_patch"
)
oem_cyder_compat="$(cat "$tmp/oem-wine/dlls/ntdll/unix/cyder_compat.c")"
assert_contains "$oem_cyder_compat" 'void cyder_compat_cleanup_process_rules' \
  "patched OEM25 CompatDB source must include the cleanup function"
assert_contains "$oem_cyder_compat" 'memset( result, 0, sizeof(*result) );' \
  "patched OEM25 CompatDB source must include the complete cleanup body"

echo "PASS test-cyder-compatdb-wine-runtime"
