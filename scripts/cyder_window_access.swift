import Cocoa
import ApplicationServices

/// Accessibility owns its own object namespace. No CGWindowID/AX/Win32 HWND
/// conversion, title matching, or process-wide activate-all-windows fallback.
final class CyderWindowAccess {
    typealias L = CyderLifecycle
    struct Node {
        let handle: AnyObject
        let title: String
        let capability: L.Capability
        let minimized: Bool?
        let focused: Bool?
    }
    enum Query { case windows([Node]), unavailable(L.Capability) }
    struct Driver {
        let scan: (L.ProcessID) -> Query
        let equal: (AnyObject, AnyObject) -> Bool
        let activate: (L.ProcessID, AnyObject, @escaping () -> Bool) -> L.WindowResult
        var requestPermission: () -> Void = {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        static var system: Driver { .init(scan: AXBackend.scan, equal: { CFEqual($0, $1) }, activate: AXBackend.activate) }
    }
    private struct Target { let stamp: L.Stamp; let node: Node }
    private struct Intent { let id: UUID; let window: L.WindowID; let expires: TimeInterval }
    private let queue = DispatchQueue(label: "local.cyder.window-state")
    private let workers = DispatchQueue(label: "local.cyder.window-workers", qos: .userInitiated, attributes: .concurrent)
    private let driver: Driver
    private let emit: (L.Event) -> Void
    private var snapshot: L.Snapshot?
    private var targets: [L.WindowID: Target] = [:]
    private var scanning: [L.ProcessID: UUID] = [:]
    private var scansInFlight = 0, actionsInFlight = 0, cursor = 0
    private var intent: Intent?
    private var closed = false
    private var permissionRequested = false
    private var timer: DispatchSourceTimer?

