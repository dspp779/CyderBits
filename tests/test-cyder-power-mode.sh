#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/support"

cat >"$TMP/bin/taskpolicy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CYDER_TEST_TASKPOLICY_LOG"
[[ "${1:-}" == -c && "${2:-}" == background ]] || exit 64
shift 2
exec "$@"
SH
cat >"$TMP/bin/wine" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CYDER_TEST_WINE_LOG"
SH
chmod +x "$TMP/bin/taskpolicy" "$TMP/bin/wine"

export PATH="$TMP/bin:$PATH"
export CYDER_TEST_TASKPOLICY_LOG="$TMP/taskpolicy.log"
export CYDER_TEST_WINE_LOG="$TMP/wine.log"
: >"$CYDER_TEST_TASKPOLICY_LOG"
: >"$CYDER_TEST_WINE_LOG"

source "$ROOT/scripts/cyder-common.sh"
CYDER_POWER_MODE=background cyder_exec_wine "$TMP/bin/wine" game.exe
assert_contains "$(cat "$CYDER_TEST_TASKPOLICY_LOG")" \
  "-c background /usr/bin/arch -x86_64 $TMP/bin/wine game.exe" \
  "energy-saving mode should use taskpolicy -c background"
assert_eq "$(cat "$CYDER_TEST_WINE_LOG")" "game.exe" \
  "taskpolicy should execute the requested Wine command"

: >"$CYDER_TEST_TASKPOLICY_LOG"
: >"$CYDER_TEST_WINE_LOG"
CYDER_POWER_MODE=normal cyder_exec_wine "$TMP/bin/wine" game.exe
assert_eq "$(cat "$CYDER_TEST_TASKPOLICY_LOG")" "" \
  "standard mode must not invoke taskpolicy"
assert_eq "$(cat "$CYDER_TEST_WINE_LOG")" "game.exe" \
  "standard mode should execute Wine directly"

echo "PASS test-cyder-power-mode"
