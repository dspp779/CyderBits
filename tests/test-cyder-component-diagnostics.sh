#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d /private/tmp/cyder-component-ui.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
cat >"$TEMP/main.swift" <<'SWIFT'
import Cocoa
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func pump(_ duration: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appendingPathComponent("Resources")
let scripts = resources.appendingPathComponent("ogom-scripts")
try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
let script = scripts.appendingPathComponent("cyder-component-integrity.rb")
// The subprocess is a fixture observer, never Wine or a host game.
try "sleep 0.15; puts '{\"status\":\"ok\",\"components\":[]}'".write(to: script, atomically: true, encoding: .utf8)
let controller = CyderComponentDiagnosticsController(resources: resources, runtime: root, engine: root)
let start = Date()
controller.runScan()
require(Date().timeIntervalSince(start) < 0.1, "scan must not block the UI")
require(controller.isChecking, "running state")
pump(3, until: { !controller.isChecking })
require(controller.diagnosticText.contains("符合清單"), "completed result")
try "sleep 3; puts '{\"status\":\"mismatch\"}'".write(to: script, atomically: true, encoding: .utf8)
controller.runScan()
pump(0.1)
controller.cancelScan()
require(!controller.isChecking && controller.diagnosticText.contains("已取消"), "cancel state")
try "puts '{\"status\":\"ok\",\"components\":[]}'".write(to: script, atomically: true, encoding: .utf8)
controller.runScan()
pump(3, until: { !controller.isChecking })
require(controller.diagnosticText.contains("符合清單"), "restart after cancel")
pump(0.3)
require(controller.diagnosticText.contains("符合清單"), "stale callback must not replace new result")
require(CyderComponentDiagnosticsController.describe(Data()).contains("無法確認"), "invalid output")
require(CyderComponentDiagnosticsController.describe(Data("{}".utf8), overflow: true).contains("無法確認"), "bounded output")
let report = Data("{\"status\":\"mismatch\",\"components\":[{\"component\":\"engine\",\"files\":[{\"path\":\"bin/wine\",\"status\":\"missing\"}]}]}".utf8)
require(CyderComponentDiagnosticsController.describe(report).contains("缺檔：bin/wine"), "specific evidence")
let legacy = Data("{\"status\":\"ok\",\"components\":[{\"component\":\"dxmt\",\"files\":[{\"path\":\"winemetal.so\",\"status\":\"ok\",\"signature\":\"unsigned\",\"signaturePolicy\":\"upstream-unsigned\"}]}]}".utf8)
require(CyderComponentDiagnosticsController.describe(legacy).contains("符合精確來源例外"), "reviewed unsigned is visible even when allowed")
try "sleep 3".write(to: script, atomically: true, encoding: .utf8)
let bounded = CyderComponentDiagnosticsController(resources: resources, runtime: root, engine: root, budget: 0.1)
bounded.runScan()
pump(2, until: { !bounded.isChecking })
require(!bounded.isChecking && bounded.diagnosticText.contains("無法確認"), "deadline is bounded and unknown")
bounded.close()
try "STDOUT.write('x' * (5 * 1024 * 1024))".write(to: script, atomically: true, encoding: .utf8)
controller.runScan()
pump(3, until: { !controller.isChecking })
require(!controller.isChecking && controller.diagnosticText.contains("無法確認"), "oversize output is drained and bounded")
try "sleep 3".write(to: script, atomically: true, encoding: .utf8)
controller.runScan()
pump(0.05)
controller.close()
require(!controller.isChecking && controller.diagnosticText.contains("已取消"), "closing cancels the observer")
print("PASS: background result, UI responsiveness, cancellation, restart fencing, report formatting")
SWIFT
swiftc -module-cache-path "$TEMP/cache" "$ROOT/scripts/cyder_process_runner.swift" \
  "$ROOT/scripts/cyder_paths.swift" "$ROOT/scripts/cyder_component_diagnostics.swift" "$TEMP/main.swift" -o "$TEMP/test"
"$TEMP/test" "$TEMP"