    init(driver: Driver = .system, event: @escaping (L.Event) -> Void) { self.driver = driver; emit = event }
    func update(_ snapshot: L.Snapshot) {
        queue.async { [self] in
            guard !closed else { return }
            self.snapshot = snapshot
            targets = targets.filter { valid($0.key, stamp: $0.value.stamp) }
            if let current = intent, !canAct(current) { finish(current, .unconfirmed) }
            guard snapshot.phase == .active else { close(); return }
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
                source.setEventHandler { [weak self] in self?.scanNext() }
                timer = source; source.resume()
            }
            // New processes are discovered immediately. Existing processes are
            // refreshed by the timer, not recursively by every published scan.
            let unknown = snapshot.processes.values.filter { $0.existence == .alive && $0.windowCapability == nil }
            for process in unknown.prefix(2) { scan(process) }
        }
    }
    func refresh() { queue.async { [self] in scanNext() } }
    func requestPermission() {
        queue.async { [self] in
            guard !closed, !permissionRequested else { return }
            permissionRequested = true
            workers.async { self.driver.requestPermission() }
        }
    }
    func stop() { queue.async { [self] in close() } }
    private func close() {
        closed = true; timer?.cancel(); timer = nil; intent = nil; targets.removeAll()
    }
    func focusChanged(to pid: Int32) {
        queue.async { [self] in
            guard let current = intent, pid != current.window.process.pid else { return }
            finish(current, .unconfirmed)
        }
    }
    private func valid(_ id: L.WindowID, stamp: L.Stamp) -> Bool {
        guard let snapshot, snapshot.phase == .active, snapshot.epoch == stamp.epoch,
              snapshot.environments[stamp.environment]?.generation == stamp.generation,
              snapshot.environments[stamp.environment]?.existence != .exited,
              let process = snapshot.processes[id.process] else { return false }
        return process.existence == .alive && process.environment == stamp.environment
    }
    private func scanNext() {
        guard !closed, let snapshot else { return }
        let processes = snapshot.processes.values.filter { $0.existence == .alive }
            .sorted { ($0.id.pid, $0.id.started) < ($1.id.pid, $1.id.started) }
        guard !processes.isEmpty else { return }
        for offset in 0..<processes.count {
            scan(processes[(cursor + offset) % processes.count])
            if scansInFlight >= 2 { break }
        }
        cursor = (cursor + 1) % processes.count
    }
    private func scan(_ process: L.ProcessRecord) {
        guard !closed, scansInFlight < 2, scanning[process.id] == nil, let snapshot,
              let environment = snapshot.environments[process.environment], environment.existence != .exited else { return }
        let stamp = L.Stamp(epoch: snapshot.epoch, environment: environment.id, generation: environment.generation)
        let token = UUID(), id = process.id
        scanning[id] = token; scansInFlight += 1
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.closed, self.scanning[id] == token else { return }
            self.emit(.windowSnapshot(stamp, id, source: "accessibility", windows: nil, capability: .temporarilyUnavailable))
            // The physical scan retains its slot until it actually returns.
        }
        workers.async { [self] in
            let result = driver.scan(id)
            queue.async {
                self.scansInFlight -= 1
                guard self.scanning.removeValue(forKey: id) == token, !self.closed,
                      self.valid(.init(process: id, source: "accessibility", token: ""), stamp: stamp) else { return }
                switch result {
                case .unavailable(let capability):
                    self.emit(.windowSnapshot(stamp, id, source: "accessibility", windows: nil, capability: capability))
                case .windows(let nodes):
                    let old = self.targets.filter { $0.key.process == id && $0.value.stamp == stamp }
                    self.targets = self.targets.filter { $0.key.process != id }
                    var windows: [L.Window] = []
                    for node in nodes.prefix(64) {
                        let existing = old.first { self.driver.equal($0.value.node.handle, node.handle) }?.key
                        let windowID = existing ?? L.WindowID(process: id, source: "accessibility", token: UUID().uuidString)
                        self.targets[windowID] = .init(stamp: stamp, node: node)
                        windows.append(.init(id: windowID, title: node.title, capability: node.capability,
                                             minimized: node.minimized, focused: node.focused))
                    }
                    self.emit(.windowSnapshot(stamp, id, source: "accessibility", windows: windows, capability: .available))
                }
            }
        }
    }
    func activate(stamp: L.Stamp, window: L.WindowID, operation: UUID) {
        queue.async { [self] in
            guard !closed, actionsInFlight < 2, let target = targets[window], target.stamp == stamp,
                  target.node.capability == .available, valid(window, stamp: stamp) else {
                emit(.windowActionFinished(operation, .unconfirmed)); return
            }
            let current = Intent(id: operation, window: window, expires: ProcessInfo.processInfo.systemUptime + 3)
            intent = current; actionsInFlight += 1
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.intent?.id == operation else { return }
                self.emit(.windowActionProgress(operation))
            }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(current, .unconfirmed) }
            workers.async { [self] in
                let allowed = { self.queue.sync { self.canAct(current) } }
                let result = allowed() ? driver.activate(window.process, target.node.handle, allowed) : .unconfirmed
                queue.async {
                    self.actionsInFlight -= 1
                    self.finish(current, result)
                }
            }
        }
    }
    private func canAct(_ current: Intent) -> Bool {
        guard !closed, intent?.id == current.id, ProcessInfo.processInfo.systemUptime < current.expires,
              snapshot?.windowAction?.id == current.id, snapshot?.windowAction?.result == nil,
              snapshot?.windows[current.window]?.capability == .available,
              let target = targets[current.window], target.node.capability == .available else { return false }
        return valid(current.window, stamp: target.stamp)
    }
    private func finish(_ current: Intent, _ result: L.WindowResult) {
        guard !closed, intent?.id == current.id else { return }
        intent = nil
        emit(.windowActionFinished(current.id, result))
    }
}

