import Cocoa
import Darwin

typealias L = CyderLifecycle
if CommandLine.arguments.contains("--child") { alarm(90); while true { pause() } }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
final class CyderDiagnostics { static let shared = CyderDiagnostics(); func info(_ message: String) {} }
struct TestWindow { let pid: Int32; let ownerName: String; let windowID: UInt32 }
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] { [] }
func pump(_ message: String, timeout: Double = 8, _ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), message)
}
func settle(_ interval: Double = 0.1) { var done = false; DispatchQueue.main.asyncAfter(deadline: .now() + interval) { done = true }; pump("settle", timeout: interval + 2) { done } }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [directory.path, "--child"]
try child.run()
defer { child.terminate(); child.waitUntilExit() }
var birth: L.ProcessID?
DispatchQueue.global().async { if case .live(let node) = CyderProcessEvidence.inspect(child.processIdentifier) { DispatchQueue.main.async { birth = node.id } } }
pump("actual native birth") { birth != nil }
let process = birth!, prefix = directory.appendingPathComponent("prefix")
try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
let oldDirectory = directory.appendingPathComponent("old-environments"), restoredDirectory = directory.appendingPathComponent("restored-environments")
try FileManager.default.createDirectory(at: restoredDirectory, withIntermediateDirectories: true)
let oldMonitor = CyderEnvironmentMonitor(epoch: UUID(), directory: oldDirectory, waitersEnabled: false, probe: { _ in .alive(process) }, event: { _ in })
var tracked = false
oldMonitor.track(prefix: prefix, engine: child.executableURL!) { tracked = $0 != nil }
let saved = oldDirectory.appendingPathComponent("managed-environments-v1.json")
pump("formal registry persisted") { tracked && FileManager.default.fileExists(atPath: saved.path) }
let bytes = try Data(contentsOf: saved)
let restoredFile = restoredDirectory.appendingPathComponent("managed-environments-v1.json")
try bytes.write(to: restoredFile); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restoredFile.path)
oldMonitor.stop()
let identity = CyderEnvironmentProbe.identify(prefix: prefix, engine: child.executableURL!)!
let journalDirectory = directory.appendingPathComponent("journal")
let firstJournal = CyderRequestJournal(directory: journalDirectory)
var opened = false, namespace: UUID?
firstJournal.open { if case .success = $0 { opened = true } }; pump("journal open") { opened }
firstJournal.namespace { namespace = $0 }; pump("namespace") { namespace != nil }
func submit(_ name: String) -> CyderRequestJournal.Record {
    var record: CyderRequestJournal.Record?
    firstJournal.submit(id: namespace!.uuidString + ":" + UUID().uuidString,
        payload: .init(files: ["/fixture/\(name).exe"], arguments: nil, urls: [], showUI: false)) {
        if case .success(let value) = $0 { record = value }
    }
    pump("submit") { record != nil }; return record!
}
let queued = submit("Queued"), initial = submit("Recovered")
var authorized: CyderRequestJournal.Record?
firstJournal.authorizeDispatch(id: initial.id) { if case .success(let value) = $0 { authorized = value } }
pump("authorized") { authorized != nil }
let committed = authorized!
let receipt = CyderRequestJournal.ExecutionReceipt(ticketID: UUID(), requestID: committed.id, launchID: committed.launchID!, epoch: committed.executorEpoch!, digest: committed.digest,
    phase: "handedOff", ownerPID: nil, ownerBoot: nil, ownerStarted: nil, childPID: nil, childBoot: nil, childStarted: nil, status: nil,
    nativeSpawn: .init(phase: "spawned", bridgePID: process.pid, bridgeBoot: process.boot, bridgeStarted: process.started,
        processPID: process.pid, processBoot: process.boot, processStarted: process.started, status: nil, signalled: nil), prefixScope: identity.executionScope)
var savedReceipt = false
firstJournal.reconcileExecutions([receipt]) { if case .success(let ids) = $0 { savedReceipt = ids == [receipt.ticketID] } }
pump("native receipt persisted") { savedReceipt }
var closed = false; firstJournal.close { closed = true }; pump("journal close") { closed }
let journal = CyderRequestJournal(directory: journalDirectory)
opened = false; journal.open { if case .success = $0 { opened = true } }; pump("journal reopen") { opened }
var records: [CyderRequestJournal.Record]?
journal.snapshot { if case .success(let value) = $0 { records = value } }; pump("recovery snapshot") { records != nil }
precondition(records!.first { $0.id == initial.id }?.phase == .uncertain && records!.first { $0.id == queued.id }?.phase == .awaitingUserResume)
let nativeAX = CyderWindowAccess.Driver(scan: { _ in .windows([]) }, equal: { $0 === $1 }, activate: { _,_,_ in fatalError("recovery must not activate") })
let controller = CyderStatusItemController(windowDriver: nativeAX); controller.setUIVisible(true)
controller.receiveLifecycleEvent(.restoring(true)); controller.receiveHistory(records!.compactMap { CyderRecoveryObserver.Record($0) })
pump("history in common store") { controller.lifecycleSnapshot.requests.count == 2 }
precondition(controller.lifecycleSnapshot.processes.isEmpty && controller.lifecycleSnapshot.launches.isEmpty, "history treated as living without calibration")
let monitor = CyderEnvironmentMonitor(epoch: controller.lifecycleEpoch, directory: restoredDirectory, expectedEngine: child.executableURL!, waitersEnabled: false,
    probe: { _ in .alive(process) }, event: controller.receiveLifecycleEvent)
