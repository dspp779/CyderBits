#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

WINE_SOURCE="${WINE_SOURCE:-$ROOT/build/cx26/sources/wine}"
WINE_BUILD="${WINE_BUILD:-$WINE_SOURCE/build64}"
RUNTIME_PATCH="$ROOT/patches/cyder-compatdb-runtime.patch"
LEGACY_PATCH="$ROOT/patches/cyder-steam-webhelper-compat.patch"
GOLDEN="$ROOT/compatdb/tests/golden/bundled-v1.cdb"
VARIANT_TOOL="$ROOT/tests/fixtures/cyder-compatdb-runtime-variants.py"
COMPILER="$ROOT/scripts/cyder-compatdb.py"
ALL_ACTIONS_RULE="$ROOT/compatdb/tests/fixtures/all-actions.yml"
ARGV_SOURCE="$ROOT/tests/fixtures/cyder-compatdb-argv.c"
LLVM_MINGW="$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal"
BUILD_PATH="$LLVM_MINGW/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-compatdb-wine-runtime.XXXXXX")"
PATCHED_BY_TEST=0
LEGACY_REVERSED_BY_TEST=0

cleanup() {
  local status=$?
  set +e
  if [[ -x "$WINE_BUILD/server/wineserver" && -d "$TEST_TMP/prefix" ]]; then
    env WINEPREFIX="$TEST_TMP/prefix" \
      /usr/bin/arch -x86_64 "$WINE_BUILD/server/wineserver" -k >/dev/null 2>&1
  fi
  if [[ "$PATCHED_BY_TEST" -eq 1 ]]; then
    (
      cd "$WINE_SOURCE"
      /usr/bin/patch --reverse --batch -s -p1 < "$RUNTIME_PATCH"
      /usr/bin/arch -x86_64 env PATH="$BUILD_PATH" make -C "$WINE_BUILD" Makefile
      /usr/bin/arch -x86_64 env PATH="$BUILD_PATH" make -C "$WINE_BUILD" \
        dlls/ntdll/unix/process.o dlls/ntdll/ntdll.so \
        dlls/wined3d/x86_64-windows/wined3d_main.o \
        dlls/wined3d/x86_64-windows/wined3d.dll
      rm -f dlls/ntdll/unix/cyder_compat.c dlls/ntdll/unix/cyder_compat.h
    ) >/dev/null 2>&1
  fi
  if [[ "$LEGACY_REVERSED_BY_TEST" -eq 1 ]]; then
    (
      cd "$WINE_SOURCE"
      /usr/bin/patch --forward --batch -s -p1 < "$LEGACY_PATCH"
      /usr/bin/arch -x86_64 env PATH="$BUILD_PATH" make -C "$WINE_BUILD" \
        dlls/kernelbase/x86_64-windows/process.o \
        dlls/kernelbase/x86_64-windows/kernelbase.dll
    ) >/dev/null 2>&1
  fi
  if [[ "${KEEP_RUNTIME_TEST_TMP:-0}" == 1 ]]; then
    echo "kept runtime verification artifacts at $TEST_TMP" >&2
  else
    rm -rf "$TEST_TMP"
  fi
  exit "$status"
}
trap cleanup EXIT

assert test -x "$WINE_BUILD/loader/wine"
assert test -x "$WINE_BUILD/server/wineserver"
assert test -x "$LLVM_MINGW/bin/x86_64-w64-mingw32-clang"

# Reversing a patch which adds a file can leave a zero-byte placeholder with
# some patch(1) versions. It is not source and must not block the next verify.
for generated in \
  "$WINE_SOURCE/dlls/ntdll/unix/cyder_compat.c" \
  "$WINE_SOURCE/dlls/ntdll/unix/cyder_compat.h"; do
  if [[ -f "$generated" && ! -s "$generated" ]]; then rm -f "$generated"; fi
done

