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
        let id: String
        var pid: Int32
        let prefix: URL
        let rootDisplayName: String
        let fromSentinel: Bool
        let startedAt = Date()
        var displayName: String
        var activated = false
        var hasForeground = false
        var leftoverNames: [String] = []
        var isStopping = false
        var helperConnected: Bool
        var adoptedPIDs: Set<Int32>
        var foregroundPIDs: Set<Int32> = []
    }

    var onOpenPreferences: (() -> Void)?
    var onOpenGameLibrary: (() -> Void)?
    var onOpenTaskManager: ((URL) -> Void)?
    var onStopPrefixes: (([URL]) -> Void)?
    var onAllSessionsEnded: (() -> Void)?
    var onSessionEnded: ((URL) -> Void)?

    private var sessions: [String: Session] = [:]
    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var visualState: VisualState = .starting
    private var animationFrame = 0
    private var uiVisible = false
    private var menuIsOpen = false
    private var processSources: [Int32: DispatchSourceProcess] = [:]
    private let processQueue = DispatchQueue(label: "local.cyder.status-proc")

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

    func markLaunchStarted() {
        precondition(Thread.isMainThread)
        visualState = .starting
        installStatusItemIfNeeded()
        refresh()
    }

    func adoptWindowedProcess(pid: Int32, prefix: String, name: String?) {
        precondition(Thread.isMainThread)
        guard pid > 0 else { return }
        let target = (prefix as NSString).standardizingPath
        let key: String?
        if let existing = sessions.first(where: { $0.value.adoptedPIDs.contains(pid) })?.key {
            key = existing
        } else {
            let starting = sessions.filter {
                $0.value.prefix.path == target && !$0.value.activated && !$0.value.hasForeground
            }
            let exactlyOneStartingGroup = starting.count == 1
            if exactlyOneStartingGroup {
                key = starting.first?.key
            } else if let treeOwner = sessions.first(where: { session in
                session.value.prefix.path == target
                    && session.value.adoptedPIDs.contains(where: { wineProcessTreeIDs(root: $0).contains(pid) })
            })?.key {
                key = treeOwner
            } else {
                key = nil
            }
        }
        guard let key, var session = sessions[key] else { return }
        session.adoptedPIDs.insert(pid)
        session.foregroundPIDs.insert(pid)
        applyWindowedHandoff(&session, preferredName: name)
        sessions[key] = session
        watchPID(pid)
        refresh()
    }

    func markActivated(pid: Int32) {
        guard let key = sessions.first(where: { $0.value.pid == pid || $0.value.adoptedPIDs.contains(pid) })?.key,
              var session = sessions[key] else { return }
        session.activated = true
        session.hasForeground = true
        sessions[key] = session
        refresh()
    }

    func markActivated(id: String) {
        precondition(Thread.isMainThread)
        guard var session = sessions[id] else { return }
        session.activated = true
        session.hasForeground = true
        sessions[id] = session
        refresh()
    }

    func hasLiveWatchedPIDs(id: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let session = sessions[id] else { return false }
        if session.pid > 0, kill(session.pid, 0) == 0 { return true }
        return session.adoptedPIDs.contains { kill($0, 0) == 0 }
    }

    func hasClaimedWindow(id: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let session = sessions[id] else { return false }
        return session.hasForeground || !session.foregroundPIDs.isEmpty
    }

    func cancelMonitoring(pid: Int32, notifyWhenEmpty: Bool = true) {
        guard let key = sessions.first(where: { $0.value.pid == pid })?.key,
              sessions.removeValue(forKey: key) != nil else { return }
        refresh()
        if notifyWhenEmpty {
            finishIfEmpty(hadSessions: true)
        } else if sessions.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
            removeStatusItemIfUnused()
        }
    }

    func markStopping(prefixes: [URL]) {
        let targets = Set(prefixes.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        for (key, var session) in sessions where targets.contains(session.prefix) {
            session.isStopping = true
            sessions[key] = session
        }
        refresh()
    }

    func markStopFailed(prefix: URL) {
        let target = prefix.resolvingSymlinksInPath().standardizedFileURL
        for (key, var session) in sessions where session.prefix == target {
            session.isStopping = false
            sessions[key] = session
        }
        refresh()
    }

    func markPrefixStopped(prefix: URL) {
        let target = prefix.resolvingSymlinksInPath().standardizedFileURL
        let removed = sessions.filter { $0.value.prefix == target }
        for key in removed.keys {
            sessions.removeValue(forKey: key)
        }
        refresh()
        finishIfEmpty(hadSessions: !removed.isEmpty)
    }

    func beginLaunch(id: String, prefix: URL, executableName: String, pid: Int32) {
        precondition(Thread.isMainThread)
        let name = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "Wine" : name
        sessions[id] = Session(
            id: id,
            pid: pid,
            prefix: prefix.resolvingSymlinksInPath().standardizedFileURL,
            rootDisplayName: display,
            fromSentinel: true,
            displayName: display,
            helperConnected: false,
            adoptedPIDs: pid > 0 ? [pid] : []
        )
        installStatusItemIfNeeded()
        watchPID(pid)
        refresh()
    }

    func updateLaunch(id: String, pid: Int32, holders: [CyderSentinelHolder]) {
        precondition(Thread.isMainThread)
        guard var session = sessions[id] else { return }
        _ = holders
        if pid > 0 {
            session.pid = pid
            session.adoptedPIDs.insert(pid)
            sessions[id] = session
            watchPID(pid)
            refresh()
        }
    }

    func noteProcessExited(_ pid: Int32) {
        precondition(Thread.isMainThread)
        handleProcessExit(pid)
    }

    func noteHelperDisconnected(id: String) {
        precondition(Thread.isMainThread)
        CyderDiagnostics.shared.info("sentinel helper disconnected id=\(id)")
        guard var session = sessions[id] else { return }
        session.helperConnected = false
        sessions[id] = session
        if !session.activated && !session.hasForeground { return }
        finishSessionIfIdle(id)
    }

    func endLaunch(id: String) {
        precondition(Thread.isMainThread)
        guard let session = sessions.removeValue(forKey: id) else { return }
        onSessionEnded?(session.prefix)
        refresh()
        finishIfEmpty(hadSessions: true)
    }

    func attachRootPID(id: String, pid: Int32) {
        precondition(Thread.isMainThread)
        guard pid > 0, var session = sessions[id] else { return }
        session.pid = pid
        session.adoptedPIDs.insert(pid)
        sessions[id] = session
        watchPID(pid)
        refresh()
    }

    func beginMonitoring(pid: Int32, prefix: URL, executablePath: String, lifecycleURL: URL) {
        precondition(Thread.isMainThread)
        guard pid > 0 else { return }
        _ = lifecycleURL
        let name = URL(fileURLWithPath: executablePath).deletingPathExtension().lastPathComponent
        let id = "pid:\(pid)"
        sessions[id] = Session(
            id: id,
            pid: pid,
            prefix: prefix.resolvingSymlinksInPath().standardizedFileURL,
            rootDisplayName: name,
            fromSentinel: false,
            displayName: name,
            helperConnected: false,
            adoptedPIDs: [pid]
        )
        installStatusItemIfNeeded()
        watchPID(pid)
        refresh()
    }

    func isMonitoring(prefix: String) -> Bool {
        precondition(Thread.isMainThread)
        let target = (prefix as NSString).standardizingPath
        return sessions.values.contains { $0.prefix.path == target }
    }

    private func watchPID(_ pid: Int32) {
        guard pid > 0 else { return }
        processQueue.async { [weak self] in
            self?.watchPIDOnQueue(pid)
        }
    }

    private func watchPIDOnQueue(_ pid: Int32) {
        guard processSources[pid] == nil else { return }
        if kill(pid, 0) != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.handleProcessExit(pid)
            }
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: [.exit, .fork, .exec],
            queue: processQueue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if events.contains(.fork) || events.contains(.exec) {
                let children = wineProcessTreeIDs(root: pid)
                for child in children {
                    self.watchPIDOnQueue(child)
                }
                DispatchQueue.main.async {
                    self.handleProcessSpawn(root: pid, children: children)
                }
            }
            if events.contains(.exit) {
                source.cancel()
                self.processSources.removeValue(forKey: pid)
                DispatchQueue.main.async {
                    self.handleProcessExit(pid)
                }
            }
        }
        processSources[pid] = source
        source.resume()
    }

    private func handleProcessSpawn(root: Int32, children: Set<Int32>) {
        precondition(Thread.isMainThread)
        var changed = false
        var probePIDs = Set<Int32>()
        var probePrefix = ""
        for (key, var session) in sessions {
            let related = session.adoptedPIDs.contains(root)
                || !session.adoptedPIDs.isDisjoint(with: children)
            guard related else { continue }
            session.adoptedPIDs.insert(root)
            session.adoptedPIDs.formUnion(children)
            sessions[key] = session
            probePIDs = session.adoptedPIDs
            probePrefix = session.prefix.path
            changed = true
        }
        if changed {
            refresh()
            probeWindows(ownedBy: probePIDs, prefix: probePrefix)
        }
    }

    private func handleProcessExit(_ pid: Int32) {
        precondition(Thread.isMainThread)
        let affected = sessions.filter { $0.value.adoptedPIDs.contains(pid) || $0.value.pid == pid }
        for (id, _) in affected {
            guard var session = sessions[id] else { continue }
            session.adoptedPIDs.remove(pid)
            if session.pid == pid { session.pid = 0 }
            session.foregroundPIDs.remove(pid)
            let live = session.adoptedPIDs.filter { kill($0, 0) == 0 }
            session.adoptedPIDs = live
            session.foregroundPIDs = session.foregroundPIDs.intersection(live)
            if !session.foregroundPIDs.isEmpty {
                sessions[id] = session
            } else if !live.isEmpty {
                session.hasForeground = false
                session.leftoverNames = leftoverNames(for: session)
                sessions[id] = session
            } else {
                session.hasForeground = false
                session.leftoverNames = []
                sessions[id] = session
                finishSessionIfIdle(id)
            }
        }
        if !affected.isEmpty { refresh() }
    }

    private func leftoverNames(for session: Session) -> [String] {
        session.adoptedPIDs.compactMap { pid -> String? in
            guard kill(pid, 0) == 0 else { return nil }
            return cyderWineArgvName(pid: pid)
        }.filter { $0.caseInsensitiveCompare(session.displayName) != .orderedSame }
    }

    private func finishSessionIfIdle(_ id: String) {
        guard var session = sessions[id] else { return }
        let live = session.adoptedPIDs.filter { kill($0, 0) == 0 }
        session.adoptedPIDs = live
        if !live.isEmpty {
            session.hasForeground = false
            session.leftoverNames = leftoverNames(for: session)
            sessions[id] = session
            refresh()
            return
        }
        if !session.activated {
            session.hasForeground = false
            session.leftoverNames = []
            sessions[id] = session
            refresh()
            return
        }
        endLaunch(id: id)
    }

    private func probeWindows(ownedBy pids: Set<Int32>, prefix: String) {
        guard !pids.isEmpty, !prefix.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let windows = wineOnscreenWindows(ownedBy: pids)
            guard !windows.isEmpty else { return }
            DispatchQueue.main.async {
                for window in windows {
                    self?.adoptWindowedProcess(
                        pid: window.pid,
                        prefix: prefix,
                        name: window.ownerName
                    )
                }
            }
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

    private func applyWindowedHandoff(_ session: inout Session, preferredName: String?) {
        session.activated = true
        session.hasForeground = true
        session.leftoverNames = []
        if let useful = preferredName.flatMap(cyderUsefulWindowOwnerName),
           useful.caseInsensitiveCompare(session.rootDisplayName) != .orderedSame {
            session.displayName = useful
        }
    }

    private func finishIfEmpty(hadSessions: Bool) {
        guard hadSessions, sessions.isEmpty else { return }
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

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        animationTimer?.invalidate()
        animationTimer = nil
        rebuild(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func refresh() {
        if menuIsOpen { return }
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
            let state: String
            if session.isStopping {
                state = "正在結束 Windows 程序"
            } else if session.hasForeground {
                state = "執行中"
            } else if !session.activated {
                state = "正在啟動"
            } else if let leftover = session.leftoverNames.first {
                state = "等待 \(leftover) 退出"
            } else {
                state = "已結束，等待背景程序退出"
            }
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
        if sessions.values.contains(where: { $0.isStopping }) { return .stopping }
        if sessions.values.contains(where: { !$0.activated && !$0.hasForeground }) { return .starting }
        if sessions.values.contains(where: { $0.activated && !$0.hasForeground }) { return .background }
        return .running
    }

    private func updateAnimationTimer() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = !reduceMotion && visualState != .running && !menuIsOpen
        if shouldAnimate, animationTimer == nil {
            let timer = Timer(timeInterval: 0.2, target: self, selector: #selector(advanceAnimation), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .default)
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
        switch state {
        case .starting: return "Cyder 正在啟動 Windows 環境"
        case .running:
            if sessions.count == 1, let name = sessions.values.first?.displayName {
                return "\(name) 執行中"
            }
            return "\(sessions.count) 個程式執行中"
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
