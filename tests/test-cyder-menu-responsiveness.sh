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
let scanStarted = DispatchSemaphore(value: 0)
let releaseScan = DispatchSemaphore(value: 0)
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] {
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
var samples: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    controller.menuNeedsUpdate(menu)
    let mutations = controller.menuMutationCount
    controller.menuWillOpen(menu)
    precondition(controller.menuMutationCount == mutations, "willOpen mutated menu")
    controller.menuDidClose(menu)
    precondition(controller.menuMutationCount == mutations, "didClose mutated menu")
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
controller.menuNeedsUpdate(menu)
controller.menuWillOpen(menu)
let mutations = controller.menuMutationCount
let removals = controller.statusRemovalCount
precondition(!completed)
precondition(menu.items.contains { $0.title.contains("正在啟動") })
// Repeated requests while the same scan is stuck do not add more OS work.
for _ in 0..<100 { controller.claimLiveWindows(id: "test") {} }
controller.endLaunch(id: "test")
let trackingDeadline = Date().addingTimeInterval(0.1)
while Date() < trackingDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
precondition(controller.menuMutationCount == mutations, "tracking changed menu structure")
precondition(controller.statusRemovalCount == removals, "tracking removed status item")
releaseScan.signal()
let deadline = Date().addingTimeInterval(5)
while !completed && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(completed, "observation completion was lost")
precondition(!controller.hasActiveSessions, "stale snapshot resurrected a launch")
controller.menuDidClose(menu)
precondition(controller.menuMutationCount == mutations, "close callback mutated menu")
controller.menuWillOpen(menu) // reopen before deferred settlement
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(controller.statusRemovalCount == removals, "quick reopen lost status item")
controller.menuDidClose(menu)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(!controller.hasStatusItem, "idle status item never removed")
let revision = controller.lifecycleSnapshot.revision
let old = CyderLifecycle.State(epoch: controller.lifecycleSnapshot.epoch).snapshot
controller.applyLifecycleSnapshot(old)
precondition(controller.lifecycleSnapshot.revision == revision, "stale revision applied")
var foreign = CyderLifecycle.State()
for _ in 0..<100 { foreign.reduce(.visibleUI(true)) }
controller.applyLifecycleSnapshot(foreign.snapshot)
precondition(controller.lifecycleSnapshot.revision == revision, "foreign epoch applied")
if let path = ProcessInfo.processInfo.environment["CYDER_MENU_SAMPLES"] {
    let raw = "sample,callback_cycle_ms\n" + samples.enumerated().map { "\($0.offset + 1),\($0.element)" }.joined(separator: "\n") + "\n"
    try! raw.write(toFile: path, atomically: true, encoding: .utf8)
}
let sorted = samples.sorted()
print("callback-cycle proxy samples=30 p95_ms=\(sorted[28]) max_ms=\(sorted.last!)")
precondition(sorted[28] <= 100 && sorted.last! < 250, "callback responsiveness target missed")
try! ("sample,callback_cycle_ms\n" + samples.enumerated().map { "\($0.offset + 1),\($0.element)" }.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
SWIFT
swiftc -module-cache-path "$TEST_DIR/module-cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test-menu"
"$TEST_DIR/test-menu" "$TEST_DIR/passed"
[[ "$(wc -l < "$TEST_DIR/passed" | tr -d ' ')" == 31 ]]
if [[ -n "${CYDER_MENU_SAMPLES:-}" ]]; then cp "$TEST_DIR/passed" "$CYDER_MENU_SAMPLES"; fi
cat "$TEST_DIR/passed"
echo "PASS test-cyder-menu-responsiveness"