# The generic runtime replaces the earlier hard-coded Steam experiment. Remove
# it for this verification and restore it exactly on exit when the local source
# tree still contains it.
if (
  cd "$WINE_SOURCE"
  /usr/bin/patch --reverse --batch --dry-run -s -p1 < "$LEGACY_PATCH"
); then
  (
    cd "$WINE_SOURCE"
    /usr/bin/patch --reverse --batch -s -p1 < "$LEGACY_PATCH"
  )
  LEGACY_REVERSED_BY_TEST=1
elif ! (
  cd "$WINE_SOURCE"
  /usr/bin/patch --forward --batch --dry-run -s -p1 < "$LEGACY_PATCH"
); then
  echo "Wine kernelbase is neither pristine nor exactly legacy-patched" >&2
  exit 1
fi

if (
  cd "$WINE_SOURCE"
  /usr/bin/patch --forward --batch --dry-run -s -p1 < "$RUNTIME_PATCH"
); then
  (
    cd "$WINE_SOURCE"
    /usr/bin/patch --forward --batch -s -p1 < "$RUNTIME_PATCH"
  )
  PATCHED_BY_TEST=1
elif ! (
  cd "$WINE_SOURCE"
  /usr/bin/patch --reverse --batch --dry-run -s -p1 < "$RUNTIME_PATCH"
); then
  echo "Wine source is neither pristine nor exactly runtime-patched" >&2
  exit 1
fi

/usr/bin/arch -x86_64 env PATH="$BUILD_PATH" make -C "$WINE_BUILD" Makefile
/usr/bin/arch -x86_64 env PATH="$BUILD_PATH" make -C "$WINE_BUILD" \
  dlls/ntdll/unix/cyder_compat.o \
  dlls/ntdll/unix/process.o \
  dlls/ntdll/ntdll.so \
  dlls/kernelbase/x86_64-windows/process.o \
  dlls/kernelbase/x86_64-windows/kernelbase.dll \
  dlls/wined3d/x86_64-windows/wined3d_main.o \
  dlls/wined3d/x86_64-windows/wined3d.dll

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/prefix"
"$LLVM_MINGW/bin/x86_64-w64-mingw32-clang" -municode -Os \
  "$ARGV_SOURCE" -o "$TEST_TMP/bin/steamwebhelper.exe"
cp "$TEST_TMP/bin/steamwebhelper.exe" "$TEST_TMP/bin/rich4.exe"
cp "$TEST_TMP/bin/steamwebhelper.exe" "$TEST_TMP/bin/action-source.exe"
cp "$TEST_TMP/bin/steamwebhelper.exe" "$TEST_TMP/bin/replace-source.exe"
cp "$TEST_TMP/bin/steamwebhelper.exe" "$TEST_TMP/bin/replace-target.exe"
cp "$TEST_TMP/bin/steamwebhelper.exe" "$TEST_TMP/bin/backend-source.exe"

for variant in optional required truncated duplicate unicode dll; do
  python3 "$VARIANT_TOOL" "$variant" "$GOLDEN" "$TEST_TMP/$variant.cdb"
done
python3 "$COMPILER" compile "$ALL_ACTIONS_RULE" \
  -o "$TEST_TMP/all-actions.cdb" >/dev/null

WINE="$WINE_BUILD/loader/wine"
WIN_EXE="Z:${TEST_TMP//\//\\}\\bin\\steamwebhelper.exe"
WIN_RICH4_EXE="Z:${TEST_TMP//\//\\}\\bin\\rich4.exe"
WIN_ACTION_EXE="Z:${TEST_TMP//\//\\}\\bin\\action-source.exe"
WIN_REPLACE_EXE="Z:${TEST_TMP//\//\\}\\bin\\replace-source.exe"
WIN_BACKEND_EXE="Z:${TEST_TMP//\//\\}\\bin\\backend-source.exe"

# Initialize once so setup helpers do not obscure the process-rule cases.
env WINEPREFIX="$TEST_TMP/prefix" WINEDEBUG=-all \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c exit >/dev/null 2>&1

run_case() {
  local name="$1"
  local database="$2"
  shift 2
  env WINEPREFIX="$TEST_TMP/prefix" \
    CYDER_COMPATDB_PATH="$database" \
    WINEDEBUG=+cydercompat \
    /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
      "$WIN_EXE $*" >"$TEST_TMP/$name.out" 2>"$TEST_TMP/$name.log"
}

