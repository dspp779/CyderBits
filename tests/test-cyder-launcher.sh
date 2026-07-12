#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/game.exe"
touch "$FAKE"
output="$(bash "$ROOT/scripts/cyder_launcher.sh" "$FAKE" --dry-run 2>&1)"
assert_contains "$output" "SharedPrefix" "dry-run should use SharedPrefix"
assert_contains "$output" "game.exe" "dry-run should show exe path"
set +e
launch_out="$(bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe /nonexistent/missing.exe 2>&1)"
launch_status=$?
set -e
assert_eq "$launch_status" 1 "launch-exe with missing file should fail"
assert_contains "$launch_out" "Missing or invalid .exe" "launch-exe should reach launch handler"

touch "$TMP/not-ready.exe"
set +e
not_ready_out="$(CYDER_SUPPORT="$TMP/not-ready-support" bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe "$TMP/not-ready.exe" 2>&1)"
not_ready_status=$?
set -e
assert_eq "$not_ready_status" "2" "launch-exe must not create a missing environment"
assert_contains "$not_ready_out" "open Cyder.app" "launch-exe should direct the user to manual setup"

mkdir -p "$TMP/bin" "$TMP/support/Engines/wine-x86_64/bin" "$TMP/support/SharedPrefix"
cat >"$TMP/bin/arch" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -x86_64 ]] && shift
exec "$@"
SH
cat >"$TMP/support/Engines/wine-x86_64/bin/wineserver" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${WINEPREFIX:-}" "$*" >"$CYDER_TEST_STOP_LOG"
SH
chmod +x "$TMP/bin/arch" "$TMP/support/Engines/wine-x86_64/bin/wineserver"
CYDER_TEST_STOP_LOG="$TMP/stop.log" CYDER_SUPPORT="$TMP/support" PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --stop-all >/dev/null 2>&1
stop_output="$(cat "$TMP/stop.log")"
assert_contains "$stop_output" "$TMP/support/SharedPrefix|-k" "stop-all should kill the shared-prefix wineserver"

set +e
CYDER_SUPPORT="$TMP/support" bash "$ROOT/scripts/cyder_launcher.sh" --has-running-exes >/dev/null 2>&1
running_status=$?
set -e
assert_eq "$running_status" "1" "inactive shared prefix should report no running EXEs"

echo "PASS test-cyder-launcher"
