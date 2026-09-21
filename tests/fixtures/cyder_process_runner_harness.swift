import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2 {
    switch CommandLine.arguments[2] {
    case "immediate": exit(7)
    case "slow":
        usleep(500000)
        FileHandle.standardOutput.write(Data("after-deadline\n".utf8))
        exit(0)
    case "observer": alarm(10); while true { pause() }
    default: exit(1)
    }
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func process(_ kind: String) -> Process {
    let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = [root.path, kind]
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    return p
}
func pump(_ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 8
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "runner callback did not arrive")
}
let runner = CyderProcessRunner()
var immediate: CyderProcessRunner.Outcome?, count = 0, released = 0
runner.run(process: process("immediate"), policy: .launch, onRelease: { released += 1 }) { immediate = $0; count += 1 }
pump { immediate != nil && released == 1 }
precondition(immediate == .exited(7, signalled: false) && count == 1)
let missing = Process(); missing.executableURL = URL(fileURLWithPath: "/nonexistent/cyder-test")
var failed: CyderProcessRunner.Outcome?
runner.run(process: missing, policy: .mutation) { failed = $0 }
pump { failed != nil }
guard case .failedToStart = failed! else { fatalError("spawn error not preserved") }
let file = root.appendingPathComponent("output")
FileManager.default.createFile(atPath: file.path, contents: Data())
let output = FileHandle(forWritingAtPath: file.path)!
let slow = process("slow"); slow.standardOutput = output
var timed: CyderProcessRunner.Outcome?, spawned: CyderProcessRunner.Receipt?, slowReleased = false, slowCount = 0
let id = runner.run(process: slow, policy: .mutation, deadline: 0.05, output: output, onSpawn: { spawned = $0 }, onRelease: { slowReleased = true }) { timed = $0; slowCount += 1 }
pump { timed != nil }
precondition(timed == .unconfirmed && spawned!.supervisorPID > 0 && slow.isRunning && !slowReleased,
             "deadline killed mutation or released its lock")
runner.cancelObservation(id)
pump { slowReleased }
precondition(slowCount == 1 && (try! String(contentsOf: file, encoding: .utf8)).contains("after-deadline"), "output owner was closed before child exit")
let observer = process("observer")
var observerDone = false, observerReleased = false
runner.run(process: observer, policy: .observation, deadline: 0.03, onRelease: { observerReleased = true }) { result in precondition(result == .unconfirmed); observerDone = true }
pump { observerDone && observerReleased }
precondition(!observer.isRunning)
let launch = process("slow")
var launchStarted = false, launchFinished = false, launchReleased = false
runner.run(process: launch, policy: .launch, onSpawn: { _ in launchStarted = true }, onRelease: { launchReleased = true }) { result in precondition(result == .unconfirmed); launchFinished = true }
pump { launchStarted }
runner.quiesce()
pump { launchFinished }
precondition(launch.isRunning && !launchReleased, "quit stopped launch supervisor")
var late: CyderProcessRunner.Outcome?
let forbidden = process("immediate")
runner.run(process: forbidden, policy: .launch) { late = $0 }
pump { late != nil && launchReleased }
precondition(late == .cancelledBeforeSpawn && !forbidden.isRunning)
var remaining: Int?
runner.inspect { remaining = $0 }
pump { remaining != nil }
precondition(remaining == 0)
print("PASS native async runner: immediate exit, failed spawn, once-only deadline/cancel/quit, retained output and mutation lifetime, observer-only termination, frozen dispatch")
