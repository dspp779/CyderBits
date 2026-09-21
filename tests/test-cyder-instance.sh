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
assert_contains "$instance" 'CyderRequestChannel' \
  "secondary delivery must use the bounded request channel"
assert_contains "$instance" 'journal.authorizeDispatch' \
  "dispatch must cross the persistent journal before execution"
assert_not_contains "$instance" 'requestPollTimer' \
  "legacy polling must not run alongside the journal consumer"
assert_not_contains "$instance" '.native-instance-' \
  "the mkdir pid lock must not remain the owner lock"
assert_contains "$app" 'isPrimaryInstance' \
  "the native app must distinguish primary and secondary processes"
assert_contains "$app" 'scheduleSecondaryForward' \
  "secondary launches must wait for openFiles before forwarding"
assert_contains "$app" 'determineInitialLaunchIntent()' \
  "secondary launches must classify their Apple Event / argv intent before forwarding"
assert_contains "$app" 'let showUI = launchIntent == .appOnly' \
  "secondary forward should only request UI for open-application launches"
assert_not_contains "$app" 'asyncAfter(deadline: .now() + 0.35)' \
  "secondary forward must not depend on a fixed 0.35s delay"
assert_contains "$app" 'receiveInstanceRequest' \
  "the primary must consume forwarded launch requests"
assert_not_contains "$instance" 'waitUntilNoPendingRequests' \
  "the secondary must not block AppKit waiting for a launch"
assert_contains "$app" 'enterReadOnly(.forwardUnconfirmed)' \
  "unacknowledged forwards must enter the current read-only recovery UI"
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

bash "$ROOT/tests/test-cyder-instance-runtime.sh"
echo "PASS test-cyder-instance"
