import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let engine = URL(fileURLWithPath: CommandLine.arguments[0])
let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
for path in [one, two] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
final class Input {
    let lock = NSLock()
    var now: TimeInterval = 0
    var empty = false
    var generation: UInt64 = 1
    var count = 0
    var blocked = true
    let gate = DispatchSemaphore(value: 0)
    func time() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func result(_ identity: CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result {
        precondition(!Thread.isMainThread)
        lock.lock(); count += 1; let stall = blocked && identity.prefix.hasSuffix("/one"); let isEmpty = empty; let born = generation; lock.unlock()
        if stall { precondition(gate.wait(timeout: .now() + 15) == .success) }
        return isEmpty ? .empty : .alive(.init(boot: "test-boot", pid: 123, started: born))
    }
    func change(_ work: (Input) -> Void) { lock.lock(); work(self); lock.unlock() }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 8) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "monitor event deadline")
}
let input = Input(), epoch = UUID()
var snapshot = CyderLifecycle.State(epoch: epoch).snapshot
var events = 0
let store = CyderLifecycleStore(epoch: epoch) { s, _ in snapshot = s; events += 1 }
let monitor = CyderEnvironmentMonitor(epoch: epoch, directory: root.appendingPathComponent("history"), waitersEnabled: false,
    clock: input.time, probe: input.result, event: store.send)
var tracked = 0
monitor.track(prefix: one, engine: engine) { _ in tracked += 1 }
monitor.track(prefix: two, engine: engine) { _ in tracked += 1 }
pump { tracked == 2 && snapshot.environments.values.contains { $0.prefix.hasSuffix("/two") && $0.existence == .alive } }
precondition(snapshot.environments.count == 2, "blocked observer prevented other bottle")
let second = snapshot.environments.values.first { $0.prefix.hasSuffix("/two") }!
for _ in 0..<50 { monitor.reconcile(.init(epoch: epoch, environment: second.id, generation: second.generation)) }
// First scan remains physically blocked, yet second bottle calibration and
// state/menu delivery continue. No new slot for the first environment.
input.change { $0.blocked = false }; input.gate.signal()
pump { snapshot.environments.values.allSatisfy { $0.existence == .alive } }
input.change { $0.generation = 2 }
monitor.reconcile(.init(epoch: epoch, environment: second.id, generation: second.generation))
pump { snapshot.environments[second.id]!.generation > second.generation }
let current = snapshot.environments[second.id]!
store.send(.reconcileStarted(.init(epoch: epoch, environment: second.id, generation: second.generation), UUID()))
let history = root.appendingPathComponent("history/managed-environments-v1.json")
pump { FileManager.default.fileExists(atPath: history.path) }
let retainedHistory = try Data(contentsOf: history)
var execution: UUID?
Task { execution = await monitor.beginExecution(prefix: two, engine: engine) }
pump { execution != nil }
input.change { $0.empty = true; $0.now = 100 }
monitor.reconcile(.init(epoch: epoch, environment: current.id, generation: current.generation))
pump { snapshot.environments[current.id]!.existence == .unconfirmed }
precondition(snapshot.environments[current.id]!.existence != .exited, "single empty probe ended environment")
input.change { $0.now = 101 }
monitor.reconcile(.init(epoch: epoch, environment: current.id, generation: current.generation))
var barrier = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { barrier = true }
pump { barrier }
precondition(snapshot.environments[current.id]!.existence == .unconfirmed, "live executor lost environment ownership at observation deadline")
var released = false
monitor.endExecution(execution!) { released = true }
monitor.endExecution(execution!) // duplicate/late release cannot end a newer owner
pump { released }
input.change { $0.now = 132 }
monitor.reconcile(.init(epoch: epoch, environment: current.id, generation: current.generation))
var sampled = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sampled = true }
pump { sampled }
input.change { $0.now = 133 }
monitor.reconcile(.init(epoch: epoch, environment: current.id, generation: current.generation))
pump { snapshot.environments[current.id]!.existence == .exited }
store.send(.quit); monitor.stop()
pump { snapshot.phase == .quiescing }
// Restoration goes through the formal reader, probes and store, never replaying
// a launch or adopting a stored process ID. Also reject corrupt history locally.
let recoveryRoot = root.appendingPathComponent("recovery")
try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
let recoveryFile = recoveryRoot.appendingPathComponent("managed-environments-v1.json")
try retainedHistory.write(to: recoveryFile)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryFile.path)
let recoveryEpoch = UUID()
var restored = CyderLifecycle.State(epoch: recoveryEpoch).snapshot
let recoveryStore = CyderLifecycleStore(epoch: recoveryEpoch) { s, _ in restored = s }
input.change { $0.empty = false }
let recovery = CyderEnvironmentMonitor(epoch: recoveryEpoch, directory: recoveryRoot, expectedEngine: engine, waitersEnabled: false,
    clock: input.time, probe: input.result, event: recoveryStore.send)
var ready = false
recovery.restore { ready = true }
pump { ready && restored.environments.count == 2 && restored.environments.values.allSatisfy { $0.existence == .alive } }
let old = CyderLifecycle.Stamp(epoch: epoch, environment: current.id, generation: current.generation)
let staleToken = UUID()
recoveryStore.send(.reconcileStarted(old, staleToken))
recoveryStore.send(.reconciled(old, staleToken, .exited, .healthy))
recoveryStore.send(.visibleUI(true))
pump { restored.visibleUI }
precondition(restored.environments[current.id]!.existence == .alive)
recovery.stop()
let corruptRoot = root.appendingPathComponent("corrupt")
try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
let corruptFile = corruptRoot.appendingPathComponent("managed-environments-v1.json")
try Data("bad".utf8).write(to: corruptFile)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptFile.path)
let corrupt = CyderEnvironmentMonitor(epoch: UUID(), directory: corruptRoot, waitersEnabled: false, event: { _ in fatalError("corrupt registry emitted authority") })
var issue = false, corruptReady = false
corrupt.onIssue = { _ in issue = true }
corrupt.restore { corruptReady = true }
pump { issue && corruptReady }
corrupt.stop()
print("PASS formal monitor/store: restoration revalidation, old epoch rejection, corrupt registry isolation; blocked probe isolation, coalescing, server generation, old event rejection, two-sample empty calibration, quit")
