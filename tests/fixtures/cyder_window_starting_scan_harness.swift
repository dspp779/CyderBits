import Foundation
// The progress panel closes when the first window of a starting launch is
// seen. A 2 s window scan closed it 0.7-1.1 s late; while a launch is still
// starting the window list is read every 0.5 s, and back to 2 s afterwards.
typealias L = CyderLifecycle
final class Counter { let lock = NSLock(); var value = 0
    func hit() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value } }
let reads = Counter()
var driver = CyderWindowAccess.Driver(scan: { _ in .unavailable(.unsupported) }, equal: { $0 === $1 },
                                      activate: { _, _, _ in .unconfirmed })
driver.readSurfaces = { _ in reads.hit(); return [:] }
driver.requestPermission = {}
let access = CyderWindowAccess(driver: driver) { _ in }
let env = L.EnvironmentID(uid: 501, device: 1, inode: 2, namespace: "test")
var state = L.State()
var managed = L.Environment(id: env, prefix: "/isolated/2", engine: "/fixture/engine", generation: 1)
managed.existence = .alive; managed.health = .healthy
state.reduce(.manage(managed))
let stamp = state.stamp(for: env)!
state.reduce(.accepted(.init(id: "r", digest: "r", environment: env, phase: .queued)))
state.reduce(.dispatchCommitted(stamp, request: "r", launch: .init(id: "r", request: "r", environment: env, name: "Game", deadline: 30)))
let root = L.ProcessID(boot: "boot", pid: 4242, started: 1)
state.reduce(.processObserved(stamp, .init(id: root, name: "Game", environment: env, launch: "r", ownership: .rootReceipt, existence: .alive)))
precondition(state.snapshot.launches["r"]?.outcome == nil, "fixture launch must be starting")
access.update(state.snapshot)
Thread.sleep(forTimeInterval: 2.2)
let starting = reads.read()
precondition(starting >= 3, "a starting launch must be scanned about every 0.5 s (reads in 2.2 s: \(starting))")
state.reduce(.observationFinished(stamp, launch: "r", outcome: .confirmedStarted))
precondition(state.snapshot.launches["r"]?.outcome != nil)
access.update(state.snapshot)
Thread.sleep(forTimeInterval: 0.3)
let settled = reads.read()
Thread.sleep(forTimeInterval: 1.6)
precondition(reads.read() - settled <= 1, "after the launch settles the scan returns to 2 s (extra reads: \(reads.read() - settled))")
access.stop()
// Process discovery: a launcher's child or a .NET host is found only by the
// inventory scan, normally every 3 s. While a launch starts: every second.
let inventory = Counter()
let scanner = CyderIndependentProcesses(driver: .init(pids: { inventory.hit(); return [] },
    read: { _, _ in .init(presence: .absent, match: nil) }, observeExits: false)) { _ in }
var wineState = L.State()
let wineEnv = L.EnvironmentID(uid: 501, device: 1, inode: 3, namespace: "wine-user")
var wineManaged = L.Environment(id: wineEnv, prefix: "/isolated/3", engine: "/fixture/engine", generation: 1)
wineManaged.existence = .alive; wineManaged.health = .healthy
wineState.reduce(.manage(wineManaged))
let wineStamp = wineState.stamp(for: wineEnv)!
wineState.reduce(.accepted(.init(id: "w", digest: "w", environment: wineEnv, phase: .queued)))
wineState.reduce(.dispatchCommitted(wineStamp, request: "w", launch: .init(id: "w", request: "w", environment: wineEnv, name: "BlueLauncher", deadline: 30)))
scanner.update(wineState.snapshot)
Thread.sleep(forTimeInterval: 2.6)
let startingScans = inventory.read()
precondition(startingScans >= 3, "a starting launch must rescan processes every second (scans in 2.6 s: \(startingScans))")
scanner.stop()
print("PASS starting launch: windows every 0.5 s (\(starting) reads in 2.2 s), processes every 1 s (\(startingScans) scans in 2.6 s); settled launch back to 2 s")
