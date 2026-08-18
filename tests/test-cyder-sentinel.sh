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
  "the supervisor must create an inheritable wait fifo for the Wine tree"
assert_contains "$common" '--sentinel-connect' \
  "the supervisor must launch CyderSwift --sentinel-connect"
assert_contains "$common" 'exec 3<>' \
  "the wait fifo write end must open read-write so attach cannot deadlock on helper dyld"
assert_contains "$status" '已結束，等待背景程序退出' \
  "menu items must describe leftover processes after the window closes"
assert_contains "$status" '等待 ' \
  "named leftover processes must appear in the waiting label"
assert_contains "$status" 'func beginLaunch(' \
  "the menu bar must track launches as LaunchGroups with a stable id"
assert_not_contains "$app" 'sentinel.onLaunch = { [weak self] launch in
                self?.statusItemController.beginLaunch(' \
  "helper hello must not create a second LaunchGroup"
assert_not_contains "$status" 'lifecycleState(at:' \
  "menu-bar liveness must not poll lifecycle sidecar files"
assert_contains "$app" 'sentinel.onLaunch' \
  "the app delegate must install sentinel launch callbacks"
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
assert_contains "$app" 'hasActiveSessions || self.libraryLaunchInProgress' \
  "closing the game library must keep the menu bar while a launch or Wine session is active"

assert_contains "$app" 'statusItemController.beginLaunch(' \
  "Swift must create the LaunchGroup when the Wine relay starts, not wait for helper hello"
assert_contains "$app" 'attachRootPID(id: launchID' \
  "the pid file must attach to this launch id, not to whichever group shares the prefix"
assert_not_contains "$app" 'sentinel.onLaunchEnded = { [weak self] id in
                self?.statusItemController.endLaunch(id: id)' \
  "helper disconnect must not endLaunch"
assert_not_contains "$app" 'self?.statusItemController.endLaunch(id: id)' \
  "onLaunchEnded must not call endLaunch"
assert_contains "$status" 'func attachRootPID(id: String, pid: Int32)' \
  "root PID attach is keyed by launch id"
assert_contains "$status" 'exactlyOneStartingGroup' \
  "window adoption must prefer the single starting group, not every group with the same prefix"
assert_not_contains "$status" 'for (key, var session) in sessions where session.prefix.path == target' \
  "adoptWindowedProcess must not dump a PID into every LaunchGroup that shares the bottle"
assert_contains "$app" 'endLaunch(id: launchID)' \
  "a failed Wine relay must tear down the LaunchGroup created for that launch id"
assert_contains "$app" 'keepLaunchGroupIfLiveOrClaimed(' \
  "timeout and early-return defer must share one LaunchGroup lifetime helper"
keep_helper_refs="$(printf '%s\n' "$app" | grep -c 'keepLaunchGroupIfLiveOrClaimed(' || true)"
assert_eq "$keep_helper_refs" "3" \
  "helper definition plus timeout and defer call sites must all use keepLaunchGroupIfLiveOrClaimed"
assert_not_contains "$app" 'cancelMonitoring(pid: winePID' \
  "failed launches must not cancel monitoring by pid after the group is keyed by launch id"
assert_contains "$status" 'if !session.activated {
            session.hasForeground = false
            session.leftoverNames = []
            sessions[id] = session
            refresh()
            return
        }
        endLaunch(id: id)' \
  "finishSessionIfIdle must not endLaunch while the LaunchGroup is still starting"
assert_contains "$status" 'func markActivated(id: String)' \
  "LaunchGroup activation after root PID exit must be keyed by launch id"
assert_contains "$app" 'markActivated(id: launchID)' \
  "the Wine relay must activate the LaunchGroup by launch id, not only by a possibly-exited root pid"
assert_contains "$app" 'hasLiveWatchedPIDs(id: launchID)' \
  "timeout and defer must not keep the LaunchGroup unless watched PIDs are still live"
assert_contains "$app" 'hasClaimedWindow(id: launchID)' \
  "timeout and defer must keep the group only if a window was claimed or a process still lives"
assert_contains "$app" 'keepLaunchGroupIfLiveOrClaimed(
                id: launchID,
                launchActivated: &launchActivated,
                activatedURL: activatedURL
            )
            if !launchActivated {' \
  "early-return defer must run the same keepGroup helper before endLaunch"

echo "PASS test-cyder-sentinel"
