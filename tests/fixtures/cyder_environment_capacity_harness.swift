import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
typealias L = CyderLifecycle
typealias P = CyderEnvironmentProbe
func pump(line: Int = #line, _ condition: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    if !condition() { fputs("FAIL capacity deadline at line \(line)\n", stderr); exit(1) }
}
final class Input {
    let lock = NSLock()
    var now: TimeInterval = 100
    var empty: Set<L.EnvironmentID> = []
    func time() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func change(_ work: (Input) -> Void) { lock.lock(); defer { lock.unlock() }; work(self) }
    func probe(_ identity: P.Identity) -> P.Result {
        precondition(!Thread.isMainThread)
        lock.lock(); defer { lock.unlock() }
        return empty.contains(identity.environment) ? .empty : .alive(.init(boot: "capacity", pid: 123, started: 1))
    }
}
func identity(_ number: Int) -> P.Identity {
    .init(environment: .init(uid: getuid(), device: 1, inode: UInt64(number), namespace: "wine-user"),
          prefix: root.appendingPathComponent("prefix-\(number)").path, engine: "/fixture/bin/wineserver")
}
let input = Input(), epoch = UUID()
var snapshot = L.State(epoch: epoch).snapshot
let store = CyderLifecycleStore(epoch: epoch) { value, _ in snapshot = value }
let monitor = CyderEnvironmentMonitor(epoch: epoch, directory: root, waitersEnabled: false,
    clock: input.time, identify: { prefix, _ in identity(Int(prefix.lastPathComponent.split(separator: "-").last!)!) },
    probe: input.probe, event: store.send)
func barrier() {
    var completed = false
    monitor.finishRecovery { completed = true }
    pump { completed }
    let target = !snapshot.visibleUI
    store.send(.visibleUI(target))
    pump { snapshot.visibleUI == target }
}
func recover(_ number: Int, birth: UInt64 = 1) {
    let item = identity(number)
    monitor.recoverVerified(item, owner: .init(boot: "capacity", pid: 123, started: birth), observedAt: input.time())
    barrier()
}
func track(_ number: Int) -> String? {
    var complete = false, result: String?
    monitor.track(prefix: URL(fileURLWithPath: identity(number).prefix), engine: URL(fileURLWithPath: "/fixture/bin/wineserver")) {
        result = $0; complete = true
    }
    pump { complete }; barrier(); return result
}
func retire(_ number: Int) {
    let item = snapshot.environments[identity(number).environment]!
    let stamp = L.Stamp(epoch: epoch, environment: item.id, generation: item.generation)
    input.change { $0.empty.insert(item.id); $0.now += 40 }
    monitor.reconcile(stamp)
    pump { snapshot.environments[item.id]?.existence == .unconfirmed }
    input.change { $0.now += 1 }
    monitor.reconcile(stamp)
    pump { snapshot.environments[item.id]?.existence == .exited }
}
// Real monitor + reducer, synthetic identities/server proofs and controlled clock.
// No Wine binary, window or process is launched.
for number in 1...33 {
    recover(number)
    pump { snapshot.environments[identity(number).environment]?.existence == .alive }
    retire(number)
}
precondition(snapshot.environments.count == 33)
precondition(track(100) != nil, "retired history consumed a live slot")
pump { snapshot.environments[identity(100).environment]?.existence == .alive }
for number in 101...131 { recover(number) }
pump { snapshot.environments.values.filter { $0.existence != .exited }.count == 32 }
let originalGeneration = snapshot.environments[identity(1).environment]!.generation
input.change { $0.empty.remove(identity(1).environment); $0.now += 1 }
recover(1, birth: 2)
precondition(snapshot.environments[identity(1).environment]!.existence == .exited,
             "verified recovery bypassed capacity for retired prefix")
precondition(track(1) == nil, "track bypassed capacity for retired prefix")
precondition(track(200) == nil, "new prefix bypassed capacity")
precondition(track(100) != nil, "existing active prefix consumed another slot")
retire(100)
precondition(track(1) != nil, "released slot was not reusable")
pump { snapshot.environments[identity(1).environment]?.generation == originalGeneration + 1 }
precondition(snapshot.environments[identity(1).environment]!.generation == originalGeneration + 1,
             "retired generation fence was lost")
precondition(snapshot.environments.values.filter { $0.existence != .exited }.count == 32)
retire(101)
input.change { $0.empty.remove(identity(2).environment); $0.now += 1 }
recover(2, birth: 2)
pump { snapshot.environments[identity(2).environment]?.existence == .alive }
precondition(snapshot.environments[identity(2).environment]!.generation == 2)
precondition(snapshot.environments.values.filter { $0.existence != .exited }.count == 32)
let registry = root.appendingPathComponent("managed-environments-v1.json")
pump {
    guard let bytes = try? Data(contentsOf: registry),
          let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          let records = json["records"] as? [[String: Any]] else { return false }
    return records.count == 32 && records.contains { ($0["generation"] as? Int) == 2 }
}
monitor.stop()
print("PASS active capacity: 33 retired environments do not consume slots; new/recovered/retired admissions share 32-slot limit; existing active track coalesces; released slot preserves generation; registry stays bounded")
try Data("passed".utf8).write(to: root.appendingPathComponent("passed"))
