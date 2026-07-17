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

set +e
diagnostic_out="$(CYDER_DIAGNOSTIC_SESSION_ID=test-session \
  bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe /nonexistent/missing.exe 2>&1)"
diagnostic_status=$?
set -e
assert_eq "$diagnostic_status" 1 "diagnostic launch should preserve the original exit status"
assert_contains "$diagnostic_out" "stage=exe-validation" "diagnostic output should identify the failing stage"
assert_contains "$diagnostic_out" "event=exit" "explicit nonzero exits should be recorded"

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
printf '%s|%s\n' "${WINEPREFIX:-}" "$*" >>"$CYDER_TEST_STOP_LOG"
if [[ "${CYDER_TEST_STOP_FAIL:-0}" == 1 ]]; then
  exit 1
fi
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

# Routine health checks must trust the bundled/installed version files and
# must not stream-decompress the engine archive merely to rediscover a version.
cat >"$TMP/runtime/Engines/wine-x86_64/bin/wine" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/runtime/Engines/wine-x86_64/bin/wine"
mkdir -p "$TMP/support/bottles/shared/drive_c/windows/system32"
: >"$TMP/support/bottles/shared/.cyder-bootstrap-v1"
: >"$TMP/support/bottles/shared/system.reg"
: >"$TMP/support/bottles/shared/user.reg"
: >"$TMP/support/bottles/shared/drive_c/windows/system32/kernel32.dll"
printf 'this is intentionally not an engine archive\n' >"$TMP/must-not-read.tar.xz"
CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" \
CYDER_TEST_STOP_LOG="$TMP/health-stop.log" PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --engine-src "$TMP/must-not-read.tar.xz" --health-check >/dev/null 2>&1

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
assert test -L "$TMP/run-support/Logs/last-launch.log"
launch_log_count="$(find "$TMP/run-support/Logs" -maxdepth 1 -type f -name 'launch-*.log' | wc -l | tr -d ' ')"
if [[ "$launch_log_count" -lt 2 ]]; then
  echo "ASSERT failed: timestamped Wine logs should not overwrite the previous launch" >&2
  exit 1
fi

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

# Per-game profile routing uses the complete EXE path and requires a ready
# versioned template manifest.
profile_support="$TMP/profile-support"
mkdir -p "$profile_support/templates/pristine"
mkdir -p "$TMP/runtime/Engines/wine-x86_64/bin"
cp "$TMP/fake-bin/wine" "$TMP/runtime/Engines/wine-x86_64/bin/wine"
chmod +x "$TMP/runtime/Engines/wine-x86_64/bin/wine"
cat >"$profile_support/templates/pristine/manifest.json" <<'JSON'
{"schemaVersion":2,"templateId":"pristine","revision":2,"recipeId":null,"engineVersion":"test-engine"}
JSON
profile_exe="$TMP/profile game.exe"
touch "$profile_exe"
profile_bottle="$(CYDER_SUPPORT="$profile_support" CYDER_ENGINE_VERSION_LABEL=test-engine \
  bash "$ROOT/scripts/cyder_launcher.sh" --profile-create "$profile_exe" pristine)"
assert test -d "$profile_bottle"
resolved_bottle="$(CYDER_SUPPORT="$profile_support" CYDER_ENGINE_VERSION_LABEL=test-engine \
  bash "$ROOT/scripts/cyder_launcher.sh" --profile-resolve "$profile_exe")"
assert_eq "$resolved_bottle" "$profile_bottle" "profile resolve should return created bottle"
metadata_path="$(find "$profile_support/profiles" -name profile.json -print -quit)"
profile_exe_canonical="$(cd "$(dirname "$profile_exe")" && printf '%s/%s' "$(pwd -P)" "$(basename "$profile_exe")")"
assert_eq "$(/usr/bin/plutil -extract sourcePath raw -o - "$metadata_path")" "$profile_exe_canonical" \
  "profile metadata should use full EXE path"
if CYDER_SUPPORT="$profile_support" bash "$ROOT/scripts/cyder_launcher.sh" \
  --profile-resolve "$profile_exe" --dry-run >/dev/null 2>&1; then
  echo "profile and dry-run actions unexpectedly combined" >&2
  exit 1
fi

if CYDER_SUPPORT="$profile_support" CYDER_ENGINE_VERSION_LABEL=other-engine \
  bash "$ROOT/scripts/cyder_launcher.sh" --profile-create "$profile_exe" pristine >/dev/null 2>&1; then
  echo "engine version mismatch unexpectedly accepted" >&2
  exit 1
fi
mkdir -p "$profile_support/templates/golden"
cp "$profile_support/templates/pristine/manifest.json" "$profile_support/templates/golden/manifest.json"
sed -i '' 's/"pristine"/"golden"/' "$profile_support/templates/golden/manifest.json" 2>/dev/null || \
  sed -i 's/"pristine"/"golden"/' "$profile_support/templates/golden/manifest.json"
