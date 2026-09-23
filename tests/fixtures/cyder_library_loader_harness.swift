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
let beforeReadOnly = try Data(contentsOf: library)
let readOnly = CyderLibraryLoader(readOnly: true)
var readOnlySnapshot: CyderLibrarySnapshot?
readOnly.onUpdate = { if case .ready(let value) = $0 { readOnlySnapshot = value } }
readOnly.request(); pump { readOnlySnapshot != nil }
precondition(readOnlySnapshot!.games.count == 1)
var denied: Bool?
precondition(!readOnly.request(.add(exe)) { denied = $0 })
precondition(denied == false)
let afterReadOnly = try Data(contentsOf: library)
precondition(beforeReadOnly == afterReadOnly, "read-only browse mutated library history")
readOnly.quiesce()
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
let readonlyLoader = CyderLibraryLoader(readOnly: true, read: { _ in
    .init(games: [.init(id: firstID, executablePath: exe.path)], independentIDs: [])
})
let readonlyController = CyderGameLibraryWindowController(loader: readonlyLoader, readOnly: true)
var forbiddenActions = 0
readonlyController.onLaunch = { _, _ in forbiddenActions += 1 }
readonlyController.onPrepareEnvironment = { forbiddenActions += 1 }
readonlyController.onOpenPreferences = { forbiddenActions += 1 }
readonlyController.showWindow(nil); readonlyController.prepareForDisplay()
pump { !readonlyLoader.isBusy }
let readonlyButtons = views(readonlyController.window!.contentView!.superview!).compactMap { $0 as? NSButton }
for button in readonlyButtons where button.title == "準備 Windows 環境" || button.toolTip == "偏好設定" || button.toolTip == "加入遊戲" {
    precondition(!button.isEnabled); button.performClick(nil)
}
let collection = views(readonlyController.window!.contentView!).compactMap { $0 as? NSCollectionView }.first!
let tile = readonlyController.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as! CyderGameTileItem
tile.onDoubleClick?()
guard let context = tile.onContextMenu?() else { fputs("FAIL missing read-only context menu\n", stderr); exit(1) }
precondition(context.items[0].isEnabled == false && context.items[1].isEnabled == false)
precondition(forbiddenActions == 0, "read-only UI invoked a mutation/launch callback")
readonlyController.quiesce(); readonlyController.close()

