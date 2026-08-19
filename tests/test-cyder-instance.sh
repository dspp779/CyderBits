#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

instance="$(cat "$ROOT/scripts/cyder_instance.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
build="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$build" 'cyder_instance.swift' \
  "native Cyder build must include the cross-process coordinator"
assert_contains "$instance" 'menu-bar item' \
  "instance coordinator source should document menu-bar ownership"
assert_contains "$instance" 'CyderSentinelServer' \
  "instances must use the sentinel socket as the owner lock"
assert_contains "$instance" 'DistributedNotificationCenter' \
  "secondary instances must forward requests to the primary"
assert_contains "$instance" 'requestPollTimer' \
  "the primary must recover requests when distributed notifications are delayed"
assert_contains "$instance" 'hasArguments' \
  "forwarded requests must preserve the distinction between nil and empty argv"
assert_contains "$instance" '"urls"' \
  "forwarded requests must include url payloads"
assert_contains "$instance" 'createdAt' \
  "stale forwarded requests must not launch unexpectedly after a crash"
assert_not_contains "$instance" '.native-instance-' \
  "the mkdir pid lock must not remain the owner lock"
assert_contains "$app" 'isPrimaryInstance' \
  "the native app must distinguish primary and secondary processes"
assert_contains "$app" 'scheduleSecondaryForward' \
  "secondary launches must wait for openFiles before forwarding"
assert_contains "$app" 'receiveInstanceRequest' \
  "the primary must consume forwarded launch requests"
assert_contains "$app" 'queuedLaunches' \
  "queued launches must remain in the primary process"
assert_contains "$app" 'launchArguments: launch.arguments' \
  "forwarded dynamic arguments must survive queueing"
assert_contains "$app" 'instanceCoordinator.stop()' \
  "the primary must release its owner lock on termination"
assert_contains "$app" 'applicationShouldHandleReopen' \
  "clicking Cyder.app while the LSUIElement process is already resident must reopen UI"
assert_contains "$app" 'presentResidentCyderUI' \
  "Finder reopen and secondary showUI must share one UI presentation path"
assert_contains "$app" 'func applicationShouldHandleReopen' \
  "reopen must be an NSApplicationDelegate method, not a comment"

echo "PASS test-cyder-instance"
