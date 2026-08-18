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
  "the menu bar must track launches from sentinel callbacks, not lifecycle files"
assert_not_contains "$status" 'lifecycleState(at:' \
  "menu-bar liveness must not poll lifecycle sidecar files"
assert_contains "$app" 'sentinel.onLaunch' \
  "the app delegate must install sentinel launch callbacks"

echo "PASS test-cyder-sentinel"
