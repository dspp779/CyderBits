import Cocoa
import ApplicationServices
import Darwin

typealias L = CyderLifecycle
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
func settle(_ delay: Double = 0.1) {
    var done = false; DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done = true }
    pump("settlement", timeout: delay + 2) { done }
}
final class Backend {
    let lock = NSLock(), actionGate = DispatchSemaphore(value: 0), scanGate = DispatchSemaphore(value: 0)
    var nodes: [L.ProcessID: [CyderWindowAccess.Node]] = [:]
    var unavailable: L.Capability?
    var holdActions = false, holdScans = false
    var entered: [ObjectIdentifier] = [], performed: [ObjectIdentifier] = []
    var scans = 0, returned = 0, permissionRequests = 0
    func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    var driver: CyderWindowAccess.Driver { .init(scan: { [self] process in
        precondition(!Thread.isMainThread)
        let (hold, result): (Bool, CyderWindowAccess.Query) = locked {
            scans += 1
            return (holdScans, unavailable.map { .unavailable($0) } ?? .windows(nodes[process] ?? []))
        }
        if hold { precondition(scanGate.wait(timeout: .now() + 15) == .success, "fixture scan gate") }
        return result
    }, equal: { $0 === $1 }, activate: { [self] _, handle, allowed in
        precondition(!Thread.isMainThread)
        let hold = locked { entered.append(ObjectIdentifier(handle)); return holdActions }
        if hold { precondition(actionGate.wait(timeout: .now() + 12) == .success, "fixture action gate") }
        let accepted = allowed()
        locked { returned += 1; if accepted { performed.append(ObjectIdentifier(handle)) } }
        return accepted ? .shown : .unconfirmed
    }, requestPermission: { [self] in locked { permissionRequests += 1 } }) }
    func set(_ process: L.ProcessID, _ handles: [NSObject], capability: L.Capability = .available, title: String = "Same title") {
        locked { nodes[process] = handles.map { .init(handle: $0, title: title, capability: capability, minimized: true, focused: false) } }
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
print("AXIsProcessTrusted_no_prompt=\(AXIsProcessTrusted()); remaining window data/actions are injected")
let backend = Backend(), first = NSObject(), second = NSObject()
let process = L.ProcessID(boot: "fixture-boot", pid: 40001, started: 100)
backend.set(process, [first, second])
let controller = CyderStatusItemController(windowDriver: backend.driver)
controller.setUIVisible(true)
let environment = L.EnvironmentID(uid: getuid(), device: 17, inode: 29, namespace: "window-fixture")
let stamp = L.Stamp(epoch: controller.lifecycleEpoch, environment: environment, generation: 1)
controller.receiveLifecycleEvent(.manage(.init(id: environment, prefix: "/fixture/window", engine: "/fixture/engine", generation: 1, existence: .alive)))
controller.receiveLifecycleEvent(.executionAttached(stamp,
    .init(id: "request", digest: "digest", environment: environment, phase: .dispatching, launch: "launch"),
    .init(id: "launch", request: "request", environment: environment, name: "Window fixture", deadline: .infinity)))
controller.receiveLifecycleEvent(.processObserved(stamp, .init(id: process, name: "Fixture", environment: environment, launch: "launch", ownership: .rootReceipt, existence: .alive)))
controller.receiveLifecycleEvent(.observationFinished(stamp, launch: "launch", outcome: .unconfirmed))
pump("two AX object identities") { controller.lifecycleSnapshot.windows.count == 2 }
let originalIDs = Set(controller.lifecycleSnapshot.windows.keys)
let menu = NSMenu(); controller.menuNeedsUpdate(menu)
func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
func command(_ title: String, in menu: NSMenu) -> NSMenuItem { items(menu).first { $0.title == title }! }
func click(_ item: NSMenuItem) {
    precondition(item.isEnabled && item.action != nil)
    precondition(NSApp.sendAction(item.action!, to: item.target, from: item), "formal selector was not invoked")
}
let windowItems = items(menu).filter { $0.title.hasPrefix("Same title") }
precondition(windowItems.count == 2 && Set(windowItems.map(\.title)).count == 2 && !menu.autoenablesItems)
precondition(windowItems.allSatisfy { $0.toolTip?.contains("最小化") == true && $0.isEnabled })
precondition(backend.locked { backend.permissionRequests == 0 }, "background scan requested permission")
click(windowItems[0]); pump("first exact action") { controller.lifecycleSnapshot.windowAction?.result == .shown }
click(windowItems[1]); pump("second exact action") { backend.locked { backend.performed.count == 2 } }
precondition(Set(backend.locked { backend.performed }) == [ObjectIdentifier(first), ObjectIdentifier(second)], "same title routed to same object")
controller.menuNeedsUpdate(menu); click(command("重新檢查視窗", in: menu))
settle(); precondition(Set(controller.lifecycleSnapshot.windows.keys) == originalIDs, "unchanged AX handles lost identity")
print("PASS two same-title/minimized windows: actual AppKit selectors reached different exact objects; refresh retained identity")

// Width truncation must preserve the disambiguating suffix of same-title
// windows. The original menu objects still bind exactly the same identities.
backend.set(process, [first, second], title: String(repeating: "很長的相同視窗標題", count: 12))
click(command("重新檢查視窗", in: menu))
pump("long title scan") { controller.lifecycleSnapshot.windows.values.allSatisfy { $0.title.hasPrefix("很長") } }
controller.menuNeedsUpdate(menu)
let longItems = items(menu).filter { $0.title.hasPrefix("很長") }
let font: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
precondition(longItems.count == 2 && longItems[0].title.hasSuffix("(1)") && longItems[1].title.hasSuffix("(2)"))
precondition(longItems.allSatisfy { ($0.title as NSString).size(withAttributes: font).width <= 360 })
precondition(Set(controller.lifecycleSnapshot.windows.keys) == originalIDs)
backend.set(process, [first, second]); click(command("重新檢查視窗", in: menu))
pump("restore fixture title") { controller.lifecycleSnapshot.windows.values.allSatisfy { $0.title == "Same title" } }
print("PASS long duplicate titles remain distinguishable within 360 points without retargeting")

// Same target pending coalesces; a new target supersedes the first even while
// its physical worker is blocked. Only the new intent may perform on release.
backend.locked { backend.holdActions = true }
click(windowItems[0]); pump("held first") { backend.locked { backend.entered.count == 3 } }
let firstOperation = controller.lifecycleSnapshot.windowAction!.id
click(windowItems[0]); settle()
precondition(controller.lifecycleSnapshot.windowAction?.id == firstOperation && backend.locked { backend.entered.count == 3 })
click(windowItems[1]); pump("superseding target") { backend.locked { backend.entered.count == 4 } }
backend.actionGate.signal(); backend.actionGate.signal()
pump("both old and new worker returned") { backend.locked { backend.returned == 4 } }
pump("new intent success") { controller.lifecycleSnapshot.windowAction?.result == .shown }
precondition(backend.locked { backend.performed.count == 3 }, "old intent performed after supersession")

click(windowItems[0]); pump("focus-race worker") { backend.locked { backend.entered.count == 5 } }
controller.noteFrontmostApplication(12345)
pump("focus cancellation") { controller.lifecycleSnapshot.windowAction?.result == .unconfirmed }
backend.actionGate.signal(); pump("focus worker returned") { backend.locked { backend.returned == 5 } }
precondition(backend.locked { backend.performed.count == 3 }, "caught up after user focus changed")
// Failure is retained while closed, immutable while tracking, and dismissed
// only after the actual menu delegate presentation/close transaction.
settle(); let feedback = controller.lifecycleSnapshot.windowAction!.id
controller.menuNeedsUpdate(menu)
precondition(items(menu).contains { $0.title.contains("尚未確認視窗是否已顯示") })
let titles = menu.items.map(\.title), mutations = controller.menuMutationCount
controller.menuWillOpen(menu); controller.menuNeedsUpdate(menu)
precondition(controller.menuMutationCount == mutations && menu.items.map(\.title) == titles)
precondition(controller.lifecycleSnapshot.windowAction?.id == feedback)
controller.menuDidClose(menu); pump("presented feedback dismissed") { controller.lifecycleSnapshot.windowAction == nil }
print("PASS pending coalescing, supersession, changed focus, retained one-time feedback, tracking immutability")

click(windowItems[0]); pump("timeout worker") { backend.locked { backend.entered.count == 6 } }
pump("half-second progress", timeout: 1.5) { controller.lifecycleSnapshot.windowAction?.showingProgress == true }
pump("three-second finite observation", timeout: 3.5) { controller.lifecycleSnapshot.windowAction?.result == .unconfirmed }
backend.actionGate.signal(); pump("expired physical worker returned") { backend.locked { backend.returned == 6 } }
precondition(backend.locked { backend.performed.count == 3 })
let timeoutID = controller.lifecycleSnapshot.windowAction!.id
settle(); precondition(controller.lifecycleSnapshot.windowAction?.id == timeoutID, "closed-menu failure expired unseen")
print("PASS bounded progress/timeout; late response cannot reissue activation")

// A replaced same-title object must get a new token. An old menu item is never
// retargeted to it, even though it retains the same process and title.
let replacement = NSObject(); backend.set(process, [replacement])
controller.menuNeedsUpdate(menu); click(command("重新檢查視窗", in: menu))
pump("replacement window") { controller.lifecycleSnapshot.windows.count == 1 && originalIDs.isDisjoint(with: controller.lifecycleSnapshot.windows.keys) }
let beforeGone = backend.locked { backend.entered.count }
click(windowItems[0]); pump("closed old target") { controller.lifecycleSnapshot.windowAction?.result == .windowGone }
precondition(backend.locked { backend.entered.count == beforeGone })
controller.menuNeedsUpdate(menu)
let replacementItem = items(menu).first { $0.title == "Window fixture — Same title" }!
click(replacementItem); pump("replacement held") { backend.locked { backend.entered.count == beforeGone + 1 } }
controller.receiveLifecycleEvent(.processExited(stamp, process))
let reused = L.ProcessID(boot: process.boot, pid: process.pid, started: process.started + 1)
backend.set(reused, [NSObject()])
controller.receiveLifecycleEvent(.processObserved(stamp, .init(id: reused, name: "Reused PID", environment: environment, launch: "launch", ownership: .rootReceipt, existence: .alive)))
pump("old birth no longer actionable") { controller.lifecycleSnapshot.windowAction?.result != nil }
backend.actionGate.signal(); pump("old birth worker returned") { backend.locked { backend.returned == beforeGone + 1 } }
precondition(backend.locked { backend.performed.count == 3 })
click(replacementItem); pump("ended process feedback") { controller.lifecycleSnapshot.windowAction?.result == .processEnded }
print("PASS closed/replaced same-title target and PID reuse never switch to replacement")

// Permission denial never requests TCC by scanning or opening a menu. The
// injected prompt callback is driven only by the formal explicit menu action.
backend.locked { backend.unavailable = .permissionRequired }
controller.menuNeedsUpdate(menu); click(command("重新檢查視窗", in: menu))
pump("permission capability") { controller.lifecycleSnapshot.processes[reused]?.windowCapability == .permissionRequired }
controller.menuNeedsUpdate(menu)
precondition(backend.locked { backend.permissionRequests == 0 })
click(command("允許操作已辨識的視窗…", in: menu))
pump("explicit permission request") { backend.locked { backend.permissionRequests == 1 } }
controller.menuNeedsUpdate(menu)
precondition(items(menu).contains { $0.title.contains("系統設定中允許") && !$0.isEnabled })
controller.menuWillOpen(menu); controller.menuDidClose(menu); settle()
precondition(backend.locked { backend.permissionRequests == 1 })
// Quit revokes an action before a delayed physical worker may perform it.
backend.locked { backend.unavailable = nil }
controller.menuNeedsUpdate(menu); click(command("重新檢查視窗", in: menu))
pump("permission recovered") { controller.lifecycleSnapshot.windows.values.contains { $0.id.process == reused && $0.capability == .available } }
controller.menuNeedsUpdate(menu)
let finalItem = items(menu).first { $0.title == "Window fixture — Same title" }!
let enteredBeforeQuit = backend.locked { backend.entered.count }
click(finalItem); pump("quit-race worker entered") { backend.locked { backend.entered.count == enteredBeforeQuit + 1 } }
controller.quiesce(); pump("quit cleared intent") { controller.lifecycleSnapshot.phase == .quiescing }
backend.actionGate.signal(); pump("quit-race worker returned") { backend.locked { backend.returned == enteredBeforeQuit + 1 } }
precondition(backend.locked { backend.performed.count == 3 }, "activation occurred after quit")
settle()
print("PASS permission denial degrades without automatic/repeated prompts; explicit selector only")

// Two permanently delayed physical scans keep their slots. Menus and quit
// continue; a timeout does not permit another physical scan.
let stalled = Backend(); stalled.locked { stalled.holdScans = true }
let blocked = CyderStatusItemController(windowDriver: stalled.driver); blocked.setUIVisible(true)
let blockedStamp = L.Stamp(epoch: blocked.lifecycleEpoch, environment: environment, generation: 1)
blocked.receiveLifecycleEvent(.manage(.init(id: environment, prefix: "/fixture/window", engine: "/fixture/engine", generation: 1, existence: .alive)))
for pid in 41000..<41006 {
    blocked.receiveLifecycleEvent(.processObserved(blockedStamp, .init(id: .init(boot: "fixture", pid: Int32(pid), started: 1), name: "Blocked", environment: environment, existence: .alive)))
}
pump("two physical scans entered") { stalled.locked { stalled.scans == 2 } }
settle(2.2)
let blockedMenu = NSMenu(); var samples: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    blocked.menuNeedsUpdate(blockedMenu); blocked.menuWillOpen(blockedMenu); blocked.menuDidClose(blockedMenu)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
precondition(stalled.locked { stalled.scans == 2 }, "physical scan slots released at logical timeout")
blocked.quiesce(); pump("quit while scans blocked") { blocked.lifecycleSnapshot.phase == .quiescing }
stalled.scanGate.signal(); stalled.scanGate.signal(); settle()
precondition(blocked.lifecycleSnapshot.windows.isEmpty)
print("window callback-cycle proxy samples=30 p95_ms=\(samples.sorted()[28]) max_ms=\(samples.max()!)")
print("window_sample,callback_cycle_ms")
for (index, sample) in samples.enumerated() { print("\(index + 1),\(sample)") }
print("PASS bounded stalled scans, responsive menu callbacks, quit rejects late scan; injected evidence only, not Wine/NGS compatibility")
