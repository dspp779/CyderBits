#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" 'cyder_write_bootstrap_marker' \
  "bootstrap marker helper must exist"
assert_contains "$common" 'engine=' \
  "bootstrap marker must record engine="
assert_contains "$common" 'cyder_shared_prefix_is_salvageable' \
  "salvageable bottle helper must exist"
assert_contains "$common" 'Updating shared bottle for engine' \
  "engine mismatch must update shared bottle in place"
assert_not_contains "$common" 'rm -f "$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"' \
  "engine upgrade must not delete bootstrap marker"
assert_not_contains "$common" 'rm -f "${CYDER_SHARED_PREFIX:-}/.cyder-bootstrap-v1"' \
  "invalidate must not delete bootstrap marker"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/engine/bin" "$TMP/scripts"
cat >"$TMP/bin/arch" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -x86_64 ]] && shift
exec "$@"
SH
cat >"$TMP/engine/bin/wine" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'wine-9.0\n'
elif [[ "${1:-}" == wineboot ]]; then
  printf '%s\n' "${2:--i}" >>"${CYDER_TEST_WINEBOOT_LOG:?}"
  mkdir -p "$WINEPREFIX/drive_c/windows/system32"
  : >"$WINEPREFIX/system.reg"
  : >"$WINEPREFIX/user.reg"
  : >"$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
fi
SH
cat >"$TMP/engine/bin/wineserver" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TMP/scripts/cyder-apply-golden-settings.sh" <<'SH'
#!/usr/bin/env bash
: >"$WINEPREFIX/.cyder-golden-baseline-v2"
SH
chmod +x "$TMP/bin/arch" "$TMP/engine/bin/"* "$TMP/scripts/"*

export PATH="$TMP/bin:$PATH"
export CYDER_WINEBOOT_TIMEOUT=5
export CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder011'
export CYDER_GRAPHICS_SRC="$TMP/missing-graphics"
export CYDER_TEST_WINEBOOT_LOG="$TMP/wineboot.log"
: >"$CYDER_TEST_WINEBOOT_LOG"

source "$ROOT/scripts/cyder-common.sh"
cyder_wine_locale_exports() { :; }

support="$TMP/support"
export CYDER_SUPPORT="$support" CYDER_SHARED_PREFIX="$support/bottles/shared" CYDER_SCRIPTS="$TMP/scripts"
cyder_init_paths "$ROOT/scripts"

cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert test -f "$CYDER_BOOTSTRAP_MARKER"
assert_contains "$(cat "$CYDER_BOOTSTRAP_MARKER")" 'engine=CX26.3.0-W11-Cyder011' \
  "first bootstrap must stamp engine into marker"
assert_contains "$(cat "$CYDER_TEST_WINEBOOT_LOG")" '-i' "first bootstrap creates with wineboot -i"
: >"$CYDER_SHARED_PREFIX/user-mutation"

# Same engine: ready → no wineboot.
: >"$CYDER_TEST_WINEBOOT_LOG"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert_eq "$(cat "$CYDER_TEST_WINEBOOT_LOG")" "" "matching engine marker must skip wineboot"
assert test -f "$CYDER_SHARED_PREFIX/user-mutation"

# Engine label change: in-place -u, keep user data.
export CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder012'
: >"$CYDER_TEST_WINEBOOT_LOG"
out="$(cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine" 2>&1)"
assert_contains "$out" 'Updating shared bottle for engine' \
  "engine mismatch must update shared bottle in place"
assert_contains "$(cat "$CYDER_TEST_WINEBOOT_LOG")" '-u' "engine upgrade must wineboot -u"
assert_not_contains "$out" 'Replacing incomplete bottle' \
  "salvageable bottle must not be replaced"
assert test -f "$CYDER_SHARED_PREFIX/user-mutation"
assert_contains "$(cat "$CYDER_BOOTSTRAP_MARKER")" 'engine=CX26.3.0-W11-Cyder012' \
  "marker must update to new engine after -u"

# Truly incomplete (no system.reg): replace path may wipe mutations.
rm -f "$CYDER_SHARED_PREFIX/system.reg"
: >"$CYDER_SHARED_PREFIX/user-mutation"
: >"$CYDER_TEST_WINEBOOT_LOG"
out="$(cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine" 2>&1)"
assert_contains "$out" 'Replacing incomplete bottle' \
  "missing system.reg must still replace"
assert test ! -e "$CYDER_SHARED_PREFIX/user-mutation"

echo "PASS test-cyder-bootstrap-engine-marker"
