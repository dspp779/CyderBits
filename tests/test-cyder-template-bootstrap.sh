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
assert_eq "${CYDER_BOOTSTRAP_HEALTH_CHECKED:-0}" "1" \
  "new Shared prefix should report that bootstrap already ran its health probe"

assert test ! -e "$support/templates/pristine/manifest.json"
assert test ! -e "$support/templates/golden/manifest.json"
assert test -f "$CYDER_SHARED_PREFIX/.cyder-mono-10.4.1"
assert test -f "$CYDER_SHARED_PREFIX/.cyder-gecko-2.47.4"
assert test -f "$CYDER_SHARED_PREFIX/.cyder-golden-baseline-v2"
assert test -f "$CYDER_SHARED_PREFIX/.golden-only"
assert test -f "$CYDER_BOOTSTRAP_MARKER"

# Replacing shared provisions a fresh baseline; mutations must not survive.
: >"$CYDER_SHARED_PREFIX/user-mutation"
rm -f "$CYDER_BOOTSTRAP_MARKER"
cyder_bootstrap_shared_prefix "$TMP/engine/bin/wine" "$TMP/engine"
assert_eq "${CYDER_BOOTSTRAP_HEALTH_CHECKED:-0}" "1" \
  "replacement Shared prefix should report its completed health probe"
assert test ! -e "$CYDER_SHARED_PREFIX/user-mutation"
assert test -f "$CYDER_SHARED_PREFIX/.golden-only"
if find "$support" -type d \( -path '*/backups/*' -o -name '.bootstrap-previous-*' -o -name '.bootstrap-staging-*' \) -print -quit | grep -q .; then
  echo "ASSERT failed: successful bootstrap should not retain the previous shared bottle" >&2
  exit 1
fi

# Engine upgrade path drops stale template bottles if present.
mkdir -p "$support/templates/golden"
: >"$support/templates/golden/manifest.json"
cyder_remove_path "$support/templates"
assert test ! -e "$support/templates"

echo "PASS test-cyder-template-bootstrap"