run_case renderer "$GOLDEN" base
renderer_out="$(cat "$TEST_TMP/renderer.out")"
renderer_log="$(cat "$TEST_TMP/renderer.log")"
assert_contains "$renderer_log" 'matched rule "launcher.steam.webhelper.cef-gpu"' \
  "renderer child should match the Steam rule"
assert_contains "$renderer_out" '=--no-sandbox' \
  "renderer child should receive --no-sandbox"
assert_contains "$renderer_out" '=--in-process-gpu' \
  "renderer child should receive --in-process-gpu"
assert_contains "$renderer_out" '=--disable-gpu' \
  "renderer child should receive --disable-gpu"

env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB_PATH="$GOLDEN" \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_RICH4_EXE base" >"$TEST_TMP/rich4.out" 2>"$TEST_TMP/rich4.log"
assert_contains "$(cat "$TEST_TMP/rich4.log")" \
  'matched rule "game.richman-4.cnc-ddraw"' \
  "Richman 4 should match its bundled CompatDB rule"
assert_contains "$(cat "$TEST_TMP/rich4.log")" \
  'adding process-local DLL override "ddraw=n,b"' \
  "Richman 4 should receive the process-local cnc-ddraw load order"

env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB_PATH="$TEST_TMP/all-actions.cdb" \
  TEST_REMOVE=remove-me \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_ACTION_EXE base" >"$TEST_TMP/actions.out" 2>"$TEST_TMP/actions.log"
actions_out="$(cat "$TEST_TMP/actions.out")"
actions_log="$(cat "$TEST_TMP/actions.log")"
assert_contains "$actions_out" '=--compat-action' \
  "append_args should compose with the other process actions"
assert_contains "$actions_out" 'ENV_TEST_SET=from-compatdb' \
  "set_env should replace the target process environment value"
assert_contains "$actions_out" 'ENV_TEST_REMOVE=<unset>' \
  "unset_env should remove the target process environment value"
assert_contains "$actions_out" 'ENV_CYDER_GRAPHICS_BACKEND=wined3d' \
  "graphics_backend should select the process-local translation stack"
assert_contains "$actions_out" 'ENV_CYDER_WINED3D_RENDERER=gdi' \
  "wined3d_renderer should select the process-local WineD3D renderer"
assert_contains "$actions_log" 'adding process-local DLL override "version=b,n"' \
  "dll_overrides should compose with environment and graphics actions"
if [[ "$actions_log" == *'adding process-local DLL override "version=n"'* ]]; then
  echo "lower-priority DLL override replaced the higher-priority action" >&2
  exit 1
fi

env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB_PATH="$TEST_TMP/all-actions.cdb" \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_REPLACE_EXE base" >"$TEST_TMP/replacement.out" 2>"$TEST_TMP/replacement.log"
assert_contains "$(cat "$TEST_TMP/replacement.out")" 'replace-target.exe' \
  "replace_executable should update argv[0] to the selected target"
assert_contains "$(cat "$TEST_TMP/replacement.log")" 'replacing executable with' \
  "replace_executable should redirect the PE image before it is opened"

env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB_PATH="$TEST_TMP/all-actions.cdb" \
  CYDER_GRAPHICS_BACKENDS_ROOT="$TEST_TMP/missing-backends" \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_BACKEND_EXE base" >"$TEST_TMP/backend-fallback.out" 2>"$TEST_TMP/backend-fallback.log"
assert_contains "$(cat "$TEST_TMP/backend-fallback.log")" \
  'graphics backend "dxvk" is unavailable; falling back to wined3d' \
  "missing backend payload should fail safely to WineD3D"

mkdir -p "$TEST_TMP/engine/lib/dxvk/x86_64-windows"
mkdir -p "$TEST_TMP/engine/lib/wine/x86_64-unix"
cp "$WINE_BUILD/dlls/d3d11/x86_64-windows/d3d11.dll" \
  "$TEST_TMP/engine/lib/dxvk/x86_64-windows/d3d11.dll"
