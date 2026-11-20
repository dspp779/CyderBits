import Cocoa
import Darwin

// Program control from the menu bar (2026-11-20 design): every row offers
// 結束… and 強制結束…, both always confirmed; Steam warns; nothing runs on 取消.
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
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let driver = CyderWindowAccess.Driver(scan: { _ in .windows([]) }, equal: { $0 === $1 },
    activate: { _, _, _ in .unconfirmed }, requestPermission: {})
let controller = CyderStatusItemController(windowDriver: driver)
controller.setUIVisible(true)
var confirmations: [ProgramConfirmation] = [], answer = false
var closes: [(URL, [String], String)] = [], stops: [String] = []
var signalled: [L.ProcessID] = []
let signalLock = NSLock()
controller.confirmProgramControl = { request, reply in confirmations.append(request); reply(answer) }
controller.onCloseProgram = { closes.append(($0, $1, $2)) }
controller.onProgramStopRequested = { stops.append($0) }
controller.signalProgram = { process in signalLock.lock(); signalled.append(process); signalLock.unlock(); return true }

let environment = L.EnvironmentID(uid: getuid(), device: 17, inode: 31, namespace: "program-control")
let stamp = L.Stamp(epoch: controller.lifecycleEpoch, environment: environment, generation: 1)
controller.receiveLifecycleEvent(.manage(.init(id: environment, prefix: "/fixture/program", engine: "/fixture/engine", generation: 1, existence: .alive)))
func attach(_ launch: String, _ name: String) {
    controller.receiveLifecycleEvent(.executionAttached(stamp,
        .init(id: "request-\(launch)", digest: launch, environment: environment, phase: .dispatching, launch: launch),
        .init(id: launch, request: "request-\(launch)", environment: environment, name: name, deadline: .infinity)))
}
func observe(_ pid: Int32, _ image: String?, launch: String, root: Bool) -> L.ProcessID {
    let id = L.ProcessID(boot: "fixture-boot", pid: pid, started: UInt64(pid))
    controller.receiveLifecycleEvent(.processObserved(stamp, .init(id: id, name: image ?? "Windows 程序", environment: environment,
        launch: launch, ownership: root ? .rootReceipt : .processTree, existence: .alive, executableName: image)))
    return id
}
attach("game", "PenguinHotel.exe")
let gameRoot = observe(41001, nil, launch: "game", root: true)          // not yet named by the scan
let gameChild = observe(41002, "PenguinHotel-Win64-Shipping.exe", launch: "game", root: false)
_ = observe(41003, "svchost.exe", launch: "game", root: false)
controller.receiveLifecycleEvent(.observationFinished(stamp, launch: "game", outcome: .unconfirmed))
pump("game row") { CyderProgramControl.programs(launch: "game", in: controller.lifecycleSnapshot).count == 2 }

func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
func menu() -> NSMenu { let menu = NSMenu(); controller.menuNeedsUpdate(menu); return menu }
func row(_ prefix: String) -> NSMenuItem { menu().items.first { $0.title.hasPrefix(prefix) }! }
func click(_ title: String, in header: NSMenuItem) {
    let item = header.submenu!.items.first { $0.title == title }!
    precondition(item.isEnabled && NSApp.sendAction(item.action!, to: item.target, from: item), "\(title) not invoked")
}
let gameHeader = row("PenguinHotel.exe — ")
precondition(gameHeader.title == "PenguinHotel.exe — 在背景執行", "status word: \(gameHeader.title)")
precondition(gameHeader.submenu?.items.map(\.title) == ["結束…", "強制結束…"], "row actions: \(String(describing: gameHeader.submenu?.items.map(\.title)))")

// 取消 does nothing.
answer = false
click("結束…", in: gameHeader); click("強制結束…", in: gameHeader)
precondition(confirmations.count == 2 && closes.isEmpty && stops.isEmpty && signalled.isEmpty, "取消 must not act")
precondition(confirmations[0] == ProgramConfirmation(name: "PenguinHotel.exe", force: false), "every 結束 asks")
precondition(confirmations[1] == ProgramConfirmation(name: "PenguinHotel.exe", force: true), "every 強制結束 asks")

// 結束 asks the launch's programs to close; the unnamed root falls back to the launch's .exe.
answer = true
click("結束…", in: row("PenguinHotel.exe — "))
precondition(closes.count == 1 && closes[0].0.path == "/fixture/program" && closes[0].2 == "game", "close target")
precondition(closes[0].1 == ["PenguinHotel.exe", "PenguinHotel-Win64-Shipping.exe"], "close images: \(closes[0].1)")
precondition(stops == ["game"], "the launch observation is cancelled")
precondition(row("PenguinHotel.exe — ").title == "PenguinHotel.exe — 正在結束…", "closing word")

// 強制結束 signals exactly the row's programs, never Wine's background programs.
click("強制結束…", in: row("PenguinHotel.exe — "))
pump("force quit signals") { signalLock.lock(); defer { signalLock.unlock() }; return signalled.count == 2 }
precondition(Set(signalled) == [gameRoot, gameChild], "force targets: \(signalled)")

// Steam while a game runs: the warning replaces the plain question.
attach("steam", "steam.exe")
controller.setProgramTitle("Steam", launch: "steam")    // the library title
_ = observe(42001, "steam.exe", launch: "steam", root: true)
_ = observe(42002, "steamwebhelper.exe", launch: "steam", root: false)
controller.receiveLifecycleEvent(.observationFinished(stamp, launch: "steam", outcome: .unconfirmed))
pump("steam row") { CyderProgramControl.programs(launch: "steam", in: controller.lifecycleSnapshot).count == 2 }
answer = false
precondition(menu().items.contains { $0.title.hasPrefix("Steam — ") } && !menu().items.contains { $0.title.hasPrefix("steam.exe — ") },
             "a library game's row uses its library title")
click("結束…", in: row("Steam — "))
let warning = confirmations.last!
precondition(warning.shared == "Steam" && warning.others == ["PenguinHotel-Win64-Shipping.exe"] && warning.title == "仍要結束「Steam」？",
             "Steam warning: \(warning)")
print("PASS program control menu: rows, confirmations, close and force targets, Steam warning")
exit(0)
