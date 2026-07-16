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
exit 0
SH
cat >"$TMP/scripts/install-wine-mono.sh" <<'SH'
#!/usr/bin/env bash
: >"$WINEPREFIX/.cyder-mono-10.4.1"
SH
cat >"$TMP/scripts/install-wine-gecko.sh" <<'SH'
#!/usr/bin/env bash
: >"$WINEPREFIX/.cyder-gecko-2.47.4"
SH
cat >"$TMP/scripts/cyder-apply-golden-settings.sh" <<'SH'
#!/usr/bin/env bash
: >"$WINEPREFIX/.cyder-golden-baseline-v2"
: >"$WINEPREFIX/.golden-only"
SH
chmod +x "$TMP/bin/arch" "$TMP/engine/bin/"* "$TMP/scripts/"*

export PATH="$TMP/bin:$PATH"
export CYDER_WINEBOOT_TIMEOUT=5 CYDER_ENGINE_VERSION_LABEL='wine crossover test'
source "$ROOT/scripts/cyder-common.sh"
cyder_wine_locale_exports() { :; }

support="$TMP/support"
export CYDER_SUPPORT="$support" CYDER_SHARED_PREFIX="$support/bottles/shared" CYDER_SCRIPTS="$TMP/scripts"
cyder_init_paths "$ROOT/scripts"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"

assert test -f "$support/templates/pristine/manifest.json"
assert test -f "$support/templates/golden/manifest.json"
assert test -f "$support/templates/golden/.cyder-mono-10.4.1"
assert test -f "$support/templates/golden/.cyder-gecko-2.47.4"
assert test -f "$support/templates/golden/.cyder-golden-baseline-v2"
assert test ! -e "$support/templates/pristine/.golden-only"
assert test -f "$CYDER_SHARED_PREFIX/.golden-only"
assert test -f "$CYDER_BOOTSTRAP_MARKER"
cyder_profile_template_ready pristine "$support" 2 'wine crossover test'
cyder_profile_template_ready golden "$support" 2 'wine crossover test'

# Shared state is disposable and must never flow back into Golden.
: >"$CYDER_SHARED_PREFIX/user-mutation"
rm -f "$CYDER_BOOTSTRAP_MARKER"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert test ! -e "$CYDER_SHARED_PREFIX/user-mutation"
assert test ! -e "$support/templates/golden/user-mutation"
assert test -f "$CYDER_SHARED_PREFIX/.golden-only"

# An unsafe Golden destination aborts before a Shared prefix is published.
support_fail="$TMP/support-fail"
export CYDER_SUPPORT="$support_fail" CYDER_SHARED_PREFIX="$support_fail/bottles/shared"
cyder_init_paths "$ROOT/scripts"
mkdir -p "$support_fail/templates" "$TMP/external-golden"
rm -rf "$support_fail/templates/golden"
ln -s "$TMP/external-golden" "$support_fail/templates/golden"
set +e
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "ASSERT failed: unsafe Golden publish succeeded" >&2; exit 1; }
assert test ! -e "$CYDER_SHARED_PREFIX"
assert test -d "$TMP/external-golden"

echo "PASS test-cyder-template-bootstrap"
