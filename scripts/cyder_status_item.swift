// Menu-bar lifecycle for native Cyder launches on macOS 11 and newer.
import Cocoa
import Foundation

final class CyderStatusItemController: NSObject, NSMenuDelegate {
    private enum VisualState: Equatable {
        case starting
        case running
        case background
        case stopping
        case attention
    }

    private struct Session {
        let pid: Int32
        let prefix: URL
        let displayName: String
        let lifecycleURL: URL
        let startedAt = Date()
        var activated = false
        var primaryExited = false
        var backgroundSince: Date?
        var isStopping = false
    }

    var onOpenPreferences: (() -> Void)?
    var onOpenGameLibrary: (() -> Void)?
    var onOpenTaskManager: ((URL) -> Void)?
    var onStopPrefixes: (([URL]) -> Void)?
    var onAllSessionsEnded: (() -> Void)?

    private var sessions: [Int32: Session] = [:]
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var visualState: VisualState = .starting
    private var animationFrame = 0
    private var uiVisible = false

    var hasActiveSessions: Bool { !sessions.isEmpty }

    /// Keep the menu-bar item available while a Cyder-owned window is open,
    /// even when no Wine process is currently being monitored.
    func setUIVisible(_ visible: Bool) {
        precondition(Thread.isMainThread)
        uiVisible = visible
        if visible {
            installStatusItemIfNeeded()
            refresh()
        } else if sessions.isEmpty {
            removeStatusItemIfUnused()
        } else {
            refresh()
        }
    }

    func markActivated(pid: Int32) {
        guard var session = sessions[pid] else { return }
        session.activated = true
        sessions[pid] = session
        refresh()
    }

