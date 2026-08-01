#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

source_text="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$source_text" "application.reply(toOpenOrPrint: .success)" \
  "Finder open-file requests must receive a LaunchServices reply"
assert_contains "$source_text" "launchGameFromLibrary" \
  "Finder requests received by a visible library must use the monitored launch path"
assert_not_contains "$source_text" "createsNewApplicationInstance = true" \
  "library launches must stay in the UI process so early failures can be presented"
assert_contains "$source_text" "libraryLaunchInProgress" \
  "the single Wine activation waiter must reject overlapping library startups"
assert_contains "$source_text" "Association launch: EXE will arrive separately in openFiles" \
  "association launches should treat application argv exclusively as game arguments"
assert_contains "$source_text" "documentLaunchRequested = true" \
  "open-file requests must switch the app out of settings mode"
assert_contains "$source_text" "asyncAfter(deadline: .now() + 0.2)" \
  "settings-mode startup must allow the open-file event to arrive"
assert_contains "$source_text" "if self.documentLaunchRequested" \
  "a late open-file request must suppress the settings completion"
assert_contains "$source_text" "runWineThroughLauncher" \
  "Finder document events must relay Wine launches to Bash"
assert_contains "$source_text" '"CYDER_WINE_DETACH": "1"' \
  "the AppKit document relay must request a detached Bash launch"
assert_contains "$source_text" '"CYDER_CAPTURE_WINE_LOG": "1"' \
  "Finder launches must retain startup stderr when Wine exits before activation"
assert_contains "$source_text" '"CYDER_WINE_RESULT_FILE": exitResultURL.path' \
  "Finder launches must request a per-launch Wine result sidecar"
assert_contains "$source_text" 'if exitStatus == 53' \
  "protected-folder guidance must use Wine's captured wait status"
assert_contains "$source_text" 'launchEnvironment: launchEnvironment' \
  "game-library test settings must flow into the monitored Bash launch"
assert_not_contains "$source_text" 'launchLogShowsFolderAccessDenied()' \
  "protected-folder guidance must not parse the shared last-launch log"
assert_contains "$source_text" 'code: "CYD-WIN-003"' \
  "protected-folder failures must use a dedicated actionable error"
assert_contains "$source_text" 'alert.addButton(withTitle: "打開 Games 資料夾")' \
  "protected-folder failures must offer to open the recommended location"
assert_contains "$source_text" 'FileManager.default.createDirectory(at: games' \
  "the recommended Games directory must be created on demand"
assert_contains "$source_text" 'args: [context.launcher' \
  "native operations must invoke the bundled Bash launcher"
support_text="$(cat "$ROOT/scripts/cyder_launch_support.swift")"
assert_contains "$source_text" "NSApp.setActivationPolicy(.accessory)" \
  "document launches must remain UI-capable without adding a Dock icon"
assert_contains "$support_text" "NSRunningApplication.current.activate" \
  "setup and error panels must explicitly activate Cyder"
assert_contains "$support_text" "anchorWindow: NSWindow? = nil" \
  "alerts should accept an optional window anchor"
assert_contains "$support_text" "alert.window.setFrameOrigin" \
  "alerts should be positioned explicitly instead of using a stale saved frame"
assert_contains "$support_text" "seen.insert(path).inserted" \
  "argv and openFiles delivery of the same EXE must be deduplicated"
assert_contains "$source_text" "var prefix = CyderPaths.sharedBottle" \
  "an EXE without a Profile must use the prepared Shared bottle"
assert_contains "$source_text" 'result.machineResult["healthChecked"] == "1"' \
  "bootstrap should consume the machine-readable health result"
assert_contains "$source_text" "if !bootstrapHealthChecked" \
  "a successful bootstrap health probe should not run twice"
assert_contains "$source_text" "CYDER_PROGRESS_FILE" \
  "bootstrap should expose a progress file for staged setup messages"
assert_contains "$source_text" 'args.contains("--bootstrap-only")' \
  "long setup operations should enable progress polling"

echo "PASS test-cyder-open-files-lifecycle"
