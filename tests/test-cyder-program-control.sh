#!/usr/bin/env bash
# Program control from the menu bar: 結束…／強制結束… per row, always confirmed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-program-control.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_program_control_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_process_evidence.swift" "$ROOT/scripts/cyder_launch_observer.swift" "$ROOT/scripts/cyder_execution_phase.swift" "$ROOT/scripts/cyder_recovery_observer.swift" "$ROOT/scripts/cyder_process_table.swift" "$ROOT/scripts/cyder_independent_processes.swift" "$ROOT/scripts/cyder_window_access.swift" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"

# Library: a running game's 啟動遊戲 becomes 顯示, 結束… appears, and opening
# it again brings it forward (the same confirmed 結束 path as the menu).
source "$ROOT/tests/assert.sh"
library="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$library" 'selectionLaunchButton.title = running ? "顯示" : "啟動遊戲"' "a running game offers 顯示"
assert_contains "$library" 'selectionEndButton.title = "結束…"' "a running game offers 結束…"
assert_contains "$library" 'if let launch = runningLaunch?(game.executableURL) { onShowProgram?(launch); return }' \
  "opening a running game shows it instead of starting a second copy"
assert_contains "$app" 'controller.onEndProgram = { [weak self] launch in self?.statusItemController.requestProgramControl(launch: launch, force: false) }' \
  "the library's 結束… is the menu's confirmed 結束"
assert_contains "$app" 'programLaunchExecutables[launchID] = Self.programExecutableKey(exe)' "launches record their executable"
assert_contains "$app" 'let alive = self.onMainThread { self.statusItemController.hasLivePrograms(launch: launch) }' \
  "taskkill runs only while the launch still has a live program"
assert_contains "$app" 'self.wineLaunchObserver?.cancel()' "ending a starting program cancels its launch observation"
echo "PASS library and app wiring"
assert_contains "$library" 'selectionEndButton.title = phase == .notResponding ? "強制結束…" : "結束…"' \
  "after 結束 is ignored, the library offers 強制結束…"
assert_contains "$library" 'if programClosePhase?(launch) == .notResponding { onForceQuitProgram?(launch) } else { onEndProgram?(launch) }' \
  "the library's 強制結束… goes through the confirmed force path"
echo "PASS library escalation"
