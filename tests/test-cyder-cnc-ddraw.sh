#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

INSTALLER="$ROOT/scripts/cyder-cnc-ddraw.sh"
PAYLOAD="$ROOT/vendor/cnc-ddraw/7.1.0.0"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-cnc-ddraw.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/game" "$TMP/bottle"
python3 "$ROOT/tests/fixtures/make-cnc-pe.py" "$TMP/game/rich4.exe"

assert_contains "$("$INSTALLER" verify "$PAYLOAD")" \
  "valid=cnc-ddraw@7.1.0.0" \
  "vendored payload should match its pinned SHA-256"

installed="$("$INSTALLER" install "$PAYLOAD" "$TMP/game/rich4.exe" "$TMP/bottle")"
assert_contains "$installed" "installed=cnc-ddraw@7.1.0.0" \
  "installer should provision the selected executable"
assert test -f "$TMP/game/ddraw.dll"
assert test -f "$TMP/game/ddraw.ini"
assert test -d "$TMP/game/Shaders"
assert test ! -e "$TMP/game/cnc-ddraw config.exe"

again="$("$INSTALLER" install "$PAYLOAD" "$TMP/game/rich4.exe" "$TMP/bottle")"
assert_contains "$again" "unchanged=true" "reapplying the same payload should be idempotent"

printf '\nuser_setting=true\n' >>"$TMP/game/ddraw.ini"
removed="$("$INSTALLER" uninstall "$TMP/game/rich4.exe" "$TMP/bottle")"
assert_contains "$removed" "preserved_modified=1" \
  "uninstall should preserve a user-modified ddraw.ini"
assert test -f "$TMP/game/ddraw.ini"
assert test ! -e "$TMP/game/ddraw.dll"

mkdir -p "$TMP/conflict-game" "$TMP/conflict-bottle"
python3 "$ROOT/tests/fixtures/make-cnc-pe.py" "$TMP/conflict-game/game.exe"
printf 'unmanaged\n' >"$TMP/conflict-game/ddraw.dll"
if "$INSTALLER" install "$PAYLOAD" "$TMP/conflict-game/game.exe" \
  "$TMP/conflict-bottle" >"$TMP/conflict.out" 2>"$TMP/conflict.err"; then
  echo "installer unexpectedly overwrote an unmanaged ddraw.dll" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/conflict.err")" "refusing to overwrite unmanaged" \
  "unmanaged wrappers must require explicit user resolution"
assert_eq "$(cat "$TMP/conflict-game/ddraw.dll")" "unmanaged" \
  "unmanaged DLL content must remain untouched"

echo "PASS test-cyder-cnc-ddraw"

# A receipt from older app versions lives in a shared bottle and may have been
# edited by hand. Never let it choose a file/hash outside the pinned release.
mkdir "$TMP/replay" "$TMP/prefix"
python3 "$ROOT/tests/fixtures/make-cnc-pe.py" "$TMP/replay/game.exe"
"$INSTALLER" install "$PAYLOAD" "$TMP/replay/game.exe" "$TMP/prefix" >/dev/null
manifest="$(find "$TMP/prefix" -name manifest.tsv -type f)"
cp "$manifest" "$TMP/good-receipt"
printf 'private\n' >"$TMP/keep"
printf 'file\t%s\tShaders/../../keep\n' "$(shasum -a 256 "$TMP/keep" | cut -d ' ' -f 1)" >> "$manifest"
if "$INSTALLER" uninstall "$TMP/replay/game.exe" "$TMP/prefix" >"$TMP/out" 2>&1; then exit 1; fi
assert_contains "$(cat "$TMP/out")" 'unsafe manifest' 'reject replay before any removal'
assert test -f "$TMP/replay/ddraw.dll"
assert_eq "$(cat "$TMP/keep")" private 'outside file survived forged receipt'
cp "$TMP/good-receipt" "$manifest"
mv "$TMP/replay/Shaders" "$TMP/user-shaders"; ln -s "$TMP/user-shaders" "$TMP/replay/Shaders"
if "$INSTALLER" uninstall "$TMP/replay/game.exe" "$TMP/prefix" >"$TMP/out" 2>&1; then exit 1; fi
assert test -f "$TMP/replay/ddraw.dll"
assert test -f "$TMP/user-shaders/interpolation/catmull-rom-bilinear.glsl"
unlink "$TMP/replay/Shaders"
mv "$TMP/user-shaders" "$TMP/replay/Shaders"
mkdir "$TMP/replay/Shaders/empty-user-directory"
"$INSTALLER" uninstall "$TMP/replay/game.exe" "$TMP/prefix" >/dev/null
assert test -d "$TMP/replay/Shaders/empty-user-directory"
assert test ! -e "$TMP/replay/ddraw.dll"
echo 'PASS legacy manifest traversal, parent symlink and unmanaged directories'

# Another process can atomically put byte-for-byte identical official files
# at the same location. New receipts bind each installed inode as well.
mkdir "$TMP/identical" "$TMP/identity-prefix"
python3 "$ROOT/tests/fixtures/make-cnc-pe.py" "$TMP/identical/test.exe"
"$INSTALLER" install "$PAYLOAD" "$TMP/identical/test.exe" "$TMP/identity-prefix" >/dev/null
cp "$TMP/identical/ddraw.dll" "$TMP/other-instance.dll"
mv -f "$TMP/other-instance.dll" "$TMP/identical/ddraw.dll"
out="$("$INSTALLER" uninstall "$TMP/identical/test.exe" "$TMP/identity-prefix")"
assert_contains "$out" 'preserved_modified=1' 'identical replacement is user-owned'
assert test -f "$TMP/identical/ddraw.dll"
echo 'PASS external byte-identical replacement inode preserved'
