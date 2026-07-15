#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/support" "$TMP/engine/bin"

cat >"$TMP/bin/arch" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -x86_64 ]] && shift
exec "$@"
SH
cat >"$TMP/engine/bin/wine" <<'SH'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == wineboot ]]; then
  case "${WINEBOOT_FAKE_MODE:-success}" in
    success)
      mkdir -p "$WINEPREFIX/drive_c/windows/system32"
      : >"$WINEPREFIX/system.reg"
      : >"$WINEPREFIX/user.reg"
      : >"$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
      ;;
    delayed)
      mkdir -p "$WINEPREFIX/drive_c/windows/system32"
      ;;
    missing)
      mkdir -p "$WINEPREFIX/drive_c"
      ;;
    exit)
      exit 7
      ;;
    signal)
      kill -TERM $$
      ;;
    timeout)
      sleep 5
      ;;
  esac
fi
SH
cat >"$TMP/engine/bin/wineserver" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CYDER_WINESERVER_LOG"
if [[ "${WINEBOOT_FAKE_MODE:-}" == delayed && "${1:-}" == -w ]]; then
  : >"$WINEPREFIX/system.reg"
  : >"$WINEPREFIX/user.reg"
  : >"$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
fi
SH
chmod +x "$TMP/bin/arch" "$TMP/engine/bin/wine" "$TMP/engine/bin/wineserver"
export PATH="$TMP/bin:$PATH"
export CYDER_SUPPORT="$TMP/support"
export CYDER_SHARED_PREFIX="$TMP/prefix"
export CYDER_WINEBOOT_TIMEOUT=1
export CYDER_WINESERVER_LOG="$TMP/wineserver.log"
source "$ROOT/scripts/cyder-common.sh"
cyder_wine_locale_exports() { :; }

mkdir -p "$CYDER_SUPPORT/Logs/operations"
printf 'stale\n' >"$CYDER_SUPPORT/Logs/operations/wineboot-20000101-000000-1.log"
touch -t 200001010000 "$CYDER_SUPPORT/Logs/operations/wineboot-20000101-000000-1.log"

run_case() {
  local mode="$1" expected_status="$2" expected_result="$3" expected_code="$4"
  local prefix="$TMP/prefix-$mode"
  export WINEBOOT_FAKE_MODE="$mode" CYDER_SHARED_PREFIX="$prefix"
  set +e
  cyder_init_bottle "$TMP/engine/bin/wine" "$prefix" >/dev/null 2>"$TMP/$mode.stderr"
  local status=$?
  set -e
  assert_eq "$status" "$expected_status" "$mode exit status"
  local log
  assert test -L "$CYDER_SUPPORT/Logs/last-wineboot.log"
  log="$(readlink "$CYDER_SUPPORT/Logs/last-wineboot.log")"
  log="$CYDER_SUPPORT/Logs/$log"
  assert test -f "$log"
  assert_contains "$(cat "$log")" "result=$expected_result" "$mode result classification"
  assert_contains "$(cat "$log")" "error_code=$expected_code" "$mode stable error code"
  assert_contains "$(cat "$log")" "engine_version=" "$mode engine metadata"
  assert_contains "$(cat "$log")" "os_version=" "$mode OS metadata"
  assert_contains "$(cat "$log")" "cpu_arch=" "$mode CPU metadata"
  if [[ "$expected_status" -ne 0 ]]; then
    assert_contains "$(cat "$log")" "failure_cleanup=wineserver -k" "$mode should clean up wineserver"
    assert_contains "$(cat "$log")" "failure_cleanup=wineserver -w" "$mode should wait for wineserver exit"
  fi
}

run_case success 0 success ""
run_case delayed 0 success ""
assert_contains "$(cat "$TMP/delayed.stderr")" "success_wait=wineserver -w" "delayed registry flush should wait for wineserver"
if [[ -e "$CYDER_SUPPORT/Logs/operations/wineboot-20000101-000000-1.log" ]]; then
  echo "ASSERT failed: wineboot operation logs older than 30 days should rotate" >&2
  exit 1
fi
run_case missing 125 artifact-missing CYD-WINEBOOT-ARTIFACT
run_case exit 7 exit CYD-WINEBOOT-EXIT
run_case signal 143 signal CYD-WINEBOOT-SIGNAL
run_case timeout 124 timeout CYD-WINEBOOT-TIMEOUT

echo "PASS test-cyder-wineboot-logging"
