import Foundation
import Darwin
typealias L = CyderLifecycle
typealias P = CyderEnvironmentProbe
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ value: Bool, _ message: String, line: Int = #line) {
    if !value { fputs("FAIL line \(line): \(message)\n", stderr); exit(1) }
}
func pump(_ message: String, _ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 9
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), message)
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
func identity(_ n: Int) -> P.Identity {
    .init(environment: .init(uid: getuid(), device: 1, inode: UInt64(n), namespace: "wine-user"),
          prefix: "/fixture/external-prefix-\(n)", engine: "/fixture/bin/wineserver")
}
func writeHistory(_ directory: URL) throws -> Data {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let records = try (1...32).map { try JSONSerialization.jsonObject(with: JSONEncoder().encode(CyderEnvironmentMonitor.Saved(identity: identity($0), generation: 7))) }
    let data = try JSONSerialization.data(withJSONObject: ["schema":1,"records":records])
    let file = directory.appendingPathComponent("managed-environments-v1.json")
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return data
}
final class Reader {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var calls = 0, identities = 0
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    func identify(_ prefix: URL, _ engine: URL) -> P.Identity? {
        lock.lock(); identities += 1; lock.unlock()
        return identity(Int(prefix.lastPathComponent.split(separator: "-").last!)!)
    }
    func identityCount() -> Int { lock.lock(); defer { lock.unlock() }; return identities }
    func read(_ file: URL) throws -> Data? {
        check(!Thread.isMainThread, "registry read on main")
        lock.lock(); calls += 1; lock.unlock()
        check(gate.wait(timeout: .now() + 20) == .success, "test did not release reader")
        return try CyderEnvironmentMonitor.readRegistryFile(file)
    }
}
let engine = URL(fileURLWithPath: "/fixture/bin/wineserver")
let alive: (P.Identity) -> P.Result = { _ in .alive(.init(boot: "fixture", pid: 123, started: 1)) }
// Launch arrives before the explicit restore request. The one physical reader
// must finish before any new identity is admitted or the prior file is saved.
let directory = root.appendingPathComponent("merge"), reader = Reader(), epoch = UUID()
let original = try writeHistory(directory)
var snapshot = L.State(epoch: epoch).snapshot
let store = CyderLifecycleStore(epoch: epoch) { value, _ in snapshot = value }
let monitor = CyderEnvironmentMonitor(epoch: epoch, directory: directory, waitersEnabled: false,
    identify: reader.identify, probe: alive, readRegistry: reader.read, event: store.send)
var tracked = false, path: String?, restored = 0
monitor.track(prefix: URL(fileURLWithPath: identity(100).prefix), engine: engine) { path = $0; tracked = true }
pump("one lazy physical reader") { reader.count() == 1 }
for _ in 0..<10 { monitor.restore { restored += 1 } }
monitor.recoverVerified(identity(101), owner: .init(boot: "fixture", pid: 124, started: 1))
settle()
check(!tracked && snapshot.environments.isEmpty && reader.identityCount() == 0, "admitted before loading history")
check(try Data(contentsOf: directory.appendingPathComponent("managed-environments-v1.json")) == original, "overwrote unread external history")
reader.gate.signal()
pump("history reserves capacity before new admissions") { tracked && restored == 10 && snapshot.environments.count == 32 }
check(path == nil, "new prefix exceeded restored capacity")
check(snapshot.environments.values.allSatisfy { $0.generation == 8 && $0.id.inode <= 32 }, "history replaced or new entry slipped through")
check(snapshot.requests.isEmpty && snapshot.launches.isEmpty, "restoration replayed a launch")
monitor.restore { restored += 1 }
pump("repeated restore completes") { restored == 11 }
check(reader.count() == 1, "repeated restore created another reader")
monitor.stop()
print("PASS launch/recovery before restore cannot overwrite unread history or exceed 32 environments; 32 external prefixes retained; repeated restore shares one reader; no replay")

// Caller deadlines never release the underlying read slot. Overflowed and
// expired calls complete exactly once; a late reader only restores history.
let slowDirectory = root.appendingPathComponent("slow"), slowReader = Reader(), slowEpoch = UUID()
let slowOriginal = try writeHistory(slowDirectory)
var slowSnapshot = L.State(epoch: slowEpoch).snapshot
let slowStore = CyderLifecycleStore(epoch: slowEpoch) { value, _ in slowSnapshot = value }
let slow = CyderEnvironmentMonitor(epoch: slowEpoch, directory: slowDirectory, waitersEnabled: false,
    identify: slowReader.identify, probe: alive, readRegistry: slowReader.read, event: slowStore.send)
