import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2 {
    if CommandLine.arguments[2] == "delay" {
        let seconds = Double(CommandLine.arguments[3])!
        alarm(UInt32(seconds.rounded(.up)) + 5)
        Thread.sleep(forTimeInterval: seconds)
        try! Data("prepared".utf8).write(to: root.appendingPathComponent(CommandLine.arguments[4]))
        exit(0)
    }
    if CommandLine.arguments[2] == "marker" {
        try! Data("final-spawn".utf8).write(to: root.appendingPathComponent(CommandLine.arguments[3]))
        exit(0)
    }
    exit(92)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var children: [Process] = []
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else {
        for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
        fputs("FAIL preparation budget line \(line): \(message)\n", stderr); exit(1)
    }
}
func process(_ args: [String]) -> Process {
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [root.path] + args
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    children.append(child); return child
}
func pump(timeout: Double = 8, _ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "asynchronous completion did not arrive")
}
let prep = CyderProcessRunner.LauncherExecution(preparationOnly: true, isLaunch: true, isObservation: false, isStop: false)
let final = CyderProcessRunner.LauncherExecution(preparationOnly: false, isLaunch: true, isObservation: false, isStop: false)
if case .mutation = prep.policy {} else { check(false, "preparation must own mutation lifetime") }
if case .launch = final.policy {} else { check(false, "final launch policy changed") }
check(prep.deadline == 120 && final.deadline == 30, "preparation/final budgets are not distinct")
check(CyderProcessRunner.LauncherExecution(preparationOnly: false, isLaunch: false, isObservation: true, isStop: false).deadline == 5, "observer budget changed")
check(CyderProcessRunner.LauncherExecution(preparationOnly: false, isLaunch: false, isObservation: false, isStop: true).deadline == 15, "stop budget changed")
check(CyderProcessRunner.LauncherExecution(preparationOnly: false, isLaunch: false, isObservation: false, isStop: false).deadline == nil, "generic mutation gained a new deadline")

// Real wall-clock child crosses the old 30-second limit under the exact
// production-selected 120-second profile. Only then may a final child spawn.
let successfulRunner = CyderProcessRunner()
var successful: CyderProcessRunner.Outcome?, positiveReleased = false
let positiveStart = ProcessInfo.processInfo.systemUptime
Task {
    successful = await CyderWineLaunchSequence.run(prepare: {
        let result = await successfulRunner.run(process: process(["delay", "31.2", "positive.prepared"]),
            policy: prep.policy, deadline: prep.deadline, onRelease: { positiveReleased = true })
        return result == .exited(0, signalled: false) ? nil : result
    }, attachAndLaunch: {
        await successfulRunner.run(process: process(["marker", "positive.final"]), policy: final.policy, deadline: final.deadline)
    })
}
pump(timeout: 45) { successful != nil && positiveReleased }
let positiveElapsed = ProcessInfo.processInfo.systemUptime - positiveStart
check(positiveElapsed > 30 && successful == .exited(0, signalled: false), "legitimate >30s preparation did not reach final spawn")
check(FileManager.default.fileExists(atPath: root.appendingPathComponent("positive.final").path), "final child never actually executed")
let observer = CyderLaunchObserver(), signal = WineActivationWaiter(prefix: root.path)
var observed: CyderLaunchObserver.Result?, observedBudget: Double?
Task {
    observed = await observer.wait(duration: 30, signal: signal, onStarted: {
        observedBudget = $0 - ProcessInfo.processInfo.systemUptime
    })
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { signal.signal() }
pump { observed != nil }
check(observed == .activated && (observedBudget ?? 0) > 29.8, "preparation consumed the fresh 30s window observation")
print("PASS real >30s preparation: elapsed=\(positiveElapsed), profile=mutation/120s; final child and fresh 30s observation succeeded")
fflush(stdout)

// Exercise the actual 120-second bound, without a fake clock or an injected
// shorter budget. The child exits late; it must never release a late final spawn.
let timeoutRunner = CyderProcessRunner()
let timeoutChild = process(["delay", "122", "timeout.prepared"])
var timed: CyderProcessRunner.Outcome?, timeoutReleased = false, timeoutReplies = 0, finalCalls = 0
let timeoutStart = ProcessInfo.processInfo.systemUptime
Task {
    timed = await CyderWineLaunchSequence.run(prepare: {
        let result = await timeoutRunner.run(process: timeoutChild, policy: prep.policy, deadline: prep.deadline,
            onRelease: { timeoutReleased = true })
        timeoutReplies += 1
        return result == .exited(0, signalled: false) ? nil : result
    }, attachAndLaunch: {
        finalCalls += 1
        return await timeoutRunner.run(process: process(["marker", "timeout.final"]), policy: final.policy, deadline: final.deadline)
    })
}
pump(timeout: 125) { timed != nil }
let timeoutElapsed = ProcessInfo.processInfo.systemUptime - timeoutStart
check(timed == .unconfirmed && timeoutElapsed >= 119.8 && timeoutElapsed < 122, "the actual 120s preparation deadline was not observed")
check(timeoutChild.isRunning && !timeoutReleased && finalCalls == 0, "deadline killed the child, released ownership or spawned final")
pump { timeoutReleased }
check(timeoutReplies == 1 && finalCalls == 0 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("timeout.final").path), "late successful preparation replayed final spawn")
print("PASS real 120s timeout: elapsed=\(timeoutElapsed); physical mutation retained until actual exit, no late final spawn")
fflush(stdout)

