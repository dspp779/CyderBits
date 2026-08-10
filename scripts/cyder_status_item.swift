// Menu-bar lifecycle for native Cyder launches on macOS 11 and newer.
import Cocoa
import Foundation

final class CyderStatusItemController: NSObject, NSMenuDelegate {
    private struct Session {
        let pid: Int32
        let prefix: URL
        let displayName: String
        let lifecycleURL: URL
        var primaryExited = false
        var isStopping = false
    }

    var onOpenPreferences: (() -> Void)?
    var onOpenTaskManager: ((URL) -> Void)?
    var onStopPrefixes: (([URL]) -> Void)?
    var onAllSessionsEnded: (() -> Void)?

    private var sessions: [Int32: Session] = [:]
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    var hasActiveSessions: Bool { !sessions.isEmpty }

    func markStopping(prefixes: [URL]) {
        let targets = Set(prefixes.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        for (pid, var session) in sessions where targets.contains(session.prefix) {
            session.isStopping = true
            sessions[pid] = session
        }
        refresh()
    }

    func markStopFailed(prefix: URL) {
        let target = prefix.resolvingSymlinksInPath().standardizedFileURL
        for (pid, var session) in sessions where session.prefix == target {
            session.isStopping = false
            sessions[pid] = session
        }
        refresh()
    }

    func markPrefixStopped(prefix: URL) {
        let target = prefix.resolvingSymlinksInPath().standardizedFileURL
        let removed = sessions.values.filter { $0.prefix == target }
        for session in removed {
            sessions.removeValue(forKey: session.pid)
            try? FileManager.default.removeItem(at: session.lifecycleURL)
        }
        refresh()
        finishIfEmpty(hadSessions: !removed.isEmpty)
    }

    func beginMonitoring(pid: Int32, prefix: URL, executablePath: String, lifecycleURL: URL) {
        precondition(Thread.isMainThread)
        guard pid > 0 else { return }
        sessions[pid] = Session(
            pid: pid,
            prefix: prefix.resolvingSymlinksInPath().standardizedFileURL,
            displayName: URL(fileURLWithPath: executablePath).deletingPathExtension().lastPathComponent,
            lifecycleURL: lifecycleURL
        )
        installStatusItemIfNeeded()
        refresh()
        if timer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.cyderBottleImage()
            button.image?.accessibilityDescription = "Cyder 正在執行"
        }
        let menu = NSMenu(title: "Cyder")
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func poll() {
        var survivors: [Int32: Session] = [:]
        for (pid, var session) in sessions {
            let lifecycleState = Self.lifecycleState(at: session.lifecycleURL)
            if lifecycleState == "background" || lifecycleState == "attention" {
                session.primaryExited = true
            }
            if lifecycleState != "stopped" {
                survivors[pid] = session
            } else {
                try? FileManager.default.removeItem(at: session.lifecycleURL)
            }
        }
        let hadSessions = !sessions.isEmpty
        sessions = survivors
        refresh()
        finishIfEmpty(hadSessions: hadSessions)
    }

    private func finishIfEmpty(hadSessions: Bool) {
        guard hadSessions, sessions.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        onAllSessionsEnded?()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func refresh() {
        guard let menu = statusItem?.menu else { return }
        rebuild(menu)
        let waiting = sessions.values.contains { $0.primaryExited }
        statusItem?.button?.toolTip = waiting
            ? "Cyder 正在等待背景程序結束"
            : "Cyder 正在執行 Windows 程式"
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let ordered = sessions.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for session in ordered {
            let lifecycleState = Self.lifecycleState(at: session.lifecycleURL)
            let state = session.isStopping
                ? "正在結束 Windows 程序"
                : lifecycleState == "attention" ? "無法確認背景程序已結束"
                : session.primaryExited ? "正在等待背景程序結束" : "執行中"
            let item = NSMenuItem(title: "\(session.displayName) — \(state)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !ordered.isEmpty { menu.addItem(.separator()) }

        let preferences = menu.addItem(withTitle: "偏好設定…", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        let prefixes = activePrefixes
        let taskManager = menu.addItem(withTitle: "工作管理員…", action: nil, keyEquivalent: "")
        if prefixes.count == 1 {
            taskManager.action = #selector(openTaskManager(_:))
            taskManager.target = self
            taskManager.representedObject = prefixes[0] as NSURL
        } else if prefixes.count > 1 {
            let submenu = NSMenu(title: "工作管理員")
            for prefix in prefixes {
                let item = submenu.addItem(
                    withTitle: prefix.lastPathComponent,
                    action: #selector(openTaskManager(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = prefix as NSURL
            }
            taskManager.submenu = submenu
        }
        taskManager.isEnabled = !prefixes.isEmpty
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "結束所有 Cyder 程序…", action: #selector(stopWindowsEnvironment), keyEquivalent: "")
        quit.target = self
        quit.isEnabled = !prefixes.isEmpty
    }

    // First version monitors one normal launch; if the library starts more than
    // one app in a bottle, either entry still resolves to the same safe target.
    private var activePrefixes: [URL] {
        Array(Set(sessions.values.map { $0.prefix })).sorted { $0.path < $1.path }
    }

    var monitoredPrefixes: [URL] { activePrefixes }

    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func openTaskManager(_ sender: NSMenuItem) {
        if let prefix = sender.representedObject as? URL { onOpenTaskManager?(prefix) }
    }
    @objc private func stopWindowsEnvironment() {
        let prefixes = activePrefixes
        if !prefixes.isEmpty { onStopPrefixes?(prefixes) }
    }

    private static func lifecycleState(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { $0.isNewline }).first { $0.hasPrefix("state=") }
            .map { String($0.dropFirst("state=".count)) }
    }

    private static func cyderBottleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bottle = NSBezierPath()
            bottle.move(to: NSPoint(x: 7.1, y: 16.5))
            bottle.curve(to: NSPoint(x: 10.9, y: 16.5), controlPoint1: NSPoint(x: 8.0, y: 17.0), controlPoint2: NSPoint(x: 10.0, y: 17.0))
            bottle.line(to: NSPoint(x: 10.6, y: 13.1))
            bottle.curve(to: NSPoint(x: 14.9, y: 8.1), controlPoint1: NSPoint(x: 10.7, y: 11.4), controlPoint2: NSPoint(x: 14.2, y: 10.5))
            bottle.curve(to: NSPoint(x: 14.8, y: 3.6), controlPoint1: NSPoint(x: 15.6, y: 6.2), controlPoint2: NSPoint(x: 15.5, y: 4.5))
            bottle.curve(to: NSPoint(x: 9.0, y: 1.2), controlPoint1: NSPoint(x: 13.6, y: 1.9), controlPoint2: NSPoint(x: 11.5, y: 1.2))
            bottle.curve(to: NSPoint(x: 3.2, y: 3.6), controlPoint1: NSPoint(x: 6.5, y: 1.2), controlPoint2: NSPoint(x: 4.4, y: 1.9))
            bottle.curve(to: NSPoint(x: 3.1, y: 8.1), controlPoint1: NSPoint(x: 2.5, y: 4.5), controlPoint2: NSPoint(x: 2.4, y: 6.2))
            bottle.curve(to: NSPoint(x: 7.4, y: 13.1), controlPoint1: NSPoint(x: 3.8, y: 10.5), controlPoint2: NSPoint(x: 7.3, y: 11.4))
            bottle.close()
            NSColor.black.setFill()
            bottle.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
