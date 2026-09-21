import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let engine = URL(fileURLWithPath: CommandLine.arguments[0])
func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "drain integration deadline")
}
func settle() { var done = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done = true }; pump { done } }
final class Input {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var now: TimeInterval = 0
    var result = CyderEnvironmentProbe.Result.alive(.init(boot: "injected", pid: 123, started: 1))
    var blockNext = false, blocked = false
    var count = 0
    func change(_ body: (Input) -> Void) { lock.lock(); body(self); lock.unlock() }
    func time() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func isBlocked() -> Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func probe(_ identity: CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result {
        precondition(!Thread.isMainThread)
        lock.lock(); let value = result, block = blockNext; blockNext = false; blocked = block; count += 1; lock.unlock()
        if block { precondition(gate.wait(timeout: .now() + 5) == .success) }
        return value
    }
}
final class Fixture {
    let input = Input(), epoch = UUID(), authority: CyderLaunchObserver.Authority
    let prefix: URL, identity: CyderEnvironmentProbe.Identity, observer: CyderLaunchObserver
    var monitor: CyderEnvironmentMonitor!
    var token: UUID!, generation: UInt64 = 1, result: CyderLaunchObserver.Result?, completions = 0
    var confirmed = false, exited = false
    init(_ name: String, realProbe: Bool = false) throws {
        prefix = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        identity = CyderEnvironmentProbe.identify(prefix: prefix, engine: engine)!
        authority = .init(request: name, launch: name, digest: "fixture", epoch: epoch)
        observer = CyderLaunchObserver(authority: authority)
        monitor = CyderEnvironmentMonitor(epoch: epoch, directory: root.appendingPathComponent(name + "-history"),
            waitersEnabled: false, clock: input.time,
            probe: { [input] identity in realProbe ? CyderEnvironmentProbe.inspect(identity) : input.probe(identity) },
            event: { [weak self] event in
                DispatchQueue.main.async {
                    if case .manage(let environment) = event { self?.generation = environment.generation }
                    if case .reconciled(_, _, .exited, _) = event { self?.exited = true }
                }
            })
        Task { token = await monitor.beginExecution(prefix: prefix, engine: engine, drained: { [weak self] scope in
            self?.observer.receiveEnvironmentEnded(prefixScope: scope)
        }) }
        pump { self.token != nil }
        observer.observeDrain { [weak self] scope in
            guard let self else { return }
            self.monitor.confirmRootExit(self.token, prefixScope: scope)
            DispatchQueue.main.async { self.confirmed = true }
        }
    }
    func rootExit(scope: String? = nil) {
        observer.receive(.init(authority: authority, ticket: UUID(), phase: "exited", pid: 1234, boot: "injected", started: 100,
            status: 0, signalled: false, prefixScope: scope ?? identity.executionScope))
        pump { self.confirmed }; settle()
    }
    func wait(_ duration: TimeInterval = 2) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        Task {
            let value = await observer.wait(until: deadline, signal: WineActivationWaiter(prefix: prefix.path))
            result = value; completions += 1
        }
    }
    func release() { var done = false; monitor.endExecution(token) { done = true }; pump { done }; settle() }
    func sample(_ time: TimeInterval) {
        input.change { $0.now = time }
        monitor.reconcile(.init(epoch: epoch, environment: identity.environment, generation: generation)); settle()
    }
    func stop() { monitor.cancelDrainObservation(token); monitor.stop(); observer.cancel() }
}
// A blocked pre-release empty sample is captured while the executor can still
// spawn. It must not count toward the two fresh post-release samples.
let clean = try Fixture("clean")
clean.wait(); clean.rootExit()
clean.input.change { $0.result = .empty }; clean.sample(100); clean.sample(101)
precondition(clean.result == nil && !clean.exited, "root zero released a still-owned executor")
clean.input.change { $0.result = .alive(.init(boot: "injected", pid: 123, started: 1)) }; clean.sample(102)
clean.input.change { $0.result = .empty; $0.blockNext = true }
clean.monitor.reconcile(.init(epoch: clean.epoch, environment: clean.identity.environment, generation: clean.generation))
pump { clean.input.isBlocked() }
clean.release()
clean.input.change { $0.result = .alive(.init(boot: "injected", pid: 123, started: 1)) }
clean.input.gate.signal(); settle()
precondition(clean.result == nil, "old empty sample completed a live successor")
clean.input.change { $0.result = .empty }
clean.sample(103)
precondition(clean.result == nil, "one fresh sample completed observation")
// A repeated track is read-only observation, not another thirty-second grace.
var retracked = false
clean.monitor.track(prefix: clean.prefix, engine: engine) { _ in retracked = true }
pump { retracked }
clean.input.change { $0.result = .alive(.init(boot: "injected", pid: 123, started: 1)) }
clean.sample(103.6)
precondition(clean.result == nil, "late live successor was discarded")
clean.input.change { $0.result = .empty }; clean.sample(104)
precondition(clean.result == nil, "live successor did not reset empty calibration")
clean.sample(104.6)
pump { clean.result != nil }; precondition(clean.result == .finishedWithoutWindow && clean.exited)
clean.observer.receiveEnvironmentEnded(prefixScope: clean.identity.executionScope); clean.stop(); settle()
precondition(clean.completions == 1)

let wrong = try Fixture("wrong-scope")
wrong.wait(0.5); wrong.rootExit(scope: "wrong:device:inode"); wrong.release()
wrong.input.change { $0.result = .empty }; wrong.sample(31); wrong.sample(32)
pump { wrong.result != nil }; precondition(wrong.result == .unconfirmed, "wrong native prefix completed launch")
wrong.stop()

let generation = try Fixture("generation")
generation.wait(0.6); generation.rootExit(); generation.release()
generation.input.change { $0.result = .alive(.init(boot: "injected", pid: 123, started: 2)) }
generation.sample(0); precondition(generation.generation == 2)
generation.input.change { $0.result = .empty }; generation.sample(31); generation.sample(32)
pump { generation.result != nil }; precondition(generation.result == .unconfirmed, "old generation drained new server")
generation.stop()

// The production probe, with real directory identities and an absent isolated
// namespace, refuses an old prefix after its pathname is replaced.
let replaced = try Fixture("replaced", realProbe: true)
replaced.wait(0.5)
try FileManager.default.moveItem(at: replaced.prefix, to: replaced.prefix.appendingPathExtension("old"))
try FileManager.default.createDirectory(at: replaced.prefix, withIntermediateDirectories: true)
precondition(CyderEnvironmentProbe.identify(prefix: replaced.prefix, engine: engine)!.executionScope != replaced.identity.executionScope)
replaced.rootExit(); replaced.release(); replaced.sample(31); replaced.sample(32)
pump { replaced.result != nil }; precondition(replaced.result == .unconfirmed && !replaced.exited)
replaced.stop()

let cancelled = try Fixture("cancelled")
cancelled.wait(); cancelled.rootExit(); cancelled.release(); cancelled.stop()
cancelled.input.change { $0.result = .empty }; cancelled.sample(31); cancelled.sample(32)
pump { cancelled.result != nil }; precondition(cancelled.result == .unconfirmed && cancelled.completions == 1)
print("PASS formal monitor/observer drain: root zero + executor release + two fresh empty probes; old blocked sample, live successor, repeat track, exact prefix, server generation, real prefix replacement, cancel and once-only completion")
