#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

source_text="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$source_text" "application.reply(toOpenOrPrint: .success)" \
  "Finder open-file requests must receive a LaunchServices reply"
assert_contains "$source_text" "documentLaunchRequested = true" \
  "open-file requests must switch the app out of settings mode"
assert_contains "$source_text" "asyncAfter(deadline: .now() + 0.2)" \
  "settings-mode startup must allow the open-file event to arrive"
assert_contains "$source_text" "if self.documentLaunchRequested" \
  "a late open-file request must suppress the settings completion"
support_text="$(cat "$ROOT/scripts/cyder_launch_support.swift")"
assert_contains "$source_text" "NSApp.setActivationPolicy(.accessory)" \
  "document launches must remain UI-capable without adding a Dock icon"
assert_contains "$support_text" "NSRunningApplication.current.activate" \
  "setup and error panels must explicitly activate Cyder"
assert_contains "$support_text" "anchorWindow: NSWindow? = nil" \
  "alerts should accept an optional window anchor"
assert_contains "$support_text" "alert.window.setFrameOrigin" \
  "alerts should be positioned explicitly instead of using a stale saved frame"
assert_contains "$source_text" "var prefix = CyderPaths.sharedBottle" \
  "an EXE without a Profile must use the prepared Shared bottle"

echo "PASS test-cyder-open-files-lifecycle"