var restored = false
monitor.restore { restored = true; controller.receiveLifecycleEvent(.restoring(false)) }
pump("native root restored after current calibration") { restored && controller.nativeRootPID(id: committed.launchID!) == process.pid && controller.lifecycleSnapshot.processes[process]?.existence == .alive }
let snapshot = controller.lifecycleSnapshot
precondition(snapshot.requests[initial.id]?.phase == .uncertain && snapshot.requests[queued.id]?.phase == .awaitingUserResume)
precondition(!snapshot.hasActiveWork && snapshot.launches[committed.launchID!]?.outcome == .unconfirmed, "recovery manufactured new observation/dispatch")
precondition(snapshot.processes[process]?.ownership == .rootReceipt && snapshot.processes[process]?.launch == committed.launchID)
let menu = NSMenu(); controller.menuNeedsUpdate(menu)
precondition(menu.items.contains { $0.title.contains("Recovered.exe") && $0.title.contains("尚未確認視窗") })
precondition(!menu.items.contains { $0.title.contains("正在啟動") })
var rejectedReplay = false
journal.authorizeDispatch(id: initial.id) { if case .failure(.tooLate) = $0 { rejectedReplay = true } }
pump("historical request cannot dispatch") { rejectedReplay }
let count = snapshot.launches.count
for _ in 0..<40 { controller.receiveHistory(records!.compactMap { CyderRecoveryObserver.Record($0) }) }
settle(); precondition(controller.lifecycleSnapshot.launches.count == count)
controller.quiesce(); monitor.stop(); settle()
precondition(child.isRunning, "recovery quit killed the actual native process")
print("PASS persisted journal + registry reopen, current native birth, formal controller/store/session, historical result retained, no replay/focus, duplicate coalescing, quit preserves native child; server and window data injected")

