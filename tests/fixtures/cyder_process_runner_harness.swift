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
    case "marker":
        try! Data("spawned".utf8).write(to: root.appendingPathComponent(CommandLine.arguments[3]))
        exit(0)
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
var immediate: CyderProcessRunner.Outcome?, count = 0, released = 0, immediateSpawned = false
runner.run(process: process("immediate"), policy: .launch, onSpawn: { _ in immediateSpawned = true },
    onRelease: { released += 1 }) { precondition(immediateSpawned); immediate = $0; count += 1 }
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

// Hold two real spawn paths inside the formal runner. Deadline, inspect and
// quit must remain responsive, without opening extra workers for queued work.
final class SpawnGate {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var entries = 0
    func block() {
        precondition(!Thread.isMainThread)
        lock.lock(); entries += 1; lock.unlock()
        precondition(gate.wait(timeout: .now() + 8) == .success)
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return entries }
}
let spawnGate = SpawnGate()
let stalled = CyderProcessRunner(beforeSpawn: spawnGate.block)
var stalledResults = 0, stalledReleases = 0, stalledSpawns = 0
for index in 0..<5 {
    let p = process("marker"); p.arguments!.append("marker-\(index)")
    stalled.run(process: p, policy: .mutation, deadline: 0.08,
        onSpawn: { _ in stalledSpawns += 1 }, onRelease: { stalledReleases += 1 }) { outcome in
        precondition(outcome == .unconfirmed); stalledResults += 1
    }
}
pump { stalledResults == 5 && spawnGate.count() == 2 }
precondition(spawnGate.count() == 2 && stalledReleases == 0 && stalledSpawns == 0)
var retained: Int?
stalled.inspect { retained = $0 }; pump { retained != nil }
precondition(retained == 5, "timed-out spawn lost physical ownership")
var queuedOutcome: CyderProcessRunner.Outcome?, queuedReleased = false
let neverStarted = process("marker"); neverStarted.arguments!.append("marker-forbidden")
stalled.run(process: neverStarted, policy: .launch, onSpawn: { _ in fatalError("queued operation crossed quit") },
    onRelease: { queuedReleased = true }) { queuedOutcome = $0 }
stalled.quiesce()
pump { stalledReleases == 3 && queuedReleased && queuedOutcome != nil }
precondition(queuedOutcome == .cancelledBeforeSpawn)
precondition(spawnGate.count() == 2 && stalledSpawns == 0, "quit spawned queued work")
spawnGate.gate.signal(); spawnGate.gate.signal()
pump { stalledReleases == 5 }
precondition(stalledResults == 5 && stalledSpawns == 2)
let markerFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
precondition(markerFiles.filter { $0.hasPrefix("marker-") }.count == 2)
var stalledRemaining: Int?
stalled.inspect { stalledRemaining = $0 }; pump { stalledRemaining != nil }; precondition(stalledRemaining == 0)
print("PASS bounded spawn workers: deadlines/inspect/quit during stalled spawn, two physical calls, queued quit prevents spawn, claimed owners retained through actual return, exactly one delivery/release")

// Drive the two formal owners in sequence. A real 0.5-second native preparation
// must not spend the subsequent 0.2-second launch observation budget.
let preparation = CyderProcessRunner()
let preparedObserver = CyderLaunchObserver(), preparedSignal = WineActivationWaiter(prefix: root.path)
var prepared: CyderProcessRunner.Outcome?, preparedResult: CyderLaunchObserver.Result?
let preparationStarted = ProcessInfo.processInfo.systemUptime
preparation.run(process: process("slow"), policy: .launch, deadline: 2) { prepared = $0 }
pump { prepared != nil }
precondition(prepared == .exited(0, signalled: false) && ProcessInfo.processInfo.systemUptime - preparationStarted >= 0.4)
Task { preparedResult = await preparedObserver.wait(duration: 0.2, signal: preparedSignal) }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { preparedSignal.signal() }
pump { preparedResult != nil }; precondition(preparedResult == .activated, "preparation consumed launch observation")
print("PASS independent preparation/launch budgets: real delayed native preparation followed by complete fresh observation interval")