CYDER_SUPPORT="$profile_support" CYDER_ENGINE_VERSION_LABEL=test-engine PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --templates-ready
set +e
CYDER_SUPPORT="$profile_support" CYDER_ENGINE_VERSION_LABEL=other-engine PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --templates-ready >/dev/null 2>&1
templates_mismatch_status=$?
set -e
assert_eq "$templates_mismatch_status" "1" "template engine mismatch should be a negative readiness result"

# Native bridge session API validates bottle scope and supports reservation
# lifecycle through the same session registry used by Wine launches.
session_prefix="$profile_support/bottles/session"
mkdir -p "$session_prefix"
session_result="$TMP/session-result.plist"
session_file="$(CYDER_SUPPORT="$profile_support" CYDER_RESULT_FILE="$session_result" \
  bash "$ROOT/scripts/cyder_launcher.sh" --session-acquire "$session_prefix" "$$" 1 0 normal)"
assert test -f "$session_file"
assert_eq "$(/usr/bin/plutil -extract sessionFile raw -o - "$session_result")" "$session_file" \
  "session acquire should publish an absolute machine-readable result"
updated="$(CYDER_SUPPORT="$profile_support" \
  bash "$ROOT/scripts/cyder_launcher.sh" --session-update "$session_prefix" "$session_file" "$$" 2>&1)"
assert_eq "$updated" "" "session update should not emit output"
CYDER_SUPPORT="$profile_support" \
  bash "$ROOT/scripts/cyder_launcher.sh" --session-release "$session_prefix" "$session_file"
assert test ! -e "$session_file"
if CYDER_SUPPORT="$profile_support" \
  bash "$ROOT/scripts/cyder_launcher.sh" --session-acquire "$profile_support" "$$" 0 0 normal >/dev/null 2>&1; then
  echo "out-of-scope session prefix unexpectedly accepted" >&2
  exit 1
fi
if CYDER_SUPPORT="$profile_support" \
  bash "$ROOT/scripts/cyder_launcher.sh" --session-acquire "$session_prefix" "$$" 1 1 normal >/dev/null 2>&1; then
  echo "dual sync session unexpectedly accepted" >&2
  exit 1
fi

mkdir -p "$profile_support/bottles/settings-target" "$profile_support/bottles/settings-other/.cyder-runtime/sessions"
printf 'pid=%s\nsync=msync=0;esync=0;power=normal\nmode=normal\n' "$$" >"$profile_support/bottles/settings-other/.cyder-runtime/sessions/live.session"
CYDER_SUPPORT="$profile_support" CYDER_SCRIPTS="$TMP/empty-scripts" \
  CYDER_TEST_STOP_LOG="$TMP/active-settings-stop.log" PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --apply-settings-prefix "$profile_support/bottles/settings-other"
settings_stop_log="$TMP/settings-stop.log"
: >"$settings_stop_log"
settings_target_real="$(cd "$profile_support/bottles/settings-target" && pwd -P)"
CYDER_SUPPORT="$profile_support" CYDER_SCRIPTS="$TMP/empty-scripts" CYDER_TEST_STOP_LOG="$settings_stop_log" PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --apply-settings-prefix "$profile_support/bottles/settings-target"
assert_contains "$(cat "$settings_stop_log")" "$settings_target_real|-k" "settings cleanup should stop target wineserver"
assert_contains "$(cat "$settings_stop_log")" "$settings_target_real|-w" "settings cleanup should wait for target wineserver"
CYDER_SUPPORT="$profile_support" CYDER_SCRIPTS="$TMP/empty-scripts" CYDER_TEST_STOP_LOG="$settings_stop_log" \
  CYDER_TEST_STOP_FAIL=1 PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/cyder_launcher.sh" --apply-settings-prefix "$profile_support/bottles/settings-target"
if CYDER_SUPPORT="$profile_support" CYDER_SCRIPTS="$TMP/empty-scripts" \
  bash "$ROOT/scripts/cyder_launcher.sh" --apply-settings-prefix "" >/dev/null 2>&1; then
  echo "empty settings prefix unexpectedly accepted" >&2
  exit 1
fi

# The optional prefix argument routes WINEPREFIX and session guard away from
# the shared bottle while preserving the existing default call shape.
custom_prefix="$TMP/custom-bottle"
CYDER_SUPPORT="$TMP/run-support" \
CYDER_SCRIPTS="$ROOT/scripts" \
CYDER_TEST_ARGS="$TMP/profile-prefix-args" \
CYDER_MSYNC=1 \
PATH="$TMP/fake-bin:$PATH" \
  bash -c 'source "$1/scripts/cyder-common.sh"; cyder_init_paths "$1"; cyder_run_wine_exe "$2/wine" "$3" "$4"' \
    _ "$ROOT" "$TMP/fake-bin" "$TMP/foreground-test.exe" "$custom_prefix"
assert_contains "$(cat "$TMP/run-support/Logs/last-launch.log")" "$custom_prefix" "custom profile launch should log its prefix"
assert test ! -e "$custom_prefix/.cyder-runtime/sessions"/*

echo "PASS test-cyder-launcher"
