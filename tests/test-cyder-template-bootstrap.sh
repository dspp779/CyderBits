#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/engine/bin" "$TMP/scripts"
cp "$ROOT/scripts/cyder-profile.sh" "$TMP/scripts/"
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
  mkdir -p "$WINEPREFIX/drive_c/windows/system32"
  : >"$WINEPREFIX/system.reg"
  : >"$WINEPREFIX/user.reg"
  : >"$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
fi
SH
cat >"$TMP/engine/bin/wineserver" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CYDER_WINESERVER_LOG:-/dev/null}"
exit 0
SH
chmod +x "$TMP/bin/arch" "$TMP/engine/bin/wine" "$TMP/engine/bin/wineserver"
export PATH="$TMP/bin:$PATH"
export CYDER_WINEBOOT_TIMEOUT=5 CYDER_ENGINE_VERSION_LABEL='wine crossover test'
export CYDER_WINESERVER_LOG="$TMP/wineserver.log"
source "$ROOT/scripts/cyder-common.sh"
cyder_wine_locale_exports() { :; }
cyder_ensure_font_replacements() { return 0; }
cyder_apply_user_settings() { : >"$CYDER_SHARED_PREFIX/.recommended-only"; }

support="$TMP/support"
export CYDER_SUPPORT="$support" CYDER_SHARED_PREFIX="$support/bottles/shared" CYDER_SCRIPTS="$TMP/scripts"
cyder_init_paths "$ROOT/scripts"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert test -f "$support/templates/pristine/manifest.json"
assert test -f "$support/templates/recommended/manifest.json"
assert test -f "$CYDER_BOOTSTRAP_MARKER"
cyder_profile_template_ready pristine "$support" 1 'wine crossover test'
cyder_profile_template_ready recommended "$support" 1 'wine crossover test'
assert test ! -e "$support/templates/pristine/.recommended-only"
assert test -f "$support/templates/recommended/.recommended-only"

# A recommended destination symlink must fail publish without removing the
# shared prefix or pristine template, and bootstrap must not publish marker.
support_fail="$TMP/support-fail"
export CYDER_SUPPORT="$support_fail" CYDER_SHARED_PREFIX="$support_fail/bottles/shared"
cyder_init_paths "$ROOT/scripts"
mkdir -p "$support_fail/templates"
mkdir -p "$TMP/external-template"
ln -s "$TMP/external-template" "$support_fail/templates/recommended"
set +e
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
status=$?
set -e
assert_ne() { [[ "$1" != "$2" ]] || { echo "ASSERT failed: $3" >&2; return 1; }; }
assert_ne "$status" 0 "recommended publish failure should fail bootstrap"
assert test -f "$support_fail/bottles/shared/system.reg"
assert test -f "$support_fail/templates/pristine/manifest.json"
assert test ! -e "$support_fail/bottles/shared/.cyder-bootstrap-v1"
assert test -d "$TMP/external-template"

# Existing shared state with no pristine template uses an isolated staging
# bottle; custom files in shared must not leak into pristine.
support_existing="$TMP/support-existing"
export CYDER_SUPPORT="$support_existing" CYDER_SHARED_PREFIX="$support_existing/bottles/shared"
cyder_init_paths "$ROOT/scripts"
mkdir -p "$CYDER_SHARED_PREFIX/drive_c/windows/system32"
: >"$CYDER_SHARED_PREFIX/system.reg"
: >"$CYDER_SHARED_PREFIX/user.reg"
: >"$CYDER_SHARED_PREFIX/drive_c/windows/system32/kernel32.dll"
: >"$CYDER_SHARED_PREFIX/custom-shared-marker"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert test -f "$support_existing/templates/pristine/manifest.json"
assert test ! -e "$support_existing/templates/pristine/custom-shared-marker"
assert test -f "$support_existing/templates/recommended/.recommended-only"

rm "$support_existing/templates/recommended/manifest.json"
session_dir="$(cyder_session_dir "$CYDER_SHARED_PREFIX")"
mkdir -p "$session_dir"
printf 'pid=%s\nmode=background\n' "$$" >"$session_dir/live.session"
: >"$CYDER_WINESERVER_LOG"
set +e
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
status=$?
set -e
assert_eq "$status" 75 "live profile session should block recommended publish"
if [[ -s "$CYDER_WINESERVER_LOG" ]]; then
  echo "ASSERT failed: active session must not stop wineserver" >&2
  cat "$CYDER_WINESERVER_LOG" >&2
  exit 1
fi
rm -f "$session_dir/live.session"

echo "PASS test-cyder-template-bootstrap"
