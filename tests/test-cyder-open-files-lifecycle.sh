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
assert_contains "$source_text" "NSApp.activate(ignoringOtherApps: true)" \
  "Profile creation confirmation must be visible"

echo "PASS test-cyder-open-files-lifecycle"