cp "$ROOT/install/wine-cx26-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib" \
  "$TEST_TMP/engine/lib/wine/x86_64-unix/libMoltenVK.dylib"
env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB_PATH="$TEST_TMP/all-actions.cdb" \
  CYDER_GRAPHICS_BACKENDS_ROOT="$TEST_TMP/engine" \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_BACKEND_EXE base" >"$TEST_TMP/backend-found.out" 2>"$TEST_TMP/backend-found.log"
assert_contains "$(cat "$TEST_TMP/backend-found.log")" \
  'activated graphics backend "dxvk"' \
  "present architecture-specific backend payload should be activated"

run_case crashpad "$GOLDEN" --type=crashpad-handler
if grep -q 'matched rule' "$TEST_TMP/crashpad.log" ||
   grep -q '=--no-sandbox' "$TEST_TMP/crashpad.out"; then
  echo "crashpad handler unexpectedly received renderer actions" >&2
  exit 1
fi

env WINEPREFIX="$TEST_TMP/prefix" \
  CYDER_COMPATDB=0 \
  CYDER_COMPATDB_PATH="$GOLDEN" \
  WINEDEBUG=+cydercompat \
  /usr/bin/arch -x86_64 "$WINE" cmd.exe /d /c \
    "$WIN_EXE base" >"$TEST_TMP/optout.out" 2>"$TEST_TMP/optout.log"
if grep -q 'loaded CDB' "$TEST_TMP/optout.log" ||
   grep -q '=--no-sandbox' "$TEST_TMP/optout.out"; then
  echo "CYDER_COMPATDB=0 did not disable runtime rules" >&2
  exit 1
fi

run_case dedupe "$GOLDEN" --IN-PROCESS-GPU=caller
assert_contains "$(cat "$TEST_TMP/dedupe.out")" '=--IN-PROCESS-GPU=caller' \
  "caller option should be preserved"
if grep -Eq '^ARG[0-9]+=--in-process-gpu$' "$TEST_TMP/dedupe.out"; then
  echo "ASCII-case-insensitive option key was appended twice" >&2
  exit 1
fi

run_case unicode "$TEST_TMP/unicode.cdb" base
assert_contains "$(cat "$TEST_TMP/unicode.out")" '=\u6e2c\u8a66 arg "quoted"\' \
  "UTF-8 action should survive Windows quoting as one argv token"

run_case dll "$TEST_TMP/dll.cdb" base
assert_contains "$(cat "$TEST_TMP/dll.log")" \
  'adding process-local DLL override "ddraw=n,b"' \
  "matched executable should receive its process-local DLL load order"

run_case optional "$TEST_TMP/optional.cdb" base
assert_contains "$(cat "$TEST_TMP/optional.log")" 'matched rule' \
  "unknown optional TLV should be skipped"

run_case required "$TEST_TMP/required.cdb" base
if grep -q 'matched rule' "$TEST_TMP/required.log" ||
   grep -q '=--no-sandbox' "$TEST_TMP/required.out"; then
  echo "unknown required TLV did not invalidate its rule" >&2
  exit 1
fi

run_case truncated "$TEST_TMP/truncated.cdb" base
if grep -q 'matched rule' "$TEST_TMP/truncated.log" ||
   grep -q '=--no-sandbox' "$TEST_TMP/truncated.out"; then
  echo "truncated database did not fail open" >&2
  exit 1
fi

run_case duplicate "$TEST_TMP/duplicate.cdb" base
assert_contains "$(cat "$TEST_TMP/duplicate.log")" 'duplicate rule ID' \
  "duplicate IDs should be rejected before actions"
if grep -q 'matched rule' "$TEST_TMP/duplicate.log" ||
   grep -q '=--no-sandbox' "$TEST_TMP/duplicate.out"; then
  echo "duplicate-ID database applied actions before rejection" >&2
  exit 1
fi

echo "PASS verify-cyder-compatdb-wine-runtime"
