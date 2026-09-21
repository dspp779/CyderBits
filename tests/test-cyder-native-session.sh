#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-native-session.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_environment_command_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_environment_probe.swift" "$ROOT/scripts/cyder_environment_command.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/helper"
"$TEST_DIR/helper"
source "$ROOT/scripts/cyder-common.sh"
prefix="$TEST_DIR/prefix"
mkdir -p "$prefix"
export CYDER_ENVIRONMENT_MONITOR=1 CYDER_EXECUTION_OWNER_TICKET=fixture
export CYDER_ENVIRONMENT_HELPER="$TEST_DIR/helper" CYDER_ENVIRONMENT_SERVER=/usr/bin/true
cyder_session_acquire "$prefix" 1 0 normal /usr/bin/true
session="$CYDER_SESSION_FILE"
grep -q '^observer=native$' "$session"
cyder_session_mark_background "$session"
cyder_session_park_native "$session"
grep -q '^pid=0$' "$session"
# Actual read-only empty namespace, executable engine stand-in; no Wine launch.
cyder_session_acquire "$prefix" 0 1 normal /usr/bin/true
[[ ! -e "$session" ]]
cyder_session_release "$prefix" "$CYDER_SESSION_FILE"
printf '%s\n' 'PASS native session parks without a reusable PID; actual empty namespace releases obsolete sync guard'
cat > "$TEST_DIR/probe" <<'SH'
#!/bin/bash
[[ -z "${TEST_PROBE_LOG:-}" ]] || printf 'probe\n' >> "$TEST_PROBE_LOG"
printf '%s\n' "${TEST_PROBE_REPLY:-cyder-environment-v1 alive}"
exit "${TEST_PROBE_STATUS:-0}"
SH
chmod +x "$TEST_DIR/probe"
export CYDER_ENVIRONMENT_HELPER="$TEST_DIR/probe"
cyder_session_acquire "$prefix" 1 0 normal
session="$CYDER_SESSION_FILE"
cyder_session_mark_background "$session"
cyder_session_park_native "$session"
for mode in alive unknown malformed mismatch; do
  case "$mode" in
    alive) export TEST_PROBE_REPLY='cyder-environment-v1 alive' TEST_PROBE_STATUS=0 ;;
    unknown) export TEST_PROBE_REPLY='' TEST_PROBE_STATUS=75 ;;
    malformed) export TEST_PROBE_REPLY=empty TEST_PROBE_STATUS=10 ;;
    mismatch) export TEST_PROBE_REPLY='cyder-environment-v1 empty' TEST_PROBE_STATUS=0 ;;
  esac
  status=0
  cyder_session_acquire "$prefix" 0 1 normal >/dev/null 2>&1 || status=$?
  [[ "$status" == 75 && -f "$session" ]]
done
# A failure to park cannot bypass calibration through the older running state.
sed 's/^state=.*/state=running/' "$session" > "$session.new"
mv "$session.new" "$session"
status=0
cyder_session_acquire "$prefix" 0 1 normal >/dev/null 2>&1 || status=$?
[[ "$status" == 75 && -f "$session" ]]
export TEST_PROBE_REPLY='cyder-environment-v1 empty' TEST_PROBE_STATUS=10
cyder_session_acquire "$prefix" 0 1 normal
[[ ! -e "$session" ]]
cyder_session_release "$prefix" "$CYDER_SESSION_FILE"
printf '%s\n' 'PASS alive/unknown/invalid proof retains native session, including failed park; only exact empty protocol permits a different sync setting'

# Many parked launches still require only one environment observation under
# the session lock; another prefix is never pruned by this acquisition.
other="$TEST_DIR/other"
mkdir -p "$(cyder_session_dir "$other")"
for n in {1..12}; do
  printf 'schema=2\npid=0\nsync=msync=1;esync=0;power=normal\nmode=normal\nstate=background\nobserver=native\n' > "$(cyder_session_dir "$prefix")/$n.session"
done
cp "$(cyder_session_dir "$prefix")/1.session" "$(cyder_session_dir "$other")/retained.session"
export TEST_PROBE_LOG="$TEST_DIR/probe.calls"
: > "$TEST_PROBE_LOG"
cyder_session_acquire "$prefix" 0 1 normal
[[ "$(wc -l < "$TEST_PROBE_LOG" | tr -d ' ')" == 1 ]]
cyder_session_release "$prefix" "$CYDER_SESSION_FILE"
[[ -f "$(cyder_session_dir "$other")/retained.session" ]]
[[ "$(find "$(cyder_session_dir "$prefix")" -name '*.session' | wc -l | tr -d ' ')" == 0 ]]
printf '%s\n' 'PASS twelve parked sessions share one calibration; cleanup is confined to the requested prefix'
# A late supervisor must wait for a current acquisition and must not recreate
# the old session after that acquisition retired it under the same lock.
late="$(cyder_session_dir "$prefix")/late.session"
printf 'schema=2\npid=0\nsync=msync=1;esync=0;power=normal\nmode=normal\nstate=running\nobserver=native\n' > "$late"
cyder_session_lock "$(cyder_session_dir "$prefix")"
(
  touch "$TEST_DIR/park.entered"
  cyder_session_park_native "$late"
  touch "$TEST_DIR/park.finished"
) &
park_pid=$!
for _ in {1..50}; do [[ -e "$TEST_DIR/park.entered" ]] && break; sleep 0.02; done
[[ -e "$TEST_DIR/park.entered" ]]
sleep 0.15
[[ ! -e "$TEST_DIR/park.finished" ]]
rm -f "$late"
printf 'new generation reservation\n' > "$(cyder_session_dir "$prefix")/new.session"
rm -rf "$(cyder_session_dir "$prefix")/.lock"
wait "$park_pid"
[[ ! -e "$late" && -e "$TEST_DIR/park.finished" ]]
[[ "$(cat "$(cyder_session_dir "$prefix")/new.session")" == 'new generation reservation' ]]
printf '%s\n' 'PASS park shares admission lock; a late supervisor cannot recreate a retired guard or overwrite a new reservation'