var admissionDone = false, executor: UUID?, completions = 0, successes = 0
Task { executor = await slow.beginExecution(prefix: URL(fileURLWithPath: identity(100).prefix), engine: engine); admissionDone = true }
pump("slow reader running") { slowReader.count() == 1 }
for n in 100...139 {
    slow.track(prefix: URL(fileURLWithPath: identity(n).prefix), engine: engine) { result in
        completions += 1; if result != nil { successes += 1 }
    }
}
pump("bounded queue rejects excess callers") { completions >= 9 }
check(completions < 40, "reader was not held")
pump("all blocked callers expire") { admissionDone && completions == 40 }
check(executor == nil && successes == 0 && slowReader.count() == 1 && slowReader.identityCount() == 0, "expiry spawned work or another reader")
check(try Data(contentsOf: slowDirectory.appendingPathComponent("managed-environments-v1.json")) == slowOriginal, "expired caller overwrote history")
slowReader.gate.signal()
pump("late read still restores history") { slowSnapshot.environments.count == 32 }
settle()
check(completions == 40 && slowReader.identityCount() == 0, "late read resurrected expired caller")
check(slowSnapshot.environments.values.allSatisfy { $0.id.inode <= 32 }, "expired caller created environment")
slow.stop()
print("PASS bounded pending registry jobs; five-second admission/track expiry keeps one physical read; late history cannot revive expired work")

let quitDirectory = root.appendingPathComponent("quit"), quitReader = Reader()
let quitOriginal = try writeHistory(quitDirectory)
let eventLock = NSLock(); var events = 0
let quitting = CyderEnvironmentMonitor(epoch: UUID(), directory: quitDirectory, waitersEnabled: false,
    identify: quitReader.identify, probe: alive, readRegistry: quitReader.read, event: { _ in eventLock.lock(); events += 1; eventLock.unlock() })
var quitComplete = false
quitting.track(prefix: URL(fileURLWithPath: identity(100).prefix), engine: engine) { result in check(result == nil, "quit admitted launch"); quitComplete = true }
pump("quit reader in flight") { quitReader.count() == 1 }
quitting.stop()
pump("quit releases pending caller") { quitComplete }
quitReader.gate.signal(); settle()
eventLock.lock(); let finalEvents = events; eventLock.unlock()
check(finalEvents == 0 && quitReader.identityCount() == 0, "late read after quit emitted authority")
check(try Data(contentsOf: quitDirectory.appendingPathComponent("managed-environments-v1.json")) == quitOriginal, "quit late reader overwrote history")
print("PASS quit cancels pending callers without waiting or accepting late registry authority")
// Two physical routine probes are occupied when an executor asks for the last
// sorted prefix. Releasing one slot must serve that admission before the other
// 29 routine entries, while the other probe remains physically held.
final class Probe {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var calls = 0, requestedCalls = 0
    var unknown = false
    func result(_ value: P.Identity) -> P.Result {
        lock.lock(); calls += 1; let hold = calls <= 2
        if value.environment.inode == 32 { requestedCalls += 1 }
        let missing = unknown; lock.unlock()
        if hold { check(gate.wait(timeout: .now() + 20) == .success, "probe fixture was not released") }
        return missing && value.environment.inode == 32 ? .unknown("fixture unreadable") : alive(value)
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    func requests() -> Int { lock.lock(); defer { lock.unlock() }; return requestedCalls }
    func setUnknown() { lock.lock(); unknown = true; lock.unlock() }
}
let priorityDirectory = root.appendingPathComponent("priority"), priorityProbe = Probe()
_ = try writeHistory(priorityDirectory)
let priority = CyderEnvironmentMonitor(epoch: UUID(), directory: priorityDirectory, waitersEnabled: false,
    identify: { prefix, _ in identity(Int(prefix.lastPathComponent.split(separator: "-").last!)!) },
    probe: priorityProbe.result, event: { _ in })
var priorityRestored = false, priorityDone = false, priorityExecutor: UUID?
priority.restore { priorityRestored = true }
pump("two routine probes held") { priorityRestored && priorityProbe.count() == 2 }
Task { priorityExecutor = await priority.beginExecution(prefix: URL(fileURLWithPath: identity(32).prefix), engine: engine); priorityDone = true }
settle(); priorityProbe.gate.signal()
pump("awaiting executor gets next physical slot") { priorityDone }
check(priorityExecutor != nil, "routine probe ordering exhausted admission deadline")
check(priorityProbe.requests() == 1, "healthy admission required repeated probe")
priority.endExecution(priorityExecutor!)
priorityProbe.setUnknown()
var unknownDone = false, unknownExecutor: UUID?
Task { unknownExecutor = await priority.beginExecution(prefix: URL(fileURLWithPath: identity(32).prefix), engine: engine); unknownDone = true }
let cadenceEnd = Date().addingTimeInterval(1.2)
while Date() < cadenceEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(!unknownDone && priorityProbe.requests() <= 5, "unknown admission caused a tight probe loop")
priority.stop(); priorityProbe.gate.signal()
pump("quit releases unknown admission") { unknownDone }
check(unknownExecutor == nil, "unknown evidence admitted executor")
print("PASS waiting executor gets a released physical slot ahead of routine polling; unknown retry remains bounded; quit releases pending admission")
try Data("passed".utf8).write(to: root.appendingPathComponent("passed"))
