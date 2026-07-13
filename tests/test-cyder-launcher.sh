#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CYDER_RUNTIME_ROOT="$TMP/runtime"
FAKE="$TMP/game.exe"
touch "$FAKE"
output="$(bash "$ROOT/scripts/cyder_launcher.sh" "$FAKE" --dry-run 2>&1)"
assert_contains "$output" "bottles/shared" "dry-run should use the shared bottle"
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

mkdir -p "$TMP/bin" "$TMP/runtime/Engines/wine-x86_64/bin" "$TMP/support/bottles/shared"
cat >"$TMP/bin/arch" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -x86_64 ]] && shift
exec "$@"
SH
cat >"$TMP/runtime/Engines/wine-x86_64/bin/wineserver" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${WINEPREFIX:-}" "$*" >"$CYDER_TEST_STOP_LOG"
SH
chmod +x "$TMP/bin/arch" "$TMP/runtime/Engines/wine-x86_64/bin/wineserver"
CYDER_TEST_STOP_LOG="$TMP/stop.log" CYDER_SUPPORT="$TMP/support" PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --stop-all >/dev/null 2>&1
stop_output="$(cat "$TMP/stop.log")"
assert_contains "$stop_output" "$TMP/support/bottles/shared|-k" "stop-all should kill the shared-bottle wineserver"

set +e
CYDER_SUPPORT="$TMP/support" bash "$ROOT/scripts/cyder_launcher.sh" --has-running-exes >/dev/null 2>&1
running_status=$?
set -e
assert_eq "$running_status" "1" "inactive shared prefix should report no running EXEs"

# The ShellExecute-compatible path is opt-in for A/B testing.  The default
# remains direct wine because start.exe does not guarantee macOS activation.
mkdir -p "$TMP/fake-bin" "$TMP/run-support"
touch "$TMP/foreground-test.exe"
cat >"$TMP/fake-bin/arch" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-x86_64" ]] && shift
exec "$@"
SH
cat >"$TMP/fake-bin/wine" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CYDER_TEST_ARGS"
if [[ -n "${CYDER_TEST_ENV_LOG:-}" ]]; then
  printf '%s|%s|%s\n' "${WINEMSYNC:-}" "${WINEESYNC:-}" "${WINEDLLOVERRIDES-unset}" >"$CYDER_TEST_ENV_LOG"
fi
SH
chmod +x "$TMP/fake-bin/arch" "$TMP/fake-bin/wine"
run_wine_args() {
  local mode="${1:-}" output="$TMP/run-args"
  CYDER_SUPPORT="$TMP/run-support" \
  CYDER_SCRIPTS="$ROOT/scripts" \
  CYDER_TEST_ARGS="$output" \
  CYDER_WINE_START_MODE="$mode" \
  PATH="$TMP/fake-bin:$PATH" \
    bash -c 'source "$1/scripts/cyder-common.sh"; cyder_init_paths "$1"; cyder_run_wine_exe "$2/wine" "$3"' \
      _ "$ROOT" "$TMP/fake-bin" "$TMP/foreground-test.exe"
  cat "$output"
}
assert_eq "$(run_wine_args direct)" "$TMP/foreground-test.exe" \
  "direct mode should invoke wine with the EXE only"
assert_eq "$(run_wine_args start)" "start /wait /unix $TMP/foreground-test.exe" \
  "start mode should invoke start /wait /unix"

# Sync modes are mutually exclusive, and normal Cyder launches must not add
# global DLL overrides now that those settings live in the prefix registry.
CYDER_SUPPORT="$TMP/run-support" \
CYDER_SCRIPTS="$ROOT/scripts" \
CYDER_TEST_ARGS="$TMP/esync-args" \
CYDER_TEST_ENV_LOG="$TMP/esync-env" \
CYDER_MSYNC=0 CYDER_ESYNC=1 \
PATH="$TMP/fake-bin:$PATH" \
  bash -c 'source "$1/scripts/cyder-common.sh"; cyder_init_paths "$1"; cyder_run_wine_exe "$2/wine" "$3"' \
    _ "$ROOT" "$TMP/fake-bin" "$TMP/foreground-test.exe"
assert_eq "$(cat "$TMP/esync-env")" "|1|unset" \
  "ESync launch should not enable MSync or inject DLL overrides"

CYDER_SUPPORT="$TMP/run-support" \
CYDER_SCRIPTS="$ROOT/scripts" \
CYDER_TEST_ARGS="$TMP/msync-args" \
CYDER_TEST_ENV_LOG="$TMP/msync-env" \
CYDER_MSYNC=1 CYDER_ESYNC=1 \
PATH="$TMP/fake-bin:$PATH" \
  bash -c 'source "$1/scripts/cyder-common.sh"; cyder_init_paths "$1"; cyder_run_wine_exe "$2/wine" "$3"' \
    _ "$ROOT" "$TMP/fake-bin" "$TMP/foreground-test.exe"
assert_eq "$(cat "$TMP/msync-env")" "1||unset" \
  "MSync should take precedence if both values are supplied externally"

# Native Cyder uses detached mode: the shell worker records the actual Wine
# PID and returns while the Wine process continues independently.
cat >"$TMP/fake-bin/wine-detached" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CYDER_TEST_ARGS"
exec sleep 10
SH
chmod +x "$TMP/fake-bin/wine-detached"
detach_pid_file="$TMP/detached.pid"
CYDER_SUPPORT="$TMP/run-support" \
CYDER_SCRIPTS="$ROOT/scripts" \
CYDER_TEST_ARGS="$TMP/detached-args" \
CYDER_WINE_DETACH=1 \
CYDER_WINE_PID_FILE="$detach_pid_file" \
PATH="$TMP/fake-bin:$PATH" \
  bash -c 'source "$1/scripts/cyder-common.sh"; cyder_init_paths "$1"; cyder_run_wine_exe "$2/wine-detached" "$3"' \
    _ "$ROOT" "$TMP/fake-bin" "$TMP/foreground-test.exe"
assert test -f "$detach_pid_file"
detached_pid="$(cat "$detach_pid_file")"
if ! kill -0 "$detached_pid" 2>/dev/null; then
  echo "ASSERT failed: detached Wine process should survive the shell worker" >&2
  exit 1
fi
kill "$detached_pid" 2>/dev/null || true
wait "$detached_pid" 2>/dev/null || true

echo "PASS test-cyder-launcher"
