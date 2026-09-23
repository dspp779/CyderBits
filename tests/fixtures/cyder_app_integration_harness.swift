import AppKit
import Foundation
import Darwin

let env = ProcessInfo.processInfo.environment
let mode = env["CYDER_FIXTURE_MODE"]!
let output = URL(fileURLWithPath: env["CYDER_FIXTURE_OUTPUT"]!)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func save(_ name: String, _ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try! data.write(to: output.appendingPathComponent(name), options: .atomic)
}
func require(_ ok: @autoclosure () -> Bool, _ reason: String) {
    if !ok() { save("failed.json", ["reason": reason]); fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
func pump(_ ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !ready(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    require(ready(), "seed deadline")
}
if mode == "seed" {
    let journal = CyderRequestJournal(directory: CyderPaths.support.appendingPathComponent("request-journal"))
    var opened = false
    journal.open { result in if case .success = result { opened = true } }
    pump { opened }
    var namespace: UUID?
    journal.namespace { namespace = $0 }; pump { namespace != nil }
    let queued = CyderRequestJournal.makeID(namespace: namespace!)
    let dispatch = CyderRequestJournal.makeID(namespace: namespace!)
    for id in [queued, dispatch] {
        var submitted = false
        journal.submit(id: id, payload: .init(files: [output.appendingPathComponent(id == queued ? "queued.exe" : "dispatch.exe").path], arguments: nil, urls: [], showUI: false)) { result in
            if case .success = result { submitted = true }
        }
        pump { submitted }
    }
    var authorized = false
    journal.authorizeDispatch(id: dispatch) { result in if case .success = result { authorized = true } }
    pump { authorized }
    var closed = false
    journal.close { closed = true }; pump { closed }
    save("seed.json", ["queued": queued, "dispatch": dispatch])
    print("PASS seed: actual durable queued/dispatching journal")
    exit(0)
}

// Instrument the production entry, not a replacement delegate. UI actions are
// replayed in-process; this is not computer-use or synthesized keyboard input.
var actions: [String] = []
var quitIssued = false
var quitStarted: TimeInterval?
var ready = false
var unavailableSince: TimeInterval?
let observation = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
    if !quitIssued && mode != "secondary" { save("unexpected-termination-stack.json", ["stack": Thread.callStackSymbols]) }
    save("terminated.json", ["expected": quitIssued || mode == "secondary", "actions": actions, "mode": mode,
        "quitSeconds": quitStarted.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0])
}
DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
    save("failed.json", ["reason": "full app deadline"])
    _exit(78)
}
func waitForWindow(_ reason: String, matching predicate: (NSWindow) -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !NSApp.windows.contains(where: predicate), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    if !NSApp.windows.contains(where: predicate) {
        save("windows.json", ["windows": NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible,
            "controller": String(describing: $0.windowController)] as [String: Any] }])
        require(false, reason)
    }
}
func menuAction(_ title: String) {
    guard let menu = NSApp.mainMenu?.items.first?.submenu,
          let index = menu.items.firstIndex(where: { $0.title == title }) else { require(false, "missing menu: \(title)"); return }
    let item = menu.items[index]
    require(item.isEnabled, "disabled menu: \(title)")
    guard let action = item.action else { require(false, "missing menu action"); return }
    let fields = Mirror(reflecting: NSApp.delegate!).children.filter {
        ["quitTransaction", "didFinishLaunch", "instanceReady", "openingGameLibrary", "readOnlyMode"].contains($0.label ?? "")
    }.map { ["field": $0.label ?? "", "value": String(describing: $0.value)] }
    save("action-state.json", ["title": title, "target": String(describing: item.target), "selector": NSStringFromSelector(action), "fields": fields])
    if mode == "menu" { menu.performActionForItem(at: index) }
    else { require(NSApp.sendAction(action, to: item.target, from: item), "menu action was not dispatched: \(title)") }
}
func quit() {
    guard !quitIssued else { return }
    quitIssued = true
    quitStarted = ProcessInfo.processInfo.systemUptime
    if mode == "direct" {
        actions.append("quit-appkit")
        NSApp.terminate(nil)
    } else {
        actions.append("quit-menu")
        guard let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == "退出 Cyder" }) else { require(false, "quit menu missing"); return }
        require(item.keyEquivalent == "q", "Command-Q menu binding")
        menuAction("退出 Cyder")
    }
}
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
timer.setEventHandler {
    if mode == "unavailable", !ready {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.windowController is CyderUnavailableWindowController }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if unavailableSince == nil { unavailableSince = now }
        // Give the actual lifecycle-idle settlement time to run. It must not
        // terminate a process which never acquired primary authority.
        guard now - unavailableSince! >= 0.5 else { return }
        ready = true
        actions.append("unavailable")
        for title in ["設定…", "啟動要求…"] {
            require(NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == title })?.isEnabled == false,
                    "read-only fallback enabled mutation menu: \(title)")
        }
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "瀏覽遊戲庫" { return button }
            return view.subviews.compactMap { button(in: $0) }.first
        }
        guard let browse = window.contentView.flatMap({ button(in: $0) }) else { require(false, "fallback browse button missing"); return }
        browse.performClick(nil)
        waitForWindow("fallback browse did not open formal library") { $0.isVisible && $0.windowController is CyderGameLibraryWindowController }
        actions.append("read-only-library")
        timer.cancel()
        DispatchQueue.main.async { quit() }
        return
    }
    guard mode != "secondary", !ready,
          let library = NSApp.windows.first(where: { $0.isVisible && $0.windowController is CyderGameLibraryWindowController }),
          let delegate = NSApp.delegate as? CyderAppDelegate,
          NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.title == "退出 Cyder" }) == true else { return }
    ready = true
    actions.append("library")
    menuAction("設定…")
    waitForWindow("settings menu did not open formal controller") { $0.isVisible && $0.windowController is CyderSettingsWindowController }
    actions.append("settings")
    menuAction("啟動要求…")
    waitForWindow("requests menu did not open formal controller") { $0.isVisible && $0.windowController is CyderRequestWindowController }
    actions.append("requests")
    menuAction("遊戲庫…")
    library.orderOut(nil)
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    require(library.isVisible, "reopen did not restore library")
    actions.append("reopen")
    save("ready.json", ["actions": actions])
    timer.cancel()
    if mode == "forward" {
        DispatchQueue.global(qos: .utility).async {
            let gate = output.appendingPathComponent("continue")
            let end = Date().addingTimeInterval(18)
            while !FileManager.default.fileExists(atPath: gate.path), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            require(FileManager.default.fileExists(atPath: gate.path), "parent continuation deadline")
            DispatchQueue.main.async { quit() }
        }
    } else if mode == "runloop" {
        let quitTimer = Timer(timeInterval: 0.01, repeats: false) { _ in quit() }
        RunLoop.main.add(quitTimer, forMode: .common)
    } else { DispatchQueue.main.async { quit() } }
}
timer.resume()
CyderMain.main()
