import AppKit
import Foundation
import Darwin

func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "library harness timeout")
}
func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let exe = root.appendingPathComponent("sample.exe")
try Data().write(to: exe)
let production = CyderLibraryLoader()
var snapshot: CyderLibrarySnapshot?
var failed = false
production.onUpdate = { update in
    if case .ready(let value) = update { snapshot = value }
    if case .failed = update { failed = true }
}
production.request(.add(exe))
pump { snapshot != nil }
precondition(snapshot!.games.count == 1)
let firstID = snapshot!.games[0].id
try FileManager.default.removeItem(at: exe)
snapshot = nil
production.request()
pump { snapshot != nil }
precondition(snapshot!.games.first?.id == firstID, "unmounted/missing EXE deleted from library")
let library = CyderPaths.support.appendingPathComponent("game-library.json")
let corrupt = Data("malformed-history".utf8)
try corrupt.write(to: library)
production.request()
pump { failed }
let preserved = try Data(contentsOf: library)
precondition(preserved == corrupt, "failed refresh overwrote corrupt history")
production.quiesce()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
final class Counter {
    let lock = NSLock(); var count = 0
    func increment() { precondition(!Thread.isMainThread); lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let counter = Counter(), gate = DispatchSemaphore(value: 0)
let loader = CyderLibraryLoader(deadline: 0.05, read: { _ in
    counter.increment(); gate.wait()
    return .init(games: [], independentIDs: [])
})
let start = ProcessInfo.processInfo.systemUptime
let controller = CyderGameLibraryWindowController(loader: loader)
controller.showWindow(nil)
controller.prepareForDisplay()
precondition(ProcessInfo.processInfo.systemUptime - start < 1, "window creation waited for data")
var preferences = 0, prepare = 0
controller.onOpenPreferences = { preferences += 1 }
controller.onPrepareEnvironment = { prepare += 1 }
let buttons = views(controller.window!.contentView!.superview!).compactMap { $0 as? NSButton }
let preferencesButton = buttons.first { $0.toolTip == "偏好設定" }!
preferencesButton.performClick(nil)
let environmentButton = buttons.first { $0.title == "準備 Windows 環境" }!
environmentButton.performClick(nil)
precondition(preferences == 1 && prepare == 1)
for _ in 0..<50 { controller.prepareForDisplay() }
var tick = false
DispatchQueue.main.async { tick = true }
pump { tick && views(controller.window!.contentView!).contains { ($0 as? NSTextField)?.stringValue.contains("讀取時間較長") == true } }
precondition(counter.value == 1, "refresh grew blocked workers")
gate.signal()
pump { !loader.isBusy }
precondition(views(controller.window!.contentView!).contains { ($0 as? NSTextField)?.stringValue == "尚未加入遊戲" })
controller.showRecoveryNotice()
let dismiss = views(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "關閉提示" }!
dismiss.performClick(nil)
precondition(dismiss.superview!.isHidden)
if let path = ProcessInfo.processInfo.environment["CYDER_TEST_RENDER"] {
    controller.updateRequestSummary("1 個項目尚未啟動 · 查看要求")
    controller.showRecoveryNotice()
    controller.window!.contentView!.layoutSubtreeIfNeeded()
    let view = controller.window!.contentView!
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
controller.quiesce(); controller.close()
let lateGate = DispatchSemaphore(value: 0)
var updates = 0
let late = CyderLibraryLoader(deadline: 0.05, read: { _ in lateGate.wait(); return .init(games: [], independentIDs: []) })
late.onUpdate = { _ in updates += 1 }
late.request(); late.quiesce(); lateGate.signal()
var completed = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completed = true }
pump { completed }
precondition(updates == 1 && !late.request(), "quit permitted late update/new work")
try Data("ok".utf8).write(to: root.appendingPathComponent("ui-completed"))
print("PASS library: actual persisted add, unavailable EXE retained, corrupt history preserved, off-main bounded worker, actual AppKit controls during hang, inline deadline, no duplicate work, quit fences late results")
