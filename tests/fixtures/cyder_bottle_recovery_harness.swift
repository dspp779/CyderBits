import Foundation
import Darwin

typealias L = CyderLifecycle
typealias Recovery = CyderBottleRecovery
func pump(_ message: String, timeout: Double = 8, _ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), message)
}
func settle(_ seconds: Double = 0.1) {
    var ready = false; DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { ready = true }
    pump("settle", timeout: seconds + 2) { ready }
}
func background<T>(_ body: @escaping () -> T) -> T {
    var value: T?; DispatchQueue.global().async { let result = body(); DispatchQueue.main.async { value = result } }
    pump("background result") { value != nil }; return value!
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let bottles = root.appendingPathComponent("bottles")
try fm.createDirectory(at: bottles, withIntermediateDirectories: true)
func bottle(_ name: String) throws -> URL {
    let prefix = bottles.appendingPathComponent(name)
    try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    try Data().write(to: prefix.appendingPathComponent("user.reg"))
    try Data().write(to: prefix.appendingPathComponent("system.reg"))
    return prefix
}
let active = try bottle("active"), inactive = try bottle("inactive"), writable = try bottle("writable"), damaged = try bottle("damaged")
try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
try fm.removeItem(at: damaged.appendingPathComponent("user.reg"))
try fm.createSymbolicLink(at: bottles.appendingPathComponent("linked"), withDestinationURL: active)
let engine = root.appendingPathComponent("engine/bin/wineserver")
try fm.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data().write(to: engine); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
let identity = CyderEnvironmentProbe.identify(prefix: active, engine: engine)!
let owner = L.ProcessID(boot: "injected-server", pid: 45678, started: 1)
let candidates = background { Recovery.candidates(support: root) }
precondition(Set(candidates.map { $0.url.lastPathComponent }) == ["active", "inactive"])
let alias = root.appendingPathComponent("linked-support")
try fm.createSymbolicLink(at: alias, withDestinationURL: root)
precondition(background { Recovery.candidates(support: alias).isEmpty })
let idleCandidate = candidates.first { $0.url.lastPathComponent == "inactive" }!
precondition(background { Recovery.inspect(idleCandidate, engine: engine) == nil }, "readonly native empty namespace became a live environment")
print("PASS actual bounded directory inventory rejects symlinks, writable directories and incomplete prefix layouts")

// Installed but idle bottles do not consume the monitor's 32 live-scope
// allowance, and must not hide a later candidate during directory discovery.
for index in 0..<40 { _ = try bottle("idle-\(index)") }
let manyCandidates = background { Recovery.candidates(support: root) }
precondition(manyCandidates.count == 42 && manyCandidates.contains { $0.url.lastPathComponent == "active" })
print("PASS more than 32 installed bottles remain candidates; idle directories do not truncate discovery")

let registry = root.appendingPathComponent("managed-environments-v1.json"), corrupt = Data("corrupt journal: preserve me".utf8)
try corrupt.write(to: registry); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
var snapshot: L.Snapshot?
let epoch = UUID()
let model = CyderLifecycleStore(epoch: epoch) { value,_ in snapshot = value }
let probe: (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result = { candidate in
    candidate.environment == identity.environment ? .alive(owner) : .empty
}
let monitor = CyderEnvironmentMonitor(epoch: epoch, directory: root, expectedEngine: engine, waitersEnabled: false, probe: probe, event: model.send)
var restored = false, issue = false
monitor.onIssue = { _ in issue = true }
monitor.restore { restored = true }
pump("corrupt registry read completes") { restored && issue }
precondition(snapshot?.environments.isEmpty ?? true)
var finished = false
let recovery = Recovery(support: root, engine: engine, probe: probe, recovered: monitor.recoverVerified)
recovery.refresh { monitor.finishRecovery { finished = true } }
pump("missing registry supplemented by current alive proof") { finished && snapshot?.environments[identity.environment]?.existence == .alive }
precondition(snapshot?.environments.count == 1 && snapshot?.launches.isEmpty == true && snapshot?.requests.isEmpty == true)
let retained = try Data(contentsOf: registry)
precondition(retained == corrupt, "corrupt history was overwritten")
let generation = snapshot!.environments[identity.environment]!.generation
monitor.recoverVerified(identity, owner: .init(boot: "wrong", pid: 45679, started: 2))
settle(); precondition(snapshot!.environments[identity.environment]!.generation == generation)
recovery.stop(); monitor.stop()
print("PASS formal directory → readonly probe → monitor → store restores only alive environment, no launch/replay; corrupt registry retained, existing generation not overwritten (server proof injected)")

// An explicit request may have installed a live execution before disk restore
// finishes. Historical generation numbers cannot replace that current entry.
let raceDirectory = root.appendingPathComponent("race-history")
var raceSnapshot: L.Snapshot?
let raceEpoch = UUID()
let raceModel = CyderLifecycleStore(epoch: raceEpoch) { value,_ in raceSnapshot = value }
let raceMonitor = CyderEnvironmentMonitor(epoch: raceEpoch, directory: raceDirectory, expectedEngine: engine,
    waitersEnabled: false, probe: probe, event: raceModel.send)
var tracked = false
raceMonitor.track(prefix: active, engine: engine) { tracked = $0 != nil }
let raceRegistry = raceDirectory.appendingPathComponent("managed-environments-v1.json")
pump("live entry persisted") { tracked && raceSnapshot?.environments[identity.environment]?.existence == .alive && fm.fileExists(atPath: raceRegistry.path) }
let beforeGeneration = raceSnapshot!.environments[identity.environment]!.generation
let saved = CyderEnvironmentMonitor.Saved(identity: identity, generation: 99)
let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
try JSONSerialization.data(withJSONObject: ["schema":1,"records":[record]]).write(to: raceRegistry)
var raceRestored = false; raceMonitor.restore { raceRestored = true }
pump("late history restored") { raceRestored }; settle()
precondition(raceSnapshot!.environments[identity.environment]!.generation == beforeGeneration)
raceMonitor.stop()
print("PASS late disk restoration cannot replace a current live environment with a historical generation")

let otherIdentity = CyderEnvironmentProbe.identify(prefix: inactive, engine: engine)!
let oneGate = DispatchSemaphore(value: 0); var otherRecovered = false
let partial = Recovery(enumerate: { candidates }, inspect: { candidate in
    if candidate.url.lastPathComponent == "active" {
        precondition(oneGate.wait(timeout: .now() + 8) == .success); return (identity, owner)
    }
    return (otherIdentity, owner)
}, recovered: { value,_,_ in DispatchQueue.main.async { otherRecovered = value.environment == otherIdentity.environment } })
partial.refresh(); pump("one slow prefix permits another recovery", timeout: 3) { otherRecovered }
partial.stop(); oneGate.signal(); settle()
print("PASS a stalled candidate does not prevent another bottle's recovery; late result rejected after stop")

final class Calibration {
    let lock = NSLock(); var now: Double = 100; var empty = false; var server = owner
    func time() -> Double { lock.lock(); defer { lock.unlock() }; return now }
    func update(_ now: Double, empty: Bool) { lock.lock(); self.now = now; self.empty = empty; lock.unlock() }
    func replaceOwner(_ owner: L.ProcessID) { lock.lock(); server = owner; lock.unlock() }
    func read(_ identity: CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result {
        lock.lock(); defer { lock.unlock() }; return empty ? .empty : .alive(server)
    }
}
let calibration = Calibration(), retiredEpoch = UUID()
var retiredSnapshot: L.Snapshot?
let retiredStore = CyderLifecycleStore(epoch: retiredEpoch) { value,_ in retiredSnapshot = value }
let retiredMonitor = CyderEnvironmentMonitor(epoch: retiredEpoch, directory: root.appendingPathComponent("retired-history"),
    waitersEnabled: false, clock: calibration.time, probe: calibration.read, event: retiredStore.send)
retiredMonitor.track(prefix: active, engine: engine)
pump("initial server observed") { retiredSnapshot?.environments[identity.environment]?.existence == .alive }
calibration.update(200, empty: true)
pump("first empty sample") { retiredSnapshot?.environments[identity.environment]?.existence == .unconfirmed }
calibration.update(201, empty: true)
pump("environment retired") { retiredSnapshot?.environments[identity.environment]?.existence == .exited }
let newOwner = L.ProcessID(boot: owner.boot, pid: owner.pid + 1, started: 2)
retiredMonitor.recoverVerified(identity, owner: newOwner, observedAt: 199)
settle(); precondition(retiredSnapshot?.environments[identity.environment]?.existence == .exited, "pre-retirement evidence resurrected an environment")
calibration.replaceOwner(newOwner); calibration.update(202, empty: false)
retiredMonitor.recoverVerified(identity, owner: newOwner, observedAt: 202)
pump("fresh post-retirement evidence creates next generation") {
    retiredSnapshot?.environments[identity.environment]?.existence == .alive && retiredSnapshot?.environments[identity.environment]?.generation == 2
}
retiredMonitor.stop()
print("PASS explicit recheck can restore a new server after retirement; evidence begun before retirement cannot resurrect it")

// The captured directory identity cannot authorize a replacement at the same path.
let oldCandidate = candidates.first { $0.url.lastPathComponent == "active" }!
try fm.moveItem(at: active, to: bottles.appendingPathComponent("retired")); _ = try bottle("active")
let replaced = CyderEnvironmentProbe.identify(prefix: active, engine: engine)!
precondition(oldCandidate.inode != replaced.environment.inode)
var replacementClaimed = false
let replacement = Recovery(enumerate: { [oldCandidate] }, inspect: { candidate in
    Recovery.inspect(candidate, engine: engine, probe: { _ in .alive(owner) })
}, recovered: { _,_,_ in replacementClaimed = true })
finished = false; replacement.refresh { finished = true }; pump("replacement scan") { finished }
precondition(!replacementClaimed); replacement.stop()
print("PASS prior directory identity cannot recognize a replacement prefix")

final class Reads {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var count = 0
    func read(_ candidate: Recovery.Candidate) -> (CyderEnvironmentProbe.Identity, L.ProcessID)? {
        lock.lock(); count += 1; lock.unlock()
        precondition(gate.wait(timeout: .now() + 12) == .success)
        return (identity, owner)
    }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let reads = Reads(); var claims = 0
let blocked = Recovery(enumerate: { Array(repeating: oldCandidate, count: 50) }, inspect: reads.read, recovered: { _,_,_ in claims += 1 })
finished = false; blocked.refresh { finished = true }; pump("two physical candidate reads") { reads.calls() == 2 }
for _ in 0..<30 { blocked.refresh() }
settle(5.2)
precondition(finished && reads.calls() == 2 && claims == 0)
blocked.stop(); reads.gate.signal(); reads.gate.signal(); settle()
precondition(reads.calls() == 2 && claims == 0)
let inventoryGate = DispatchSemaphore(value: 0); var inventoryCalls = 0
let stuckInventory = Recovery(enumerate: {
    inventoryCalls += 1; precondition(inventoryGate.wait(timeout: .now() + 12) == .success); return [oldCandidate]
}, inspect: { _ in (identity, owner) }, recovered: { _,_,_ in claims += 1 })
finished = false; stuckInventory.refresh { finished = true }
pump("inventory timeout completion", timeout: 6) { finished }
stuckInventory.stop(); inventoryGate.signal(); settle()
precondition(inventoryCalls == 1 && claims == 0)
print("PASS two held physical candidate reads do not multiply after expiry/recheck; bounded inventory completion; quit rejects late results")
try "passed\n".write(to: root.appendingPathComponent("passed"), atomically: true, encoding: .utf8)
