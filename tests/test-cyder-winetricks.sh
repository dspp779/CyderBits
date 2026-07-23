#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCRIPTS="$TMP/scripts"
ENGINES="$TMP/engines"
PREFIX="$TMP/prefix"
mkdir -p "$SCRIPTS" "$ENGINES/wine-x86_64/bin" "$PREFIX" "$TMP/support"
cp "$ROOT/scripts/cyder-common.sh" "$SCRIPTS/"
cp "$ROOT/scripts/cyder-ensure-rosetta.sh" "$SCRIPTS/"
cp "$ROOT/scripts/resolve-wine-locale.sh" "$SCRIPTS/"
cp "$ROOT/scripts/cyder-winetricks.sh" "$SCRIPTS/"
cp /usr/bin/true "$ENGINES/wine-x86_64/bin/wine"
cp /usr/bin/true "$ENGINES/wine-x86_64/bin/wineserver"
touch "$PREFIX/system.reg"

cat >"$SCRIPTS/winetricks" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$WINETRICKS_LOG"
printf 'prefix=%s\n' "$WINEPREFIX" >>"$WINETRICKS_LOG"
printf 'wine=%s\n' "$WINE" >>"$WINETRICKS_LOG"
printf 'wineserver=%s\n' "$WINESERVER" >>"$WINETRICKS_LOG"
printf 'cache=%s\n' "$W_CACHE" >>"$WINETRICKS_LOG"
SCRIPT
chmod +x "$SCRIPTS"/*.sh "$SCRIPTS/winetricks"

export CYDER_SCRIPTS="$SCRIPTS"
export CYDER_ENGINES="$ENGINES"
export CYDER_SHARED_PREFIX="$PREFIX"
export CYDER_SUPPORT="$TMP/support"
export WINETRICKS_LOG="$TMP/winetricks.log"
export CYDER_WINE_LOCALE_FALLBACK="en_US.UTF-8"

bash "$SCRIPTS/cyder-winetricks.sh" install vcrun2005 quartz
assert_contains "$(cat "$WINETRICKS_LOG")" "--unattended vcrun2005 quartz" \
  "Winetricks should receive selected verbs in unattended mode"
assert_contains "$(cat "$WINETRICKS_LOG")" "prefix=$PREFIX" \
  "Winetricks should target the shared prefix"
assert_contains "$(cat "$WINETRICKS_LOG")" "wine=$ENGINES/wine-x86_64/bin/wine" \
  "Winetricks should receive the Cyder Wine engine"

if bash "$SCRIPTS/cyder-winetricks.sh" install unsupported-verb >/dev/null 2>&1; then
  echo "ASSERT failed: unsupported Winetricks verbs should be rejected" >&2
  exit 1
fi

echo "PASS test-cyder-winetricks"