    func cancelMonitoring(pid: Int32, notifyWhenEmpty: Bool = true) {
        guard let session = sessions.removeValue(forKey: pid) else { return }
        try? FileManager.default.removeItem(at: session.lifecycleURL)
        refresh()
        if notifyWhenEmpty {
            finishIfEmpty(hadSessions: true)
        } else if sessions.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
            animationTimer?.invalidate()
            animationTimer = nil
            removeStatusItemIfUnused()
        }
    }

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
        if pollTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.cyderBottleImage(liquidLevel: 1, showsAttention: false)
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
                if session.backgroundSince == nil { session.backgroundSince = Date() }
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
        pollTimer?.invalidate()
        pollTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        if uiVisible {
            refresh()
        } else {
            removeStatusItemIfUnused()
        }
        onAllSessionsEnded?()
    }

    private func removeStatusItemIfUnused() {
        guard !uiVisible, sessions.isEmpty else { return }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func refresh() {
        guard let menu = statusItem?.menu else { return }
        rebuild(menu)
        let nextState = currentVisualState
        if nextState != visualState {
            visualState = nextState
            animationFrame = 0
        }
        updateStatusImage()
        updateAnimationTimer()
        statusItem?.button?.toolTip = tooltip(for: nextState)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let ordered = sessions.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for session in ordered {
            let lifecycleState = Self.lifecycleState(at: session.lifecycleURL)
            let state = session.isStopping
                ? "正在結束 Windows 程序"
                : lifecycleState == "attention" ? "無法確認背景程序已結束"
                : session.primaryExited
                    ? "正在等待背景程序結束 · \(Self.elapsed(since: session.backgroundSince))"
                    : session.activated ? "執行中" : "正在啟動"
            let item = NSMenuItem(title: "\(session.displayName) — \(state)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !ordered.isEmpty { menu.addItem(.separator()) }

        let preferences = menu.addItem(withTitle: "偏好設定…", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        let library = menu.addItem(withTitle: "遊戲庫…", action: #selector(openGameLibrary), keyEquivalent: "")
        library.target = self
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
                    withTitle: displayName(for: prefix),
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
        quit.isEnabled = !prefixes.isEmpty && !sessions.values.contains { $0.isStopping }
    }

    private var currentVisualState: VisualState {
        if sessions.values.contains(where: { Self.lifecycleState(at: $0.lifecycleURL) == "attention" }) {
            return .attention
        }
        if sessions.values.contains(where: { $0.isStopping }) { return .stopping }
        if sessions.values.contains(where: { $0.primaryExited }) { return .background }
        if sessions.values.contains(where: { !$0.activated }) { return .starting }
        return .running
    }

    private func updateAnimationTimer() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = !reduceMotion && visualState != .running
        if shouldAnimate, animationTimer == nil {
            let timer = Timer(timeInterval: 0.2, target: self, selector: #selector(advanceAnimation), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !shouldAnimate {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    @objc private func advanceAnimation() {
        animationFrame += 1
        updateStatusImage()
    }

    private func updateStatusImage() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let parameters: (liquid: CGFloat, attention: Bool)
        switch visualState {
        case .starting:
            parameters = (1, false)
        case .running:
            parameters = (1, false)
        case .background:
            parameters = (1, false)
        case .stopping:
            parameters = (Self.forcedStopLiquidLevel(animationFrame: animationFrame, reduceMotion: reduceMotion), false)
        case .attention:
            let visible = reduceMotion || animationFrame >= 8 || (animationFrame / 2).isMultiple(of: 2)
            parameters = (0.45, visible)
        }
        statusItem?.button?.image = Self.cyderBottleImage(
            liquidLevel: parameters.liquid,
            showsAttention: parameters.attention
        )
    }

    private func tooltip(for state: VisualState) -> String {
        let count = Set(sessions.values.map { $0.prefix }).count
        switch state {
        case .starting: return "Cyder 正在啟動 Windows 環境"
        case .running: return "\(count) 個 Cyder Windows 環境執行中"
        case .background: return "Cyder 正在等待背景程序結束"
        case .stopping: return "Cyder 正在結束 Windows 程序"
        case .attention: return "Cyder 無法確認背景程序已結束"
        }
    }

    private func displayName(for prefix: URL) -> String {
        let names = sessions.values
            .filter { $0.prefix == prefix }
            .map(\.displayName)
            .sorted()
        return names.first ?? prefix.lastPathComponent
    }

    // First version monitors one normal launch; if the library starts more than
    // one app in a bottle, either entry still resolves to the same safe target.
    private var activePrefixes: [URL] {
        Array(Set(sessions.values.map { $0.prefix })).sorted { $0.path < $1.path }
    }

    var monitoredPrefixes: [URL] { activePrefixes }

    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func openGameLibrary() { onOpenGameLibrary?() }
    @objc private func openTaskManager(_ sender: NSMenuItem) {
        if let prefix = sender.representedObject as? URL { onOpenTaskManager?(prefix) }
    }
    @objc private func stopWindowsEnvironment() {
        let prefixes = activePrefixes
        if !prefixes.isEmpty { onStopPrefixes?(prefixes) }
    }

    /// Drain the bottle only while the user-confirmed managed shutdown is in progress.
    /// At 0.2s per frame this reaches the resting level in about 1.4 seconds.
    private static func forcedStopLiquidLevel(animationFrame: Int, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return 0.25 }
        return max(0.12, 1 - CGFloat(animationFrame) / 7.0)
    }

    private static func lifecycleState(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { $0.isNewline }).first { $0.hasPrefix("state=") }
            .map { String($0.dropFirst("state=".count)) }
    }

    private static func elapsed(since date: Date?) -> String {
        guard let date else { return "0 秒" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private static func cyderBottleImage(
        liquidLevel: CGFloat,
        showsAttention: Bool
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bottle = NSBezierPath()
            // Simple tall-neck decanter silhouette with a smooth arced bottom.
            bottle.move(to: NSPoint(x: 6.4, y: 16.7))
            bottle.curve(to: NSPoint(x: 11.6, y: 16.7), controlPoint1: NSPoint(x: 6.5, y: 17.1), controlPoint2: NSPoint(x: 11.5, y: 17.1))
            bottle.line(to: NSPoint(x: 11.2, y: 16.0))
            bottle.curve(to: NSPoint(x: 10.4, y: 14.5), controlPoint1: NSPoint(x: 10.9, y: 15.5), controlPoint2: NSPoint(x: 10.55, y: 15.0))
            bottle.curve(to: NSPoint(x: 10.1, y: 12.4), controlPoint1: NSPoint(x: 10.25, y: 13.8), controlPoint2: NSPoint(x: 10.25, y: 13.2))
            bottle.curve(to: NSPoint(x: 10.15, y: 10.5), controlPoint1: NSPoint(x: 10.05, y: 11.5), controlPoint2: NSPoint(x: 10.05, y: 11.0))
            bottle.curve(to: NSPoint(x: 12.4, y: 8.0), controlPoint1: NSPoint(x: 10.4, y: 10.1), controlPoint2: NSPoint(x: 11.4, y: 9.1))
            bottle.curve(to: NSPoint(x: 14.8, y: 6.1), controlPoint1: NSPoint(x: 13.5, y: 7.1), controlPoint2: NSPoint(x: 14.6, y: 6.6))
            bottle.curve(to: NSPoint(x: 14.9, y: 4.0), controlPoint1: NSPoint(x: 15.1, y: 5.3), controlPoint2: NSPoint(x: 15.0, y: 4.5))
            bottle.curve(to: NSPoint(x: 12.0, y: 1.25), controlPoint1: NSPoint(x: 14.7, y: 2.8), controlPoint2: NSPoint(x: 13.6, y: 1.35))
            bottle.curve(to: NSPoint(x: 6.0, y: 1.25), controlPoint1: NSPoint(x: 10.6, y: 0.55), controlPoint2: NSPoint(x: 7.4, y: 0.55))
            bottle.curve(to: NSPoint(x: 3.1, y: 4.0), controlPoint1: NSPoint(x: 4.4, y: 1.35), controlPoint2: NSPoint(x: 3.3, y: 2.8))
            bottle.curve(to: NSPoint(x: 3.2, y: 6.1), controlPoint1: NSPoint(x: 3.0, y: 4.5), controlPoint2: NSPoint(x: 3.1, y: 5.3))
            bottle.curve(to: NSPoint(x: 5.6, y: 8.0), controlPoint1: NSPoint(x: 3.4, y: 6.6), controlPoint2: NSPoint(x: 4.5, y: 7.1))
            bottle.curve(to: NSPoint(x: 7.85, y: 10.5), controlPoint1: NSPoint(x: 6.6, y: 9.1), controlPoint2: NSPoint(x: 7.6, y: 10.1))
            bottle.curve(to: NSPoint(x: 7.9, y: 12.4), controlPoint1: NSPoint(x: 7.8, y: 11.0), controlPoint2: NSPoint(x: 7.8, y: 11.5))
            bottle.curve(to: NSPoint(x: 7.6, y: 14.5), controlPoint1: NSPoint(x: 7.75, y: 13.2), controlPoint2: NSPoint(x: 7.4, y: 13.8))
            bottle.line(to: NSPoint(x: 7.0, y: 16.0))
            bottle.close()
            bottle.lineWidth = 1.35
            bottle.lineJoinStyle = .round

            // A full bottle should be solid through the shoulders and neck. For
            // the drain animation, retain the clipped liquid edge below that.
            let clampedLiquidLevel = max(0, min(1, liquidLevel))
            NSColor.black.setFill()
            if clampedLiquidLevel >= 0.999 {
                bottle.fill()
            } else if clampedLiquidLevel > 0 {
                NSGraphicsContext.saveGraphicsState()
                bottle.addClip()
                let level = 1.2 + clampedLiquidLevel * 11.2
                NSBezierPath(rect: NSRect(x: 2.5, y: 1.1, width: 13, height: level - 1.1)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            NSColor.black.setStroke()
            bottle.stroke()
            if showsAttention {
                let mark = NSBezierPath(roundedRect: NSRect(x: 14.6, y: 11.0, width: 1.5, height: 4.5), xRadius: 0.7, yRadius: 0.7)
                mark.fill()
                NSBezierPath(ovalIn: NSRect(x: 14.6, y: 8.8, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
