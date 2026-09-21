import Cocoa
import Foundation
import Darwin
if CommandLine.arguments.contains("--child") { alarm(30); while true { pause() } }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
final class CyderDiagnostics { static let shared = CyderDiagnostics(); func info(_ message: String) {} }
struct TestWindow { let pid: Int32; let ownerName: String }
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
final class Windows {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var visible: Set<Int32> = [], blocked = false, entered = false
    func set(_ value: Set<Int32>) { lock.lock(); visible = value; lock.unlock() }
    func hold() { lock.lock(); blocked = true; entered = false; lock.unlock() }
    func started() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func release() { lock.lock(); blocked = false; lock.unlock(); gate.signal() }
    func read(_ pids: Set<Int32>) -> [TestWindow] {
        precondition(!Thread.isMainThread)
        lock.lock(); let result = visible.intersection(pids); let wait = blocked; entered = true; lock.unlock()
        if wait { precondition(gate.wait(timeout: .now() + 8) == .success) }
        return result.map { .init(pid: $0, ownerName: "Fixture") }
    }
}
let windows = Windows()
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] { windows.read(pids) }
func pump(_ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 8
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "native menu callback deadline")
}
func settle() { var done = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done = true }; pump { done } }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let controller = CyderStatusItemController()
controller.setUIVisible(true)
let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [root.path, "--child"]
try child.run()
defer { child.terminate(); child.waitUntilExit() }
var node: CyderProcessEvidence.Node?
DispatchQueue.global().async { if case .live(let value) = CyderProcessEvidence.inspect(child.processIdentifier) { DispatchQueue.main.async { node = value } } }
pump { node != nil }
let identity = node!.id
let authority = CyderLaunchObserver.Authority(request: "request", launch: "launch", digest: "digest", epoch: UUID())
let ticket = UUID(), scope = "501:11:22"
func receipt(_ phase: String = "spawned", a: CyderLaunchObserver.Authority = authority, started: UInt64? = nil) -> CyderLaunchObserver.NativeRoot {
    .init(authority: a, ticket: ticket, phase: phase, pid: identity.pid, boot: identity.boot, started: started ?? identity.started,
        status: phase == "exited" ? 0 : nil, signalled: phase == "exited" ? false : nil, prefixScope: scope)
}
var confirmations: [String] = []
controller.onWindowConfirmed = { confirmations.append($0) }
controller.beginLaunch(id: authority.launch, prefix: root, executableName: "Fixture", authority: authority)
controller.adoptWindowedProcess(pid: identity.pid, prefix: root.path, name: "unproven")
settle(); precondition(confirmations.isEmpty && !controller.hasLiveWatchedPIDs(id: authority.launch))
let wrong = CyderLaunchObserver.Authority(request: "wrong", launch: authority.launch, digest: authority.digest, epoch: authority.epoch)
controller.attachNativeRoot(receipt(a: wrong)); settle()
precondition(controller.nativeRootPID(id: authority.launch) == 0)
controller.attachNativeRoot(receipt()); pump { controller.hasLiveWatchedPIDs(id: authority.launch) }
precondition(confirmations.isEmpty, "process alone was treated as a window")
// A receipt for a reused numeric PID cannot remove the actual root.
controller.attachNativeRoot(receipt("exited", started: identity.started + 1)); settle()
precondition(controller.hasLiveWatchedPIDs(id: authority.launch))
// Same prefix, separate accepted request: one native root cannot satisfy both.
let second = CyderLaunchObserver.Authority(request: "second", launch: "second", digest: "second", epoch: authority.epoch)
controller.beginLaunch(id: second.launch, prefix: root, executableName: "Other", authority: second)
windows.set([identity.pid])
controller.adoptWindowedProcess(pid: identity.pid, prefix: root.path, name: "Fixture")
pump { !confirmations.isEmpty }
precondition(Set(confirmations) == [authority.launch] && !controller.hasClaimedWindow(id: second.launch))
controller.endLaunch(id: second.launch)
// Prepare an old window snapshot, then deliver authoritative native exit while
// the physical query is held. The old snapshot cannot resurrect this birth.
windows.hold(); var finished = false
controller.claimLiveWindows(id: authority.launch) { finished = true }
pump { windows.started() }
controller.attachNativeRoot(receipt("exited"))
let beforeRelease = confirmations.count
windows.release(); pump { finished }; settle()
precondition(!controller.hasLiveWatchedPIDs(id: authority.launch) && confirmations.count == beforeRelease)
precondition(child.isRunning, "observation cleanup killed the controlled native child")
// A past environment at the same path cannot remove a new prefix identity.
let newAuthority = CyderLaunchObserver.Authority(request: "fresh", launch: "fresh", digest: "fresh", epoch: authority.epoch)
controller.beginLaunch(id: newAuthority.launch, prefix: root, executableName: "Fresh", authority: newAuthority)
let fresh = CyderLaunchObserver.NativeRoot(authority: newAuthority, ticket: UUID(), phase: "spawned", pid: identity.pid,
    boot: identity.boot, started: identity.started, status: nil, signalled: nil, prefixScope: "501:11:23")
controller.attachNativeRoot(fresh)
let oldEnvironment = CyderLifecycle.EnvironmentID(uid: 501, device: 11, inode: 22, namespace: "wine-user")
let stamp = CyderLifecycle.Stamp(epoch: controller.lifecycleEpoch, environment: oldEnvironment, generation: 1), token = UUID()
controller.receiveLifecycleEvent(.manage(.init(id: oldEnvironment, prefix: root.path, engine: "/fixture", generation: 1)))
controller.receiveLifecycleEvent(.reconcileStarted(stamp, token))
controller.receiveLifecycleEvent(.reconciled(stamp, token, .exited, .healthy))
settle(); precondition(controller.nativeRootPID(id: newAuthority.launch) == identity.pid, "old environment path removed new prefix identity")
controller.quiesce(); controller.endLaunch(id: newAuthority.launch); settle()
print("PASS formal native menu: exact receipt authority/birth, process is not window, same-prefix requests stay distinct, late pre-exit window rejected, environment inode isolation, no child termination")
