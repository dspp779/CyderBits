import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func pump(_ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 5
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "launch observer completion missing")
}
func start(_ observer: CyderLaunchObserver, _ signal: WineActivationWaiter, duration: TimeInterval,
           read: @escaping () -> CyderLaunchObserver.Sample,
           done: @escaping (CyderLaunchObserver.Result) -> Void) {
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    Task.detached {
        let result = await observer.wait(until: deadline, signal: signal, read: read)
        DispatchQueue.main.async { done(result) }
    }
}
let early = WineActivationWaiter(prefix: root.path); early.signal()
var earlyResult: CyderLaunchObserver.Result?
start(CyderLaunchObserver(), early, duration: 1, read: { .init(rootStatus: nil, lifecycle: nil) }) { earlyResult = $0 }
pump { earlyResult != nil }; precondition(earlyResult == .activated)
let handoff = WineActivationWaiter(prefix: root.path)
var handoffResult: CyderLaunchObserver.Result?
start(CyderLaunchObserver(), handoff, duration: 1, read: { .init(rootStatus: 0, lifecycle: "background") }) { handoffResult = $0 }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handoff.signal() }
pump { handoffResult != nil }; precondition(handoffResult == .activated, "clean root exit prematurely finished observation")
var rootFailure: CyderLaunchObserver.Result?
start(CyderLaunchObserver(), WineActivationWaiter(prefix: root.path), duration: 1, read: { .init(rootStatus: 53, lifecycle: "background") }) { rootFailure = $0 }
pump { rootFailure != nil }; precondition(rootFailure == .rootFailed(53))
var windowless: CyderLaunchObserver.Result?
start(CyderLaunchObserver(), WineActivationWaiter(prefix: root.path), duration: 1, read: { .init(rootStatus: 0, lifecycle: "stopped") }) { windowless = $0 }
pump { windowless != nil }; precondition(windowless == .finishedWithoutWindow)
final class Counts {
    let lock = NSLock(); var reads = 0
    func enter() { lock.lock(); reads += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}
let counts = Counts(), gate = DispatchSemaphore(value: 0)
var timed = 0
let observers = (0..<4).map { _ in CyderLaunchObserver() }
let signals = (0..<4).map { _ in WineActivationWaiter(prefix: root.path) }
for i in 0..<4 {
    start(observers[i], signals[i], duration: 0.1, read: {
        precondition(!Thread.isMainThread); counts.enter()
        precondition(gate.wait(timeout: .now() + 4) == .success)
        return .init(rootStatus: 0, lifecycle: "stopped")
    }) { result in precondition(result == .unconfirmed); timed += 1 }
}
pump { timed == 4 }
precondition(counts.value() == 2, "stuck reads exceeded the global bound")
for i in 0..<4 { signals[i].signal(); observers[i].cancel() }
gate.signal(); gate.signal()
var ticked = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ticked = true }
pump { ticked }
precondition(timed == 4, "late activation/read/cancel delivered duplicate result")
let sidecar = root.appendingPathComponent("root.result")
try Data("schema=1\nexit_status=53\n".utf8).write(to: sidecar)
precondition(CyderLaunchObserver.readSidecar(sidecar)["exit_status"] == "53")
let link = root.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sidecar)
precondition(CyderLaunchObserver.readSidecar(link).isEmpty)
let fifo = root.appendingPathComponent("fifo"); precondition(mkfifo(fifo.path, 0o600) == 0)
precondition(CyderLaunchObserver.readSidecar(fifo).isEmpty, "FIFO should not block sidecar adapter")
print("PASS formal launch observer: early activation, root-to-child handoff, captured root failure, fixed deadline under stuck reads, global in-flight bound, late events, safe sidecars")