// Exercise the actual context-menu targets with stalled filesystem and
// installer adapters. No Finder opening or user Applications writes occur.
let fileGame = CyderGameRecord(id: firstID, executablePath: exe.path)
let otherGame = CyderGameRecord(id: "second", executablePath: root.appendingPathComponent("other.exe").path)
let metadataGate = DispatchSemaphore(value: 0), metadataCounter = Counter()
let fileLoader = CyderLibraryLoader(read: { operation in
    if case .setMacApp = operation { metadataCounter.increment(); metadataGate.wait() }
    return .init(games: [fileGame, otherGame], independentIDs: [])
})
DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
    fputs("FAIL: file-action fixture deadline\n", stderr); _exit(79)
}
let fileController = CyderGameLibraryWindowController(loader: fileLoader)
fileController.fileActionDeadline = 0.05
fileController.showWindow(nil); fileController.prepareForDisplay()
pump { !fileLoader.isBusy }
let fileCollection = views(fileController.window!.contentView!).compactMap { $0 as? NSCollectionView }.first!
let fileTile = fileController.collectionView(fileCollection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as! CyderGameTileItem
let otherTile = fileController.collectionView(fileCollection, itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)) as! CyderGameTileItem
func contextAction(_ tile: CyderGameTileItem, _ title: String) {
    let menu = tile.onContextMenu!()!
    let index = menu.items.firstIndex(where: { $0.title == title })!
    menu.performActionForItem(at: index)
}
func fileMessage(_ text: String) -> Bool {
    views(fileController.window!.contentView!).contains { ($0 as? NSTextField)?.stringValue.contains(text) == true }
}
var revealed: [URL] = []
fileController.revealInFinder = { precondition(Thread.isMainThread); revealed += $0 }
let fileCounter = Counter(), fileGate = DispatchSemaphore(value: 0)
fileController.fileExists = { _ in fileCounter.increment(); fileGate.wait(); return true }
for _ in 0..<40 { contextAction(fileTile, "顯示於 Finder") }
pump { fileMessage("檔案位置尚未確認") }
precondition(fileCounter.value == 1)
precondition(fileTile.onContextMenu!()!.items.last!.isEnabled == false)
fileGate.signal()
pump { fileTile.onContextMenu!()!.items.last!.isEnabled }
precondition(revealed.isEmpty, "late filesystem result opened Finder")
fileController.fileExists = { _ in precondition(!Thread.isMainThread); return true }
contextAction(fileTile, "顯示於 Finder")
pump { revealed.count == 1 }
precondition(revealed == [exe])
// A newer selection also revokes the meaning of the original target.
let selectionGate = DispatchSemaphore(value: 0), selectionCounter = Counter()
fileController.fileExists = { _ in selectionCounter.increment(); selectionGate.wait(); return true }
contextAction(fileTile, "顯示於 Finder")
pump { selectionCounter.value == 1 }
_ = otherTile.onContextMenu?()
selectionGate.signal()
pump { otherTile.onContextMenu!()!.items.last!.isEnabled }
precondition(revealed.count == 1, "changed selection opened the old target")
var installs = 0
var installCompletion: ((Result<URL, Error>) -> Void)?
fileController.installMacLauncher = { _, completion in installs += 1; installCompletion = completion }
for _ in 0..<40 { contextAction(fileTile, "加入 macOS 應用程式") }
pump { fileMessage("建立結果尚未確認") }
precondition(installs == 1 && !fileTile.onContextMenu!()!.items[0].isEnabled)
installCompletion?(.success(root.appendingPathComponent("Late.app")))
precondition(fileMessage("建立結果尚未確認") && !fileLoader.isBusy, "late install changed presentation or metadata")
precondition(fileTile.onContextMenu!()!.items[0].isEnabled)
contextAction(fileTile, "加入 macOS 應用程式")
precondition(installs == 2)
installCompletion?(.success(root.appendingPathComponent("Saved.app")))
pump { metadataCounter.value == 1 }
precondition(!fileTile.onContextMenu!()!.items[0].isEnabled)
fileController.close(); fileController.showWindow(nil)
metadataGate.signal()
pump { !fileLoader.isBusy && fileTile.onContextMenu!()!.items[0].isEnabled }
precondition(NSApp.modalWindow == nil, "old persistence completion opened a success dialog")
contextAction(fileTile, "加入 macOS 應用程式")
precondition(installs == 3)
let quitGate = DispatchSemaphore(value: 0), quitCounter = Counter()
fileController.fileExists = { _ in quitCounter.increment(); quitGate.wait(); return true }
contextAction(fileTile, "顯示於 Finder")
pump { quitCounter.value == 1 }
fileController.quiesce()
installCompletion?(.success(root.appendingPathComponent("Quit.app")))
quitGate.signal()
contextAction(fileTile, "加入 macOS 應用程式")
contextAction(fileTile, "顯示於 Finder")
var quitSettled = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { quitSettled = true }
pump { quitSettled }
precondition(installs == 3 && quitCounter.value == 1 && revealed.count == 1 && !fileLoader.isBusy)
fileController.close()
// The default installer also delivers preflight failure asynchronously on main.
var defaultInstallFinished = false
CyderMacLauncherInstaller.install(game: fileGame) { result in
    precondition(Thread.isMainThread)
    guard case .failure(CyderMacLauncherError.missingExecutable) = result else { preconditionFailure("missing executable preflight") }
    defaultInstallFinished = true
}
precondition(!defaultInstallFinished, "installer performed synchronous preflight completion")
pump { defaultInstallFinished }
// Run the production installer against an isolated helper that only emits a
// large failure. It never writes the computed Applications destination.
let helperDirectory = Bundle.main.resourceURL!.appendingPathComponent("ogom-scripts")
precondition(helperDirectory.path.hasPrefix(root.deletingLastPathComponent().path + "/"))
try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
let failingHelper = helperDirectory.appendingPathComponent("cyder-create-mac-launcher.sh")
try """
#!/bin/bash
for ((i=0; i<4096; i++)); do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done >&2
exit 7
""".write(to: failingHelper, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingHelper.path)
try Data().write(to: exe)
var largeFailureFinished = false
CyderMacLauncherInstaller.install(game: fileGame) { result in
    precondition(Thread.isMainThread)
    guard case .failure(CyderMacLauncherError.scriptFailed(let detail)) = result else { preconditionFailure("helper failure lost") }
    precondition(detail.hasPrefix("（內容較長，以下為最後一段）\n"), "truncation was not disclosed")
    precondition(detail.filter { $0 == "x" }.count == 65_536, "helper error tail was not bounded")
    largeFailureFinished = true
}
pump { largeFailureFinished }
print("PASS installer: actual native child, 128 KiB stderr drained with 64 KiB tail, main completion, no Applications writes")
print("PASS file actions: actual menu, off-main stalled read, one physical worker, deadline/selection/quit fences, installer late result and asynchronous preflight")

let unavailable = CyderUnavailableWindowController()
var browsed = 0, diagnostics = 0, quits = 0
unavailable.onLibrary = { browsed += 1 }; unavailable.onDiagnostics = { diagnostics += 1 }; unavailable.onQuit = { quits += 1 }
unavailable.update(.forwardUnconfirmed); unavailable.showWindow(nil)
let fallbackViews = views(unavailable.window!.contentView!)
precondition(fallbackViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("不代表取消") })
for button in fallbackViews.compactMap({ $0 as? NSButton }) { button.performClick(nil) }
precondition(browsed == 1 && diagnostics == 1 && quits == 1)
if let path = ProcessInfo.processInfo.environment["CYDER_TEST_RENDER"] {
    let view = unavailable.window!.contentView!; view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path + ".unavailable.png"))
}
unavailable.close()
print("PASS read-only fallback: unchanged persisted metadata, mutation refusal, disabled and guarded actual UI actions, uncertain wording, browse/log/quit controls")
try Data("ok".utf8).write(to: root.appendingPathComponent("ui-completed"))
print("PASS library: actual persisted add, unavailable EXE retained, corrupt history preserved, off-main bounded worker, actual AppKit controls during hang, inline deadline, no duplicate work, quit fences late results")
