import Cocoa
import ApplicationServices
import Darwin

typealias L = CyderLifecycle
final class CyderDiagnostics { static let shared = CyderDiagnostics(); func info(_ message: String) { print(message) } }
struct TestWindow { let pid: Int32; let ownerName: String; let windowID: UInt32 }
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] { [] }
let app = NSApplication.shared
if CommandLine.arguments.contains("--native-child") {
    alarm(40)
    app.setActivationPolicy(.regular)
    var windows: [NSWindow] = []
    for index in 0..<2 {
        let window = NSWindow(contentRect: NSRect(x: 120 + index * 340, y: 180, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Cyder C22 native window"
        window.identifier = NSUserInterfaceItemIdentifier("cyder-c22-\(index)")
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(NSTextField(labelWithString: "Isolated native AX fixture \(index + 1)"))
        window.orderFront(nil)
        if index == 0 { window.miniaturize(nil) }
        windows.append(window)
    }
    app.run()
    withExtendedLifetime(windows) {}
    exit(0)
}
app.setActivationPolicy(.accessory)
func pump(_ timeout: Double = 8, _ condition: () -> Bool) -> Bool {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return condition()
}
print("native_AX_trusted_no_prompt=\(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else { print("BLOCKED: current native harness lacks Accessibility permission; no prompt requested"); exit(0) }
func runNative() throws -> Int32 {
let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]); child.arguments = ["--native-child"]
try child.run()
defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
var birth: L.ProcessID?
DispatchQueue.global().async {
    if case .live(let node) = CyderProcessEvidence.inspect(child.processIdentifier) { DispatchQueue.main.async { birth = node.id } }
}
guard pump(8, { birth != nil }) else { print("BLOCKED: native child birth unavailable"); return 1 }
let controller = CyderStatusItemController(); controller.setUIVisible(true)
let activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
    if let application = $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        controller.noteFrontmostApplication(application.processIdentifier)
    }
}
defer { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
let environment = L.EnvironmentID(uid: getuid(), device: 12, inode: 34, namespace: "native-window-fixture")
let stamp = L.Stamp(epoch: controller.lifecycleEpoch, environment: environment, generation: 1)
controller.receiveLifecycleEvent(.manage(.init(id: environment, prefix: "/fixture/native-ax", engine: "/fixture", generation: 1, existence: .alive)))
controller.receiveLifecycleEvent(.executionAttached(stamp,
    .init(id: "native-request", digest: "native-digest", environment: environment, phase: .dispatching, launch: "native-launch"),
    .init(id: "native-launch", request: "native-request", environment: environment, name: "Native AX fixture", deadline: .infinity)))
controller.receiveLifecycleEvent(.processObserved(stamp, .init(id: birth!, name: "Native fixture", environment: environment, launch: "native-launch", ownership: .rootReceipt, existence: .alive)))
controller.receiveLifecycleEvent(.observationFinished(stamp, launch: "native-launch", outcome: .unconfirmed))
guard pump(12, { controller.lifecycleSnapshot.windows.count == 2 }) else {
    print("BLOCKED: actual native AX enumeration windows=\(controller.lifecycleSnapshot.windows.count) capability=\(String(describing: controller.lifecycleSnapshot.processes[birth!]?.windowCapability))")
    controller.quiesce(); _ = pump { controller.lifecycleSnapshot.phase == .quiescing }; return 1
}
let menu = NSMenu(); controller.menuNeedsUpdate(menu)
let children = menu.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.action != nil }
print("real native AX windows=\(controller.lifecycleSnapshot.windows.count) minimized=\(controller.lifecycleSnapshot.windows.values.filter { $0.minimized == true }.count) actions=\(children.count)")
var successes = 0
for item in children {
    guard item.isEnabled, let action = item.action else { print("BLOCKED: native target capability unavailable"); continue }
    let prior = controller.lifecycleSnapshot.windowAction?.id
    precondition(NSApp.sendAction(action, to: item.target, from: item))
    _ = pump(5) { controller.lifecycleSnapshot.windowAction?.id != prior && controller.lifecycleSnapshot.windowAction?.result != nil }
    let result = controller.lifecycleSnapshot.windowAction?.result
    print("real native exact selector title=\(item.title) result=\(String(describing: result))")
    if result == .shown { successes += 1 }
}
controller.quiesce(); _ = pump { controller.lifecycleSnapshot.phase == .quiescing }
print("native child survived Cyder observer quiesce=\(child.isRunning)")
print("real_native_AX_shown=\(successes)/2; environment/launch attachment injected; no Wine/NGS claim")
return successes == 2 ? 0 : 1
}
exit(try runNative())
