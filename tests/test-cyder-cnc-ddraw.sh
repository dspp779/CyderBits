#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

INSTALLER="$ROOT/scripts/cyder-cnc-ddraw.sh"
PAYLOAD="$ROOT/vendor/cnc-ddraw/7.1.0.0"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-cnc-ddraw.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/game" "$TMP/bottle"
printf 'test executable\n' >"$TMP/game/rich4.exe"

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
printf 'test executable\n' >"$TMP/conflict-game/game.exe"
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