let cancelledRunner = CyderProcessRunner()
var cancellation: CyderProcessRunner.Outcome?, cancellationReleased = false, cancellationReplies = 0
let cancelledChild = process(["delay", "0.3", "cancel.prepared"])
var cancellationID: UUID?
Task {
    cancellation = await CyderWineLaunchSequence.run(prepare: {
        await withCheckedContinuation { continuation in
            cancellationID = cancelledRunner.run(process: cancelledChild, policy: prep.policy, deadline: prep.deadline,
                onRelease: { cancellationReleased = true }) { outcome in
                cancellationReplies += 1; continuation.resume(returning: outcome)
            }
        }
    }, attachAndLaunch: {
        finalCalls += 1
        return await cancelledRunner.run(process: process(["marker", "cancel.final"]), policy: final.policy, deadline: final.deadline)
    })
}
pump { cancellationID != nil && cancelledChild.isRunning }
cancelledRunner.cancelObservation(cancellationID!)
pump { cancellation != nil }
check(cancellation == .unconfirmed && !cancellationReleased && cancelledChild.isRunning, "cancel revoked physical mutation ownership")
pump { cancellationReleased }
check(cancellationReplies == 1 && finalCalls == 0 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel.final").path), "cancelled observation enabled a late final spawn")
let frozen = CyderProcessRunner(); frozen.quiesce()
var refused: CyderProcessRunner.Outcome?, refusedRelease = false
frozen.run(process: process(["marker", "cancel.forbidden"]), policy: prep.policy, deadline: prep.deadline,
    onRelease: { refusedRelease = true }) { refused = $0 }
pump { refused != nil && refusedRelease }
check(refused == .cancelledBeforeSpawn && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel.forbidden").path), "quiesced preparation spawned a new child")
print("PASS cancellation contract: observation cancellation keeps physical owner; quiesce refuses unstarted work; neither dispatches final")
let result: [String: Any] = ["status": "PASS", "positivePreparationSeconds": positiveElapsed,
    "preparationBudgetSeconds": prep.deadline!, "timeoutObservedSeconds": timeoutElapsed,
    "finalBudgetSeconds": final.deadline!, "windowObservationBudgetSeconds": observedBudget!,
    "timeoutReplies": timeoutReplies, "lateFinalSpawns": finalCalls]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
