import Cocoa
import Foundation
import Darwin

if CommandLine.arguments.contains("--child") { alarm(45); while true { pause() } }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
final class CyderDiagnostics { static let shared = CyderDiagnostics(); func info(_ message: String) {} }
struct TestWindow { let pid: Int32; let ownerName: String; let windowID: UInt32 }
final class WindowProbe {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var held = false, entered = false
    func hold() { lock.lock(); held = true; entered = false; lock.unlock() }
    func hasEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func release() { lock.lock(); held = false; lock.unlock(); gate.signal() }
    func read(_ pids: Set<Int32>) -> [TestWindow] {
        lock.lock(); let wait = held; entered = true; lock.unlock()
        if wait { precondition(gate.wait(timeout: .now() + 8) == .success) }
        return pids.map { .init(pid: $0, ownerName: "Native fixture", windowID: 77) }
    }
}
let windowProbe = WindowProbe()
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] {
    precondition(!Thread.isMainThread)
    return windowProbe.read(pids)
}
func pump(_ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 8
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "binding integration deadline")
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let controller = CyderStatusItemController(); controller.setUIVisible(true)
let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [directory.path, "--child"]
try child.run()
defer { child.terminate(); child.waitUntilExit() }
var birth: CyderLifecycle.ProcessID?
DispatchQueue.global().async {
    if case .live(let node) = CyderProcessEvidence.inspect(child.processIdentifier) { DispatchQueue.main.async { birth = node.id } }
}
pump { birth != nil }
let prefix = directory.appendingPathComponent("prefix")
try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
let monitor = CyderEnvironmentMonitor(epoch: controller.lifecycleEpoch, directory: directory.appendingPathComponent("monitor"),
    waitersEnabled: false, probe: { _ in .empty }, event: controller.receiveLifecycleEvent)
var execution: UUID?, stamp: CyderLifecycle.Stamp?
Task {
    execution = await monitor.beginExecution(prefix: prefix, engine: child.executableURL!)
    if let execution { stamp = await monitor.executionStamp(execution) }
}
pump { stamp != nil }
let boundStamp = stamp!
let journal = CyderRequestJournal(directory: directory.appendingPathComponent("journal"))
var opened = false, namespace: UUID?, record: CyderRequestJournal.Record?
journal.open { if case .success = $0 { opened = true } }; pump { opened }
journal.namespace { namespace = $0 }; pump { namespace != nil }
let requestID = namespace!.uuidString + ":" + UUID().uuidString
journal.submit(id: requestID, payload: .init(files: ["/fixture.exe"], arguments: nil, urls: [], showUI: false)) {
    if case .success(let value) = $0 { record = value }
}
pump { record != nil }
precondition(record!.phase == .queued)
controller.receiveHistory([CyderRecoveryObserver.Record(record!)!])
pump { controller.lifecycleSnapshot.requests[requestID]?.phase == .queued }
record = nil
journal.authorizeDispatch(id: requestID) { if case .success(let value) = $0 { record = value } }
pump { record != nil }
let committed = record!
precondition(committed.phase == .dispatching)
controller.receiveHistory([CyderRecoveryObserver.Record(committed)!])
let authority = CyderLaunchObserver.Authority(request: committed.id, launch: committed.launchID!, digest: committed.digest, epoch: committed.executorEpoch!)
controller.beginLaunch(id: authority.launch, prefix: prefix, executableName: "Committed fixture", authority: authority, stamp: boundStamp,
    committedRequest: .init(id: committed.id, digest: committed.digest, environment: boundStamp.environment, phase: .dispatching, launch: authority.launch))