private enum AXBackend {
    typealias L = CyderLifecycle
    static func prepared(_ element: AXUIElement) -> AXUIElement {
        // AppKit animations can exceed 150 ms. This is a per-message worker
        // timeout; the coordinator still expires the entire intent at 3 s.
        _ = AXUIElementSetMessagingTimeout(element, 0.5); return element
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    static func flag(_ element: AXUIElement, _ attribute: String) -> Bool? { value(element, attribute) as? Bool }
    static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }
    static func windows(_ app: AXUIElement) -> [AXUIElement]? {
        var count = 0, values: CFArray?
        guard AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success,
              (0...64).contains(count) else { return nil }
        if count == 0 { return [] }
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &values) == .success,
              let values = values as? [AXUIElement] else { return nil }
        return values.map(prepared)
    }
    static func scan(_ process: L.ProcessID) -> CyderWindowAccess.Query {
        precondition(!Thread.isMainThread)
        guard AXIsProcessTrusted() else { return .unavailable(.permissionRequired) }
        guard CyderProcessEvidence.live(process) else { return .unavailable(.temporarilyUnavailable) }
        let app = prepared(AXUIElementCreateApplication(process.pid))
        guard let windows = windows(app) else { return .unavailable(.temporarilyUnavailable) }
        let focus = value(app, kAXFocusedWindowAttribute)
        let canFront = settable(app, kAXFrontmostAttribute)
        var result: [CyderWindowAccess.Node] = []
        let expires = ProcessInfo.processInfo.systemUptime + 1
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < expires else { return .unavailable(.temporarilyUnavailable) }
            var pid: pid_t = 0, actions: CFArray?
            guard AXUIElementGetPid(window, &pid) == .success, pid == process.pid else { continue }
            let raised = AXUIElementCopyActionNames(window, &actions) == .success && (actions as? [String] ?? []).contains(kAXRaiseAction)
            let minimized = flag(window, kAXMinimizedAttribute)
            let capable = canFront && raised && minimized != nil && (minimized != true || settable(window, kAXMinimizedAttribute))
            let title = (value(window, kAXTitleAttribute) as? String ?? "視窗")
                .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            result.append(.init(handle: window, title: String(title.prefix(100)), capability: capable ? .available : .unsupported,
                minimized: minimized, focused: focus.map { CFEqual($0, window) }))
        }
        guard CyderProcessEvidence.live(process) else { return .unavailable(.temporarilyUnavailable) }
        return .windows(result)
    }
    static func frontmost() -> Int32? {
        let system = prepared(AXUIElementCreateSystemWide())
        guard let app = value(system, kAXFocusedApplicationAttribute), CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
    }
    static func activate(_ process: L.ProcessID, _ handle: AnyObject, _ allowed: @escaping () -> Bool) -> L.WindowResult {
        precondition(!Thread.isMainThread)
        func unconfirmed(_ stage: String) -> L.WindowResult {
            CyderDiagnostics.shared.info("Window activation unconfirmed at " + stage)
            return .unconfirmed
        }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        guard CFGetTypeID(handle) == AXUIElementGetTypeID() else { return .unsupported }
        guard CyderProcessEvidence.live(process) else {
            return CyderProcessEvidence.hasEnded(process) ? .processEnded : .unconfirmed
        }
        let app = prepared(AXUIElementCreateApplication(process.pid)), window = prepared(handle as! AXUIElement)
        guard let initialFocus = frontmost() else { return unconfirmed("initial focus") }
        let expires = ProcessInfo.processInfo.systemUptime + 3
        func current() -> Bool {
            guard ProcessInfo.processInfo.systemUptime < expires, allowed(), CyderProcessEvidence.live(process), let focus = frontmost(), allowed() else { return false }
            return focus == initialFocus || focus == process.pid
        }
        func observe() -> L.WindowResult {
            // Observe only; a slow response never authorizes another activation.
            while ProcessInfo.processInfo.systemUptime < expires && allowed() && CyderProcessEvidence.live(process) {
                // During a transition the system may temporarily omit its focused
                // application. Observe within the same budget; do not resend intent.
                if let focus = frontmost(), focus != initialFocus && focus != process.pid { break }
                if flag(app, kAXFrontmostAttribute) == true && flag(window, kAXMinimizedAttribute) == false &&
                    value(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true && allowed() { return .shown }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return unconfirmed("result observation")
        }
        guard let currentWindows = windows(app) else { return unconfirmed("window enumeration") }
        guard currentWindows.contains(where: { CFEqual($0, window) }) else { return .windowGone }
        if flag(window, kAXMinimizedAttribute) == true {
            guard current(), settable(window, kAXMinimizedAttribute), current() else { return unconfirmed("unminimize eligibility") }
            let unminimizeReply = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if unminimizeReply == .cannotComplete { return observe() }
            guard unminimizeReply == .success else { return unconfirmed("unminimize request (\(unminimizeReply.rawValue))") }
        }
        guard current() else { return unconfirmed("raise eligibility") }
        // CannotComplete may mean the action happened. Never automatically resend.
        let raiseReply = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raiseReply == .cannotComplete { return observe() }
        guard raiseReply == .success else { return unconfirmed("raise request (\(raiseReply.rawValue))") }
        if value(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) != true {
            guard current(), settable(window, kAXMainAttribute), current() else { return unconfirmed("main eligibility") }
            let mainReply = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            if mainReply == .cannotComplete { return observe() }
            guard mainReply == .success else { return unconfirmed("main request (\(mainReply.rawValue))") }
        }
        guard value(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true,
              current() else { return unconfirmed("focused target before foreground") }
        let foregroundReply = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if foregroundReply == .cannotComplete { return observe() }
        guard foregroundReply == .success else { return unconfirmed("foreground request (\(foregroundReply.rawValue))") }
        return observe()
    }
}