// Real native inspection rejects a prior boot and PID reuse, even when journal
// correlation and prefix are otherwise valid. No historical title is authority.
func candidate(_ id: String, birth: L.ProcessID, scope: String = identity.executionScope) -> CyderRecoveryObserver.Record {
    .init(version: 1, request: .init(id: id, digest: id, environment: nil, phase: .uncertain, launch: id), name: id,
        root: .init(authority: .init(request: id, launch: id, digest: id, epoch: UUID()), ticket: UUID(), phase: "spawned",
                    pid: birth.pid, boot: birth.boot, started: birth.started, status: nil, signalled: nil, prefixScope: scope))
}
final class NativeReads {
    let lock = NSLock(); var count = 0
    func read(_ pid: Int32) -> CyderProcessEvidence.Presence {
        let result = CyderProcessEvidence.inspect(pid)
        lock.lock(); count += 1; lock.unlock(); return result
    }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let nativeReads = NativeReads()
let invalid = CyderStatusItemController(windowDriver: nativeAX, recoveryInspect: nativeReads.read); invalid.setUIVisible(true)
invalid.receiveHistory([candidate("prior-boot", birth: .init(boot: process.boot + "-old", pid: process.pid, started: process.started)),
    candidate("reused-pid", birth: .init(boot: process.boot, pid: process.pid, started: process.started + 1))])
invalid.receiveLifecycleEvent(.manage(.init(id: identity.environment, prefix: identity.prefix, engine: identity.engine, generation: 1, existence: .alive, health: .healthy)))
pump("both invalid births actually inspected") { nativeReads.calls() == 2 }
settle(); precondition(invalid.lifecycleSnapshot.launches.isEmpty && invalid.lifecycleSnapshot.processes.isEmpty)
invalid.quiesce()
print("PASS real native birth rejects prior boot and reused numeric PID")

let ambiguousReads = NativeReads()
let ambiguous = CyderStatusItemController(windowDriver: nativeAX, recoveryInspect: ambiguousReads.read)
ambiguous.setUIVisible(true)
ambiguous.receiveHistory([candidate("claim-one", birth: process), candidate("claim-two", birth: process)])
ambiguous.receiveLifecycleEvent(.manage(.init(id: identity.environment, prefix: identity.prefix, engine: identity.engine, generation: 1, existence: .alive, health: .healthy)))
settle(0.2)
precondition(ambiguousReads.calls() == 0 && ambiguous.lifecycleSnapshot.launches.isEmpty, "conflicting journal claims guessed one owner")
ambiguous.quiesce()
print("PASS conflicting historical claims do not choose an arbitrary launch owner")

// One stalled environment cannot prevent recovery in another environment.
let mixedGate = DispatchSemaphore(value: 0), heldBirth = L.ProcessID(boot: "fixture", pid: 50001, started: 1)
let otherEnvironment = L.EnvironmentID(uid: identity.environment.uid, device: identity.environment.device, inode: identity.environment.inode + 1, namespace: "wine-user")
let otherScope = "\(otherEnvironment.uid):\(Int64(bitPattern: otherEnvironment.device)):\(otherEnvironment.inode)"
let mixed = CyderStatusItemController(windowDriver: nativeAX, recoveryInspect: { pid in
    if pid == heldBirth.pid { precondition(mixedGate.wait(timeout: .now() + 8) == .success); return .unavailable }
    return CyderProcessEvidence.inspect(pid)
})
mixed.setUIVisible(true)
mixed.receiveHistory([candidate("blocked-environment", birth: heldBirth), candidate("healthy-environment", birth: process, scope: otherScope)])
for environment in [identity.environment, otherEnvironment] {
    mixed.receiveLifecycleEvent(.manage(.init(id: environment, prefix: identity.prefix, engine: identity.engine, generation: 1, existence: .alive, health: .healthy)))
}
pump("other environment recovery is independent", timeout: 3) { mixed.nativeRootPID(id: "healthy-environment") == process.pid }
precondition(mixed.lifecycleSnapshot.launches["blocked-environment"] == nil)
mixed.quiesce(); mixedGate.signal(); settle()
print("PASS one blocked environment does not delay another native root; environment metadata injected")

final class Reader {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var count = 0
    func read(_ pid: Int32) -> CyderProcessEvidence.Presence {
        precondition(!Thread.isMainThread); lock.lock(); count += 1; lock.unlock()
        precondition(gate.wait(timeout: .now() + 12) == .success)
        return .live(.init(id: process, parent: getpid()))
    }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
// A result that started under the previous server generation is discarded;
// a newly calibrated generation must perform a new physical birth check.
let generationReader = Reader()
let generation = CyderStatusItemController(windowDriver: nativeAX, recoveryInspect: generationReader.read)
generation.setUIVisible(true)
generation.receiveHistory([candidate("generation", birth: process)])
generation.receiveLifecycleEvent(.manage(.init(id: identity.environment, prefix: identity.prefix, engine: identity.engine, generation: 1, existence: .alive, health: .healthy)))
pump("old generation reader entered") { generationReader.calls() == 1 }
generation.receiveLifecycleEvent(.manage(.init(id: identity.environment, prefix: identity.prefix, engine: identity.engine, generation: 2, existence: .alive, health: .healthy)))
pump("new generation reached store") { generation.lifecycleSnapshot.environments[identity.environment]?.generation == 2 }
generationReader.gate.signal()
pump("new generation requires new physical read") { generationReader.calls() == 2 }
precondition(generation.lifecycleSnapshot.launches.isEmpty, "old read was accepted in a new generation")
generation.quiesce(); generationReader.gate.signal(); settle()
precondition(generation.lifecycleSnapshot.launches.isEmpty)
print("PASS generation change discards late recovery and requires fresh evidence; quit cancels its replacement")

let metadata = CyderStatusItemController(windowDriver: nativeAX)
metadata.beginRecovery()
pump("metadata recovery retained initially") { metadata.lifecycleSnapshot.restoring && metadata.hasStatusItem }
let reader = Reader(), blocked = CyderStatusItemController(windowDriver: nativeAX, recoveryInspect: reader.read)
blocked.setUIVisible(true)
blocked.receiveHistory((1...20).map { candidate("held-\($0)", birth: .init(boot: process.boot, pid: process.pid + Int32($0), started: process.started)) })
blocked.receiveLifecycleEvent(.manage(.init(id: identity.environment, prefix: identity.prefix, engine: identity.engine, generation: 1, existence: .alive, health: .healthy)))
pump("two physical recovery reads") { reader.calls() == 2 }
settle(5.2)
precondition(!metadata.lifecycleSnapshot.restoring && !metadata.hasStatusItem, "absent metadata completion retained closed UI forever")
metadata.quiesce()
let blockedMenu = NSMenu(); var samples: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    blocked.menuNeedsUpdate(blockedMenu); blocked.menuWillOpen(blockedMenu); blocked.menuDidClose(blockedMenu)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
precondition(reader.calls() == 2 && blocked.lifecycleSnapshot.launches.isEmpty)
blocked.quiesce(); reader.gate.signal(); reader.gate.signal(); settle()
precondition(reader.calls() == 2 && blocked.lifecycleSnapshot.launches.isEmpty, "late recovery or queued read survived quit")
print("recovery callback-cycle proxy samples=30 p95_ms=\(samples.sorted()[28]) max_ms=\(samples.max()!)")
print("recovery_sample,callback_cycle_ms")
for (i, sample) in samples.enumerated() { print("\(i + 1),\(sample)") }
print("PASS blocked recovery retains physical slots and permits menus/quit; no late restoration")
closed = false; journal.close { closed = true }; pump("final journal close") { closed }