pump { controller.lifecycleSnapshot.requests[committed.id]?.phase == .observing }
precondition(controller.lifecycleSnapshot.launches.count == 1)
let identity = birth!, environment = boundStamp.environment
let scope = "\(environment.uid):\(Int64(bitPattern: environment.device)):\(environment.inode)"
let ticket = UUID()
func root(_ phase: String, scope: String) -> CyderLaunchObserver.NativeRoot {
    .init(authority: authority, ticket: ticket, phase: phase, pid: identity.pid, boot: identity.boot, started: identity.started,
          status: phase == "exited" ? 0 : nil, signalled: phase == "exited" ? false : nil, prefixScope: scope)
}
controller.attachNativeRoot(root("spawned", scope: "wrong"))
precondition(controller.nativeRootPID(id: authority.launch) == 0, "matching request cannot override actual environment scope")
let observer = CyderLaunchObserver(authority: authority), signal = WineActivationWaiter(prefix: prefix.path)
controller.onWindowConfirmed = { if $0 == authority.launch { signal.signal() } }
controller.attachNativeRoot(root("spawned", scope: scope))
observer.receive(root("spawned", scope: scope))
var outcome: CyderLaunchObserver.Result?
Task {
    outcome = await observer.wait(duration: 1, signal: signal, onStarted: {
        controller.receiveLifecycleEvent(.observationStarted(boundStamp, launch: authority.launch, deadline: $0))
    })
    controller.receiveLifecycleEvent(.observationFinished(boundStamp, launch: authority.launch,
        outcome: outcome == .activated ? .confirmedStarted : .unconfirmed))
}
pump { controller.lifecycleSnapshot.requests[committed.id]?.phase == .completed }
let snapshot = controller.lifecycleSnapshot
precondition(outcome == .activated && snapshot.launches[authority.launch]?.deadline.isFinite == true)
precondition(snapshot.processes[identity]?.launch == authority.launch && snapshot.processes[identity]?.ownership == .rootReceipt)
let window = CyderLifecycle.WindowID(process: identity, source: "coregraphics", token: "77")
precondition(snapshot.windows[window]?.capability == .unsupported, "CoreGraphics identity alone must not invent a focus capability")
let menu = NSMenu(); controller.menuNeedsUpdate(menu)
precondition(menu.items.contains { $0.title.contains("Committed fixture") && $0.title.contains("已確認程式視窗") })
windowProbe.hold(); var queried = false
controller.claimLiveWindows(id: authority.launch) { queried = true }
pump { windowProbe.hasEntered() }
var samples: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    controller.menuNeedsUpdate(menu); controller.menuWillOpen(menu); controller.menuDidClose(menu)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
precondition(!queried, "menu callbacks unexpectedly waited for window query")
windowProbe.release(); pump { queried }
let sorted = samples.sorted()
print("bound callback-cycle proxy samples=30 p95_ms=\(sorted[28]) max_ms=\(sorted[29])")
print("bound_sample,callback_cycle_ms")
for (index, sample) in samples.enumerated() { print("\(index + 1),\(sample)") }
// Genuine native exit is deliberately not asserted here: the receipt is fault
// injection while the child is alive, to exercise the actual adapter/store path.
controller.attachNativeRoot(root("exited", scope: scope))
pump { controller.lifecycleSnapshot.processes[identity]?.existence == .exited }
precondition(controller.lifecycleSnapshot.windows.isEmpty && child.isRunning)
controller.receiveLifecycleEvent(.manage(.init(id: environment, prefix: prefix.path, engine: child.executableURL!.path,
    generation: boundStamp.generation + 1)))
pump { controller.nativeRootPID(id: authority.launch) == 0 }
controller.attachNativeRoot(root("spawned", scope: scope))
precondition(controller.nativeRootPID(id: authority.launch) == 0, "late receipt cannot recreate old generation session")
var released = false
monitor.endExecution(execution!) { released = true }; pump { released }
var checkedRelease = false
Task { let value = await monitor.executionStamp(execution!); precondition(value == nil); checkedRelease = true }
pump { checkedRelease }
monitor.stop(); observer.cancel(); controller.quiesce()
var closed = false; journal.close { closed = true }; pump { closed }
precondition(child.isRunning, "quiesce must not terminate native client")
print("PASS formal journal authorization + monitor stamp + status adapter + lifecycle store + observer + menu; actual native birth, injected windows/exit, exact scope, generation retirement and no replay/kill")
