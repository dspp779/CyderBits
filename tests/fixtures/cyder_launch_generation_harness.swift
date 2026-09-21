import Foundation
import Darwin

if CommandLine.arguments.contains("--owned-helper") { alarm(20); while true { pause() } }

let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[0])
let prefix = root.appendingPathComponent("prefix")
try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
final class Input {
    let lock = NSLock()
    var now: TimeInterval = 0, count = 0
    var result = CyderEnvironmentProbe.Result.alive(.init(boot: "fixture", pid: 123, started: 1))
    func change(_ body: (Input) -> Void) { lock.lock(); body(self); lock.unlock() }
    func time() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func samples() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    func probe(_ identity: CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result {
        lock.lock(); defer { lock.unlock() }; count += 1; return result
    }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    return condition()
}
var failures: [String] = []
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
func settle() { _ = pump({ false }, timeout: 0.08) }
let input = Input(), epoch = UUID()
var snapshot = CyderLifecycle.State(epoch: epoch).snapshot
let store = CyderLifecycleStore(epoch: epoch) { value, _ in snapshot = value }
let monitor = CyderEnvironmentMonitor(epoch: epoch, directory: root.appendingPathComponent("history"),
    waitersEnabled: false, clock: input.time, probe: input.probe, event: store.send)
var tracked = false
monitor.track(prefix: prefix, engine: engine) { _ in tracked = true }
check(pump { tracked && snapshot.environments.values.first?.existence == .alive }, "initial environment observed")
guard let environment = snapshot.environments.values.first else { exit(1) }
let old = CyderLifecycle.Stamp(epoch: epoch, environment: environment.id, generation: environment.generation)
store.send(.executionAttached(old, .init(id: "old", digest: "old", environment: environment.id, phase: .dispatching, launch: "old"),
    .init(id: "old", request: "old", environment: environment.id, name: "Old", deadline: .infinity)))
check(pump { snapshot.launches["old"] != nil }, "old observation installed")
input.change { $0.now = 10; $0.result = .empty }
let before = input.samples()
var execution: UUID?, bound: CyderLifecycle.Stamp?, returned = false, drained = false
Task {
    execution = await monitor.beginExecution(prefix: prefix, engine: engine, drained: { _ in drained = true })
    if let execution { bound = await monitor.executionStamp(execution) }
    returned = true
}
check(pump { input.samples() > before }, "fresh admission probe started")
settle()
check(!returned, "one empty sample cannot admit against the stale server generation")
input.change { $0.now = 10.6 }
monitor.reconcile(old)
check(pump { returned }, "two empty samples complete admission")
guard let execution, let bound else { print("FAIL no execution stamp"); monitor.stop(); exit(1) }
check(bound.generation > old.generation, "new execution receives a new generation before it can spawn")
store.send(.executionAttached(bound, .init(id: "new", digest: "new", environment: environment.id, phase: .dispatching, launch: "new"),
    .init(id: "new", request: "new", environment: environment.id, name: "New", deadline: .infinity)))
check(pump { snapshot.launches["new"] != nil }, "new committed launch attached")
input.change { $0.result = .alive(.init(boot: "fixture", pid: 124, started: 2)) }
monitor.reconcile(bound)
check(pump { snapshot.environments[environment.id]?.existence == .alive }, "new server observed")
check(snapshot.environments[environment.id]?.generation == bound.generation && snapshot.launches["new"]?.outcome == nil,
    "first server in the prepared generation must not invalidate its own launch")
check(snapshot.requests["old"]?.phase == .uncertain, "old launch does not transfer into new generation")
store.send(.observationFinished(old, launch: "old", outcome: .confirmedStarted))
settle(); check(snapshot.requests["old"]?.phase == .uncertain, "late old success remains rejected")
let scope = "\(environment.id.uid):\(Int64(bitPattern: environment.id.device)):\(environment.id.inode)"
monitor.confirmRootExit(execution, prefixScope: scope)
var released = false; monitor.endExecution(execution) { released = true }
check(pump { released }, "executor released")
input.change { $0.now = 20; $0.result = .empty }
let current = CyderLifecycle.Stamp(epoch: epoch, environment: environment.id, generation: snapshot.environments[environment.id]!.generation)
monitor.reconcile(current); settle()
input.change { $0.now = 20.6 }; monitor.reconcile(current)
check(pump { drained }, "new launch keeps its exact drain observation across normal server creation")
monitor.stop()

// A probe that outlives admission must never hand an executor token back late.
final class BlockedProbe {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var held = true, entered = false
    func started() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func release() { lock.lock(); held = false; lock.unlock(); gate.signal() }
    func read(_ identity: CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result {
        lock.lock(); let wait = held; entered = true; lock.unlock()
        if wait { _ = gate.wait(timeout: .now() + 10) }
        return .alive(.init(boot: "injected", pid: 789, started: 1))
    }
}
let blocked = BlockedProbe()
let admission = CyderEnvironmentMonitor(epoch: UUID(), directory: root.appendingPathComponent("blocked-history"),
    waitersEnabled: false, probe: blocked.read, event: { _ in })
let unknownAdmission = CyderEnvironmentMonitor(epoch: UUID(), directory: root.appendingPathComponent("unknown-history"),
    waitersEnabled: false, probe: { _ in .unknown("injected-unreadable") }, event: { _ in })
var unknownReturned = false, unknownToken: UUID?
Task { unknownToken = await unknownAdmission.beginExecution(prefix: prefix, engine: engine); unknownReturned = true }
var admissionReplies = 0, admitted: UUID?
Task { admitted = await admission.beginExecution(prefix: prefix, engine: engine); admissionReplies += 1 }
check(pump { blocked.started() }, "blocked admission probe started")
check(pump({ admissionReplies == 1 }, timeout: 7) && admitted == nil, "stuck calibration denies executor within its preparation budget")
blocked.release(); settle()
check(admissionReplies == 1 && admitted == nil, "late probe cannot deliver a second admission")
admission.stop()
check(pump { unknownReturned } && unknownToken == nil, "unreadable calibration cannot authorize native spawn")
unknownAdmission.stop()

final class BlockedIdentity {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var calls = 0, active = 0
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (calls, active) }
    func read(_ prefix: URL, _ engine: URL) -> CyderEnvironmentProbe.Identity? {
        lock.lock(); calls += 1; active += 1; lock.unlock()
        if prefix.lastPathComponent.hasPrefix("held-") { _ = gate.wait(timeout: .now() + 15) }
        lock.lock(); active -= 1; lock.unlock()
        return CyderEnvironmentProbe.identify(prefix: prefix, engine: engine)
    }
}
let identityHook = BlockedIdentity()
let identityMonitor = CyderEnvironmentMonitor(epoch: UUID(), directory: root.appendingPathComponent("identity-history"),
    waitersEnabled: false, identify: identityHook.read, probe: { _ in .empty }, event: { _ in })
let heldPrefixes = [root.appendingPathComponent("held-one"), root.appendingPathComponent("held-two")]
for path in heldPrefixes { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
var denied = 0, unexpectedlyAdmitted = 0
func requestHeld(_ prefix: URL) {
    Task { if await identityMonitor.beginExecution(prefix: prefix, engine: engine) == nil { denied += 1 } else { unexpectedlyAdmitted += 1 } }
}
requestHeld(heldPrefixes[0]); check(pump { identityHook.counts().1 == 1 }, "first identity lookup blocked")
var independentFinished = false, independent: UUID?
Task { independent = await identityMonitor.beginExecution(prefix: prefix, engine: engine); independentFinished = true }
check(pump { independentFinished }, "one blocked prefix must not block a healthy prefix admission")
check(independent != nil, "independent prefix granted")
if let independent { identityMonitor.endExecution(independent) }
requestHeld(heldPrefixes[1]); check(pump { identityHook.counts().1 == 2 }, "two physical identity slots occupied")
for _ in 0..<33 { requestHeld(heldPrefixes[0]) }
check(pump({ denied == 35 }, timeout: 7), "identity capacity and timeout return all pending callers")
check(unexpectedlyAdmitted == 0 && identityHook.counts().0 == 3, "no extra physical identity work after caller timeout")
identityHook.gate.signal(); identityHook.gate.signal()
check(pump { identityHook.counts().1 == 0 }, "identity workers released")
settle(); check(identityHook.counts().0 == 3, "expired queued admissions never resolve paths")
identityMonitor.stop()

// Fault injection blocks the formal helper launch worker, without executing
// Wine. Other environment probes, admission and quit must still run.
final class BlockedWaiters {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var entered = 0, active = 0
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (entered, active) }
    func launch(_ process: Process) throws {
        lock.lock(); entered += 1; active += 1; lock.unlock()
        _ = gate.wait(timeout: .now() + 10)
        lock.lock(); active -= 1; lock.unlock()
        throw CocoaError(.executableLoad)
    }
}
let heldWaiters = BlockedWaiters(), waiterEpoch = UUID()
var waiterSnapshot = CyderLifecycle.State(epoch: waiterEpoch).snapshot
let waiterStore = CyderLifecycleStore(epoch: waiterEpoch) { value, _ in waiterSnapshot = value }
let waiterMonitor = CyderEnvironmentMonitor(epoch: waiterEpoch, directory: root.appendingPathComponent("waiter-history"),
    probe: { _ in .alive(.init(boot: "injected", pid: 456, started: 1)) }, launchWaiter: heldWaiters.launch, event: waiterStore.send)
var waiterTracked = 0
let waiterPrefixes = (1...3).map { root.appendingPathComponent("waiter-\($0)") }
for prefix in waiterPrefixes {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    waiterMonitor.track(prefix: prefix, engine: engine) { _ in waiterTracked += 1 }
}
check(pump { waiterTracked == 3 && waiterSnapshot.environments.values.filter { $0.existence == .alive }.count == 3 }, "blocked helper launch cannot block other environments")
check(pump { heldWaiters.counts().0 == 2 }, "helper spawn worker limit reached")
var responsive = false, waiterExecution: UUID?, waiterStamp: CyderLifecycle.Stamp?
Task {
    waiterExecution = await waiterMonitor.beginExecution(prefix: waiterPrefixes[2], engine: engine)
    if let waiterExecution { waiterStamp = await waiterMonitor.executionStamp(waiterExecution) }
    responsive = true
}
check(pump { responsive }, "admission and stamp remain responsive under blocked helper spawns")
check(waiterStamp != nil && heldWaiters.counts().0 == 2, "no third physical waiter spawn")
waiterMonitor.stop(); waiterStore.send(.quit)
check(pump { waiterSnapshot.phase == .quiescing }, "quit not blocked by helper spawn")
if let waiterExecution {
    var revoked = false
    Task { revoked = await waiterMonitor.executionStamp(waiterExecution) == nil }
    check(pump { revoked }, "closed monitor revokes executor stamp immediately")
}
heldWaiters.gate.signal(); heldWaiters.gate.signal()
check(pump { heldWaiters.counts().1 == 0 }, "owned helper workers drained after release")

// Let the formal worker actually spawn a trusted native helper after stop.
// Cleanup must target that Process object, never the injected server owner.
final class LateNativeHelper {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var process: Process?, launched = false
    func value() -> (Process?, Bool) { lock.lock(); defer { lock.unlock() }; return (process, launched) }
    func launch(_ process: Process) throws {
        lock.lock(); self.process = process; lock.unlock()
        _ = gate.wait(timeout: .now() + 10)
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--owned-helper"]
        try process.run()
        lock.lock(); launched = true; lock.unlock()
    }
}
let lateHelper = LateNativeHelper()
let lateMonitor = CyderEnvironmentMonitor(epoch: UUID(), directory: root.appendingPathComponent("late-helper"),
    probe: { _ in .alive(.init(boot: "injected", pid: 555, started: 1)) }, launchWaiter: lateHelper.launch, event: { _ in })
lateMonitor.track(prefix: prefix, engine: engine)
check(pump { lateHelper.value().0 != nil }, "native helper worker claimed")
lateMonitor.stop()
var stopped = false
Task { _ = await lateMonitor.executionStamp(UUID()); stopped = true }
check(pump { stopped }, "stop crosses state queue before native launch returns")
lateHelper.gate.signal()
check(pump { lateHelper.value().1 }, "late native helper actually spawned")
if lateHelper.value().1, let helper = lateHelper.value().0 {
    check(pump { !helper.isRunning }, "late owned helper terminated after stop")
    if !helper.isRunning { check(helper.terminationReason == .uncaughtSignal && helper.terminationStatus == SIGTERM, "owned helper receives expected cleanup signal") }
    else { helper.terminate() }
}
let replacedHelper = LateNativeHelper(), replacementInput = Input(), replacementEpoch = UUID()
var replacementSnapshot = CyderLifecycle.State(epoch: replacementEpoch).snapshot
let replacementStore = CyderLifecycleStore(epoch: replacementEpoch) { value, _ in replacementSnapshot = value }
let replacementMonitor = CyderEnvironmentMonitor(epoch: replacementEpoch, directory: root.appendingPathComponent("replaced-helper"),
    clock: replacementInput.time, probe: replacementInput.probe, launchWaiter: replacedHelper.launch, event: replacementStore.send)
replacementMonitor.track(prefix: prefix, engine: engine)
check(pump { replacedHelper.value().0 != nil && replacementSnapshot.environments.values.first?.existence == .alive }, "old generation helper claimed")
if let oldEnvironment = replacementSnapshot.environments.values.first {
    let oldStamp = CyderLifecycle.Stamp(epoch: replacementEpoch, environment: oldEnvironment.id, generation: oldEnvironment.generation)
    replacementInput.change { $0.now = 100; $0.result = .empty }
    replacementMonitor.reconcile(oldStamp); settle()
    replacementInput.change { $0.now = 101 }; replacementMonitor.reconcile(oldStamp)
    check(pump { replacementSnapshot.environments[oldEnvironment.id]?.existence == .exited }, "old environment drained while helper spawn held")
    var newToken: UUID?, newStamp: CyderLifecycle.Stamp?
    Task {
        newToken = await replacementMonitor.beginExecution(prefix: prefix, engine: engine)
        if let newToken { newStamp = await replacementMonitor.executionStamp(newToken) }
    }
    check(pump { newStamp != nil }, "replacement entry admitted")
    check(newStamp?.generation == oldStamp.generation + 1, "replacement gets its own generation")
    replacedHelper.gate.signal()
    check(pump { replacedHelper.value().1 }, "retired helper actually spawned late")
    if replacedHelper.value().1, let helper = replacedHelper.value().0 {
        check(pump { !helper.isRunning }, "retired entry cannot keep a late helper attached to replacement")
        if !helper.isRunning { check(helper.terminationStatus == SIGTERM, "retired helper cleaned by its own owner") }
        else { helper.terminate() }
    }
    check(replacementSnapshot.environments[oldEnvironment.id]?.generation == newStamp?.generation,
        "old helper callback cannot mutate replacement generation")
    if let newToken { replacementMonitor.endExecution(newToken) }
}
replacementMonitor.stop()
if !failures.isEmpty { failures.forEach { print("FAIL \($0)") }; exit(1) }
print("PASS formal monitor/store generation admission: two fresh empty samples, new launch survives first server discovery, old launch isolated, exact drain retained; late admission denied, helper spawn limit, responsive quit and late native helper cleanup")
