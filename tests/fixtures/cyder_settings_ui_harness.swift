import AppKit
import Foundation
import Darwin
func check(_ condition: @autoclosure () -> Bool, _ message: String = "assertion failed", line: UInt = #line) {
    if !condition() { fputs("FAIL settings UI line \(line): \(message)\n", stderr); exit(1) }
}
var diagnosticState: () -> String = { "" }
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10, line: UInt = #line) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "settings UI callback missing: \(diagnosticState())", line: line)
}
func views(_ root: NSView) -> [NSView] {
    var seen = Set<ObjectIdentifier>(), result: [NSView] = []
    func visit(_ view: NSView) {
        guard seen.insert(ObjectIdentifier(view)).inserted else { return }
        result.append(view)
        view.subviews.forEach(visit)
        if let tabs = view as? NSTabView { tabs.tabViewItems.compactMap { $0.view }.forEach(visit) }
    }
    visit(root); return result
}
func renderScrollingUI(_ window: NSWindow, name: String, tab: String? = nil) throws {
    guard let folder = ProcessInfo.processInfo.environment["CYDER_SCROLL_UI_RENDER_DIR"],
          let content = window.contentView else { return }
    if let tab, let tabs = views(content).compactMap({ $0 as? NSTabView }).first,
       let item = tabs.tabViewItems.first(where: { $0.label == tab }) { tabs.selectTabViewItem(item) }
    content.layoutSubtreeIfNeeded()
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let settingsURL = root.appendingPathComponent("settings.json")
let original = CyderSettings(fontMingLiuTarget: "songti")
try JSONEncoder().encode(original).write(to: settingsURL)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let gate = DispatchSemaphore(value: 0), pendingSave = DispatchSemaphore(value: 0), secondPendingSave = DispatchSemaphore(value: 0), countLock = NSLock()
var reads = 0
let access = CyderSettingsAccess(url: settingsURL, deadline: 0.05, read: { url in
    check(!Thread.isMainThread)
    countLock.lock(); reads += 1; let count = reads; countLock.unlock()
    if count == 1 { gate.wait() }
    if count == 2 { pendingSave.wait() }
    if count == 3 { secondPendingSave.wait() }
    return try CyderSettingsStore.readValidated(at: url)
})
let started = ProcessInfo.processInfo.systemUptime
let preferences = CyderSettingsWindowController(settingsAccess: access)
preferences.hasRunningExes = { false }
var applied = 0
preferences.onImmediateSave = { _ in applied += 1; return true }
preferences.showWindow(nil)
check(ProcessInfo.processInfo.systemUptime - started < 1, "preferences constructor waited for disk")
let controls = views(preferences.window!.contentView!)
diagnosticState = { "applied=\(applied); " + controls.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ") }
let retina = controls.first { $0.identifier?.rawValue == "settings-retina" } as! NSSwitch
check(!retina.isEnabled)
check(!controls.contains { ($0 as? NSButton)?.title == "打開遊戲庫…" }, "preferences still exposes the library button")
let settingsTabs = controls.compactMap { $0 as? NSTabView }.first!
let generalViews = views(settingsTabs.tabViewItems.first { $0.label == "一般" }!.view!)
let advancedViews = views(settingsTabs.tabViewItems.first { $0.label == "進階" }!.view!)
check(!generalViews.contains { ($0 as? NSButton)?.title == "關閉所有 Windows 程序" })
check(advancedViews.contains { ($0 as? NSButton)?.title == "關閉所有 Windows 程序" }, "stop action missing from advanced tab")
for _ in 0..<40 { preferences.prepareForDisplay() }
var ticked = false; DispatchQueue.main.async { ticked = true }
pump { ticked && controls.contains { ($0 as? NSTextField)?.stringValue.contains("讀取尚未確認") == true } }
countLock.lock(); check(reads == 1); countLock.unlock()
gate.signal(); pump { retina.isEnabled }
retina.state = .on
check(retina.sendAction(retina.action!, to: retina.target))
pump { controls.contains { ($0 as? NSTextField)?.stringValue.contains("儲存尚未確認") == true } }
check(applied == 0)
pendingSave.signal()
pump { applied == 1 && controls.contains { ($0 as? NSTextField)?.stringValue == "設定已儲存" } }
let saved = try CyderSettingsStore.readValidated(at: settingsURL)
check(saved.retinaMode, "formal settings action did not persist")
// A newer identical edit can arrive while the first write is physically busy.
// Retrying after the older write must still perform its pending prefix apply.
retina.state = .off
check(retina.sendAction(retina.action!, to: retina.target))
pump { controls.contains { ($0 as? NSTextField)?.stringValue.contains("儲存尚未確認") == true } }
check(retina.sendAction(retina.action!, to: retina.target))
pump { controls.contains { ($0 as? NSTextField)?.stringValue.contains("草稿尚未儲存") == true } }
secondPendingSave.signal(); pump { !access.isBusy }
check(applied == 1)
let retry = controls.compactMap { $0 as? NSButton }.first { $0.title == "重試" }!
check(!retry.isHidden); retry.performClick(nil)
pump { applied == 2 && controls.contains { ($0 as? NSTextField)?.stringValue == "設定已儲存" } }
let retried = try CyderSettingsStore.readValidated(at: settingsURL)
check(!retried.retinaMode)
let exe = root.appendingPathComponent("inert.exe"); try Data().write(to: exe)
let game = CyderGameRecord(id: "profile-aaaaaaaaaaaaaaaaaaaaaaaa", executablePath: exe.path)
let gameAccess = CyderSettingsAccess(url: settingsURL)
let options = CyderGameSettingsWindowController(game: game, independent: true, settingsAccess: gameAccess)
options.showWindow(nil)
let gameControls = views(options.window!.contentView!)
diagnosticState = { "game: " + gameControls.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ") }
let saveButton = gameControls.first { $0.identifier?.rawValue == "game-settings-save" } as! NSButton
let gameRetina = gameControls.first { $0.identifier?.rawValue == "game-settings-retina" } as! NSSwitch
let gameScrolling = gameControls.first { $0.identifier?.rawValue == "game-settings-scrolling" } as! NSPopUpButton
check(gameScrolling.itemTitles == CyderScrolling.gameTitles)
pump { saveButton.isEnabled && gameRetina.isEnabled }
check(gameControls.contains { ($0 as? NSTextField)?.stringValue.contains("同一 prefix 內同名 EXE") == true })
try renderScrollingUI(options.window!, name: "game-scrolling")
var savedEvents = 0
options.onSettingsChanged = { savedEvents += 1 }
gameRetina.state = .on
check(gameScrolling.indexOfSelectedItem == 0)
gameScrolling.selectItem(at: 2)
saveButton.performClick(nil)
pump { savedEvents == 1 }
let perGame = try CyderSettingsStore.readValidated(at: settingsURL)
check(perGame.perProfile[game.id]?.retinaMode == true && !perGame.retinaMode,
             "game edit lost global preferences")
check(perGame.perProfile[game.id]?.scrolling == .traditional && perGame.scrolling == .traditional,
      "per-game scrolling edit lost global preferences")
// Re-open and verify the saved menu selection, then exercise every choice
// through the actual Apply action without starting Wine.
for (index, expected): (Int, CyderScrolling?) in [(3, .precise), (1, .unmanaged), (0, nil)] {
    let reopened = CyderGameSettingsWindowController(game: game, independent: true, settingsAccess: gameAccess)
    reopened.showWindow(nil)
    let reopenedViews = views(reopened.window!.contentView!)
    let popup = reopenedViews.first { $0.identifier?.rawValue == "game-settings-scrolling" } as! NSPopUpButton
    let apply = reopenedViews.first { $0.identifier?.rawValue == "game-settings-save" } as! NSButton
    pump { apply.isEnabled && popup.isEnabled }
    if index == 3 { check(popup.indexOfSelectedItem == 2, "persisted scrolling choice not loaded") }
    var completed = false; reopened.onSettingsChanged = { completed = true }
    popup.selectItem(at: index); apply.performClick(nil)
    pump { completed }
    let persisted = try CyderSettingsStore.readValidated(at: settingsURL)
    check(persisted.perProfile[game.id]?.scrolling == expected)
    reopened.close()
}
// A separate preferences view tests global scrolling changes while the
// application reports a running game: save only, no live registry apply.
let scrollAccess = CyderSettingsAccess(url: settingsURL)
let scrollPreferences = CyderSettingsWindowController(settingsAccess: scrollAccess)
scrollPreferences.hasRunningExes = { true }
var scrollingRegistryApplies = 0
scrollPreferences.onImmediateSave = { _ in scrollingRegistryApplies += 1; return true }
scrollPreferences.showWindow(nil)
let scrollingViews = views(scrollPreferences.window!.contentView!)
let globalScrolling = scrollingViews.first { $0.identifier?.rawValue == "settings-scrolling" } as! NSSwitch
pump { globalScrolling.isEnabled }
check(globalScrolling.state == .off, "precise scrolling should default off")
for (state, expected) in [(NSControl.StateValue.on, CyderScrolling.precise), (.off, .traditional)] {
    globalScrolling.state = state
    check(globalScrolling.sendAction(globalScrolling.action!, to: globalScrolling.target))
    pump { (try? CyderSettingsStore.readValidated(at: settingsURL).scrolling) == expected }
}
check(scrollingRegistryApplies == 0, "scrolling preference edited a live prefix")
check(scrollingViews.contains { ($0 as? NSTextField)?.stringValue == "開啟可能會捲動過快。" })
try renderScrollingUI(scrollPreferences.window!, name: "global-scrolling", tab: "輸入")
scrollPreferences.close(); scrollAccess.quiesce()
// A late successful physical write may persist, but closing the window must
// prevent its callback from closing a later modal or claiming a new UI success.
let saveGate = DispatchSemaphore(value: 0), saveLock = NSLock()
var saveReads = 0
let delayed = CyderSettingsAccess(url: settingsURL, deadline: 0.03, read: { url in
    saveLock.lock(); saveReads += 1; let count = saveReads; saveLock.unlock()
    if count == 2 { saveGate.wait() }
    return try CyderSettingsStore.readValidated(at: url)
})
let late = CyderGameSettingsWindowController(game: game, independent: true, settingsAccess: delayed)
late.showWindow(nil)
let lateViews = views(late.window!.contentView!)
diagnosticState = { "late: " + lateViews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ") }
let lateSave = lateViews.first { $0.identifier?.rawValue == "game-settings-save" } as! NSButton
let lateRetina = lateViews.first { $0.identifier?.rawValue == "game-settings-retina" } as! NSSwitch
pump { lateSave.isEnabled }
var lateUI = 0; late.onSettingsChanged = { lateUI += 1 }
lateRetina.state = .off; lateSave.performClick(nil)
pump { lateViews.contains { ($0 as? NSTextField)?.stringValue.contains("儲存尚未確認") == true } }
late.close(); saveGate.signal()
var checked = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { checked = true }
pump { checked }
check(lateUI == 0, "closed settings view accepted a late write callback")
// Runtime maintenance uses the real environment operation gate and retains
// the lease past observation timeout and window close until actual completion.
let maintenanceAccess = CyderSettingsAccess(url: settingsURL, deadline: 0.03)
let maintenance = CyderSettingsWindowController(settingsAccess: maintenanceAccess)
maintenance.hasRunningExes = { false }
maintenance.showWindow(nil)
let maintenanceViews = views(maintenance.window!.contentView!)
let maintenanceRetina = maintenanceViews.first { $0.identifier?.rawValue == "settings-retina" } as! NSSwitch
pump { maintenanceRetina.isEnabled }
let operationGate = CyderOperationGate()
maintenance.maintenanceGate = operationGate
let mutationGate = DispatchSemaphore(value: 0), mutationLock = NSLock()
var mutationStarted = false, duplicateMutation = false
maintenance.performRuntimeMaintenance {
    check(!Thread.isMainThread)
    mutationLock.lock(); mutationStarted = true; mutationLock.unlock()
    mutationGate.wait()
    try Data("finished".utf8).write(to: root.appendingPathComponent("maintenance-result"))
}
pump { mutationLock.lock(); defer { mutationLock.unlock() }; return mutationStarted }
maintenance.performRuntimeMaintenance { duplicateMutation = true }
pump { maintenanceViews.contains { ($0 as? NSTextField)?.stringValue.contains("元件更新尚未確認") == true } }
var followingLease: CyderOperationGate.Lease?
operationGate.acquire(.environment("test-bottle")) { followingLease = $0 }
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
check(followingLease == nil && !duplicateMutation)
maintenance.close(); maintenanceAccess.quiesce()
mutationGate.signal(); pump { followingLease != nil }
let physicalResult = try Data(contentsOf: root.appendingPathComponent("maintenance-result"))
check(physicalResult == Data("finished".utf8))
operationGate.release(followingLease!)
// Post-mutation presentation reads do not extend mutation ownership.
let metadataAccess = CyderSettingsAccess(url: settingsURL, deadline: 0.03)
let metadataUI = CyderSettingsWindowController(settingsAccess: metadataAccess)
metadataUI.showWindow(nil)
let metadataViews = views(metadataUI.window!.contentView!)
let metadataRetina = metadataViews.first { $0.identifier?.rawValue == "settings-retina" } as! NSSwitch
pump { metadataRetina.isEnabled }
let metadataGate = DispatchSemaphore(value: 0), metadataLock = NSLock()
var metadataStarted = false
metadataUI.maintenanceGate = operationGate
metadataUI.runtimePresentationReader = {
    metadataLock.lock(); metadataStarted = true; metadataLock.unlock()
    metadataGate.wait(); return CyderSettingsPresentation()
}
metadataUI.performRuntimeMaintenance { }
pump { metadataLock.lock(); defer { metadataLock.unlock() }; return metadataStarted }
var duringMetadata: CyderOperationGate.Lease?
operationGate.acquire(.environment("other-bottle")) { duringMetadata = $0 }
pump { duringMetadata != nil }
pump { metadataViews.contains { ($0 as? NSTextField)?.stringValue.contains("顯示狀態仍在確認") == true } }
operationGate.release(duringMetadata!); metadataUI.close(); metadataAccess.quiesce(); metadataGate.signal()
// Closing before the gate grants authority cancels this unscheduled action.
let queuedAccess = CyderSettingsAccess(url: settingsURL)
let queuedUI = CyderSettingsWindowController(settingsAccess: queuedAccess)
queuedUI.showWindow(nil)
let queuedViews = views(queuedUI.window!.contentView!)
let queuedRetina = queuedViews.first { $0.identifier?.rawValue == "settings-retina" } as! NSSwitch
pump { queuedRetina.isEnabled }
queuedUI.maintenanceGate = operationGate
var blocker: CyderOperationGate.Lease?
operationGate.acquire(.allEnvironments) { blocker = $0 }; pump { blocker != nil }
var wronglyStarted = false
queuedUI.performRuntimeMaintenance { wronglyStarted = true }
queuedUI.close(); operationGate.release(blocker!)
var afterCancel: CyderOperationGate.Lease?
operationGate.acquire(.allEnvironments) { afterCancel = $0 }; pump { afterCancel != nil }
check(!wronglyStarted)
operationGate.release(afterCancel!); queuedAccess.quiesce(); operationGate.quiesce()
if let path = ProcessInfo.processInfo.environment["CYDER_TEST_RENDER"] {
    let content = preferences.window!.contentView!
    content.layoutSubtreeIfNeeded()
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
preferences.close(); options.close(); access.quiesce(); gameAccess.quiesce(); delayed.quiesce()
try Data("completed\n".utf8).write(to: root.appendingPathComponent("ui-completed"))
print("PASS formal settings AppKit: slow first load, bounded reopen, responsive event loop, global and per-game save actions, late close fence (no Wine)")
