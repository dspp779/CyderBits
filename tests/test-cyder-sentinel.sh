#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

sentinel="$(cat "$ROOT/scripts/cyder_sentinel.swift")"
instance="$(cat "$ROOT/scripts/cyder_instance.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
status="$(cat "$ROOT/scripts/cyder_status_item.swift")"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
build="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$build" 'cyder_sentinel.swift' \
  "native Cyder build must include the launch sentinel"
assert_contains "$app" '--sentinel-connect' \
  "CyderSwift must expose a sentinel-connect helper before NSApplication starts"
assert_contains "$sentinel" 'AF_UNIX' \
  "the sentinel must listen on a Unix domain socket"
assert_contains "$sentinel" 'bind(' \
  "primary election must use socket bind"
assert_contains "$sentinel" 'connect(' \
  "helpers and secondaries must connect to the existing sentinel"
assert_contains "$sentinel" 'unlink' \
  "a stale sentinel socket must be removable before retrying bind"
assert_contains "$instance" 'CyderSentinelServer' \
  "instance coordination must use the sentinel socket as the primary lock"
assert_not_contains "$instance" '.native-instance-' \
  "the mkdir pid lock must not remain the primary instance lock"
assert_contains "$common" 'cyder_sentinel_attach' \
  "the Wine supervisor must attach a per-launch sentinel helper"
assert_contains "$common" 'mkfifo' \
  "the supervisor must create a wait fifo for the sentinel helper"
assert_contains "$common" 'cyder_spawn_cyder_swift' \
  "the sentinel helper must spawn CyderSwift with the host-native architecture"
assert_contains "$common" 'exec 3<>' \
  "the wait fifo write end must open read-write so attach cannot deadlock on helper dyld"
assert_contains "$common" '--pid-file "$CYDER_SENTINEL_WATCH_FILE" 3>&-' \
  "the helper argv must close fd 3 so it cannot inherit the fifo write end"
assert_contains "$common" 'cyder_exec_game_with_launch_log "$log_file" &' \
  "the detached supervisor must log through the launch-log helper"
assert_contains "$common" 'cyder_exec_game >"$fifo" 2>&1 3>&-' \
  "Wine must not inherit the fifo write end"
assert_contains "$sentinel" 'closeInheritedHelperFileDescriptors' \
  "the sentinel helper must drop inherited fds so it cannot hold its own fifo write end"
assert_contains "$status" '背景執行' \
  "windowless background processes must not be described as cleanup"
assert_contains "$status" '暫時無法確認執行狀態' \
  "unconfirmed environment presence must remain visible"
assert_contains "$status" 'func beginLaunch(' \
  "the menu bar must track launches as LaunchGroups with a stable id"
assert_not_contains "$app" 'sentinel.onLaunch = { [weak self] launch in
                self?.statusItemController.beginLaunch(' \
  "helper hello must not create a second LaunchGroup"
assert_not_contains "$status" 'lifecycleState(at:' \
  "menu-bar liveness must not poll lifecycle sidecar files"
assert_contains "$app" 'instanceCoordinator.sentinel.onLaunchEnded' \
  "the app delegate must install the helper disconnect callback"
assert_not_contains "$app" 'sentinel.onLaunch =' \
  "helper hello must not be wired; LaunchGroup is created at relay start"
assert_not_contains "$sentinel" 'usleep(400_000)' \
  "the sentinel helper must not poll Wine windows on an interval"
assert_not_contains "$sentinel" 'func currentHolders' \
  "the sentinel helper must not scan every onscreen window for WINEPREFIX"
assert_contains "$sentinel" 'makeReadSource' \
  "fifo EOF must wake the helper through kqueue rather than a sleep loop"
assert_contains "$status" 'makeProcessSource' \
  "the menu bar must watch Wine PIDs with process-exit/fork events"
assert_contains "$status" 'forMode: .default' \
  "menu-bar timers must not run during menu tracking"
assert_not_contains "$status" 'forMode: .common' \
  "menu tracking must not fire Wine window polls"
assert_contains "$status" 'menuWillOpen' \
  "opening the status menu must pause animation"
assert_contains "$status" 'noteHelperDisconnected' \
  "a crashed sentinel helper must not drop a still-running Wine launch"
assert_not_contains "$status" 'if isMonitoring(prefix: prefix.path) { return }' \
  "a published Wine PID must attach to the existing sentinel launch instead of being ignored"
assert_contains "$app" 'controller.onLifecycleIdle' \
  "closing Cyder UI must use the shared lifecycle policy"

assert_contains "$app" 'statusItemController.beginLaunch(' \
  "Swift must create the LaunchGroup when the Wine relay starts, not wait for helper hello"
assert_contains "$app" 'statusItemController.attachNativeRoot(proof)' \
  "native proof must attach to its own launch, never a prefix-only group"
assert_not_contains "$app" 'sentinel.onLaunchEnded = { [weak self] id in
                self?.statusItemController.endLaunch(id: id)' \
  "helper disconnect must not endLaunch"
assert_not_contains "$app" 'self?.statusItemController.endLaunch(id: id)' \
  "onLaunchEnded must not call endLaunch"
assert_contains "$status" 'func attachNativeRoot(_ receipt: CyderLaunchObserver.NativeRoot)' \
  "root attach verifies launch authority and process birth"
assert_not_contains "$status" 'exactlyOneStartingGroup' \
  "one starting group is not evidence that another prefix process belongs to it"
assert_not_contains "$status" 'for (key, var session) in sessions where session.prefix.path == target' \
  "adoptWindowedProcess must not dump a PID into every LaunchGroup that shares the bottle"
# Old assertions demanded synchronous timeout scans and prefix-only ownership.
# These are explicitly superseded by spec §20–23 and the runtime harness.
assert_contains "$app" 'finishLaunchObservation(id: launchID' \
  "the Wine relay must finish observation through the asynchronous controller adapter"
assert_not_contains "$app" 'observationFinished.wait()' \
  "observation finalization must not wait indefinitely for an OS query"
assert_not_contains "$status" 'wineOnscreenWindows(matchingPrefix:' \
  "prefix membership must not be mistaken for launch ownership"
assert_contains "$status" 'wineOnscreenWindows(ownedBy: Set(expanded.map(\.pid)))' \
  "launch window claims require a proven process tree"
assert_not_contains "$app" 'cancelMonitoring(pid: winePID' \
  "failed launches must not cancel unrelated monitoring by numeric PID"
assert_contains "$status" 'func markActivated(id: String)' \
  "activation after root exit must still be keyed by launch ID"
assert_contains "$app" 'markActivated(id: launchID)' \
  "the relay must apply activation to its own launch"
echo "PASS test-cyder-sentinel"
