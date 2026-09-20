#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Cocoa
import Foundation
struct CyderSentinelHolder {}
final class CyderDiagnostics {
    static let shared = CyderDiagnostics()
    func info(_ message: String) {}
}
struct TestWindow { let pid: Int32; let ownerName: String }
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
func wineProcessTreeIDs(root: Int32) -> Set<Int32> {
    precondition(!Thread.isMainThread, "process-tree query blocked AppKit")
    return [root]
}
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] { [] }
let scanStarted = DispatchSemaphore(value: 0)
let releaseScan = DispatchSemaphore(value: 0)
func wineOnscreenWindows(matchingPrefix prefix: String, extraPIDs: Set<Int32>) -> [TestWindow] {
    precondition(!Thread.isMainThread, "window query blocked AppKit")
    scanStarted.signal()
    precondition(releaseScan.wait(timeout: .now() + 5) == .success)
    return []
}
final class TestDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}
let delegate = TestDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
let controller = CyderStatusItemController()
controller.beginLaunch(id: "test", prefix: URL(fileURLWithPath: "/tmp/cyder-test"), executableName: "Test", pid: 0)
var completed = false
controller.claimLiveWindows(id: "test") { completed = true }
precondition(scanStarted.wait(timeout: .now() + 5) == .success)
// Simulate a slow WindowServer query. Menu callbacks must still return while
// that query is blocked, and a removed group must not be resurrected afterward.
let menu = NSMenu(title: "Test")
controller.menuNeedsUpdate(menu)
controller.menuWillOpen(menu)
precondition(!completed)
precondition(menu.items.contains { $0.title.contains("正在啟動") })
controller.endLaunch(id: "test")
releaseScan.signal()
let deadline = Date().addingTimeInterval(5)
while !completed && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(completed, "observation completion was lost")
precondition(!controller.hasActiveSessions, "stale snapshot resurrected a launch")
controller.menuDidClose(menu)
try! Data("passed".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swiftc -module-cache-path "$TEST_DIR/module-cache" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test-menu"
"$TEST_DIR/test-menu" "$TEST_DIR/passed"
[[ -f "$TEST_DIR/passed" ]]
echo "PASS test-cyder-menu-responsiveness"
