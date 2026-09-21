import Foundation
import Darwin
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else { fputs("FAIL supervisor owner line \(line): \(message)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 15, line: UInt = #line) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), "callback timeout", line: line)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let scripts = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let shell = root.appendingPathComponent("launch.sh")
try Data(#"""
#!/bin/bash
set -e
source "$SOURCE_SCRIPTS/cyder-common.sh"
cyder_init_paths "$SOURCE_SCRIPTS"
cyder_sentinel_attach() {
  printf 'entered\n' > "$TEST_ROOT/entered"
  if [[ "$TEST_MODE" == fail ]]; then exit 37; fi
  while [[ ! -e "$TEST_ROOT/release" ]]; do sleep 0.02; done
}
cyder_exec_wine() {
  printf 'spawned\n' > "$TEST_ROOT/spawned"
  sleep 0.15
  return 53
}
cyder_run_wine_exe "$TEST_ROOT/runtime/bin/wine" "$TEST_ROOT/inert.exe" "$TEST_ROOT/prefix"
"""#.utf8).write(to: shell)
func process(_ directory: URL, mode: String) throws -> Process {
    for path in ["runtime/bin", "prefix", "support"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try Data().write(to: directory.appendingPathComponent("inert.exe"))
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [shell.path]
    p.environment = ProcessInfo.processInfo.environment.merging([
        "SOURCE_SCRIPTS": scripts.path, "TEST_ROOT": directory.path, "TEST_MODE": mode,
        "CYDER_SUPPORT": directory.appendingPathComponent("support").path,
        "CYDER_RUNTIME_ROOT": directory.appendingPathComponent("runtime").path,
        "CYDER_WINE_DETACH": "1", "CYDER_WINE_PID_FILE": directory.appendingPathComponent("pid").path,
        "CYDER_WINE_RESULT_FILE": directory.appendingPathComponent("result").path,
        "CYDER_SESSION_GUARD": "0", "CYDER_CAPTURE_WINE_LOG": "0",
    ]) { _, value in value }
    let log = directory.appendingPathComponent("launcher.log")
    FileManager.default.createFile(atPath: log.path, contents: Data())
    let output = try FileHandle(forWritingTo: log)
    p.standardOutput = output; p.standardError = output
    return p
}
let runner = CyderProcessRunner(), gate = CyderOperationGate()
var lease: CyderOperationGate.Lease?
gate.acquire(.environment("isolated")) { lease = $0 }; pump { lease != nil }
let delayed = root.appendingPathComponent("delayed")
let p = try process(delayed, mode: "delayed")
var observation: CyderProcessRunner.Outcome?, releases = 0
runner.run(process: p, policy: .launch, deadline: 0.05,
    onRelease: { releases += 1; gate.release(lease!) }) { observation = $0 }
pump { observation == .unconfirmed && FileManager.default.fileExists(atPath: delayed.appendingPathComponent("entered").path) }
var following: CyderOperationGate.Lease?
gate.acquire(.environment("isolated")) { following = $0 }
let until = ProcessInfo.processInfo.systemUptime + 6
while ProcessInfo.processInfo.systemUptime < until && releases == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
let heldBeforeHandoff = releases == 0 && following == nil && p.isRunning
let noPrematureSpawn = !FileManager.default.fileExists(atPath: delayed.appendingPathComponent("spawned").path)
// Release even a failing baseline before asserting, so the test never leaves
// an intentionally stalled supervisor behind.
try Data().write(to: delayed.appendingPathComponent("release"))
pump { releases == 1 && following != nil && FileManager.default.fileExists(atPath: delayed.appendingPathComponent("result").path) }
gate.release(following!)
let resultText = try String(contentsOf: delayed.appendingPathComponent("result"), encoding: .utf8)
check(heldBeforeHandoff, "native launcher released mutation ownership before its delayed supervisor handoff")
check(noPrematureSpawn && observation == .unconfirmed, "observation timeout changed execution outcome")
check(resultText.contains("exit_status=53"), "supervisor lost the exact root result")
check(p.terminationStatus == 0, "successful late handoff was reported as launcher failure")
print("PASS supervisor: delayed handoff retains real ProcessRunner/gate ownership beyond observation; no duplicate release; root status preserved")
let failure = root.appendingPathComponent("failed")
let failedProcess = try process(failure, mode: "fail")
var failed: CyderProcessRunner.Outcome?, failedRelease = false
runner.run(process: failedProcess, policy: .launch, onRelease: { failedRelease = true }) { failed = $0 }
pump { failed != nil && failedRelease }
check(failed == .exited(37, signalled: false), "pre-handoff supervisor failure lost its status")
check(!FileManager.default.fileExists(atPath: failure.appendingPathComponent("spawned").path), "failed supervisor spawned")
print("PASS supervisor: exact child failure before handoff, no fabricated PID or spawn")
let quitting = root.appendingPathComponent("quitting")
let quittingProcess = try process(quitting, mode: "delayed")
let quittingRunner = CyderProcessRunner()
var quittingOutcome: CyderProcessRunner.Outcome?, quittingReleases = 0
quittingRunner.run(process: quittingProcess, policy: .launch, deadline: 0.05,
    onRelease: { quittingReleases += 1 }) { quittingOutcome = $0 }
pump { quittingOutcome == .unconfirmed && FileManager.default.fileExists(atPath: quitting.appendingPathComponent("entered").path) }
quittingRunner.quiesce()
var quitTick = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { quitTick = true }; pump { quitTick }
let survivedQuiesce = quittingProcess.isRunning && quittingReleases == 0
try Data().write(to: quitting.appendingPathComponent("release"))
pump { quittingReleases == 1 && FileManager.default.fileExists(atPath: quitting.appendingPathComponent("result").path) }
check(survivedQuiesce && quittingOutcome == .unconfirmed, "quiescing terminated or prematurely released an authorized executor")
let quitResult = try String(contentsOf: quitting.appendingPathComponent("result"), encoding: .utf8)
check(quitResult.contains("exit_status=53"), "authorized native stand-in did not survive observer quit")
print("PASS supervisor: ProcessRunner quiesce leaves authorized child running and releases only after physical handoff")
runner.quiesce(); gate.quiesce()
