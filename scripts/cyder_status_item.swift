// Menu-bar lifecycle for native Cyder launches on macOS 11 and newer.
import Cocoa
import Foundation
import Darwin

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
        var root: CyderLifecycle.ProcessID?
        let authority: CyderLaunchObserver.Authority?
        var nativeRoot: CyderLaunchObserver.NativeRoot? = nil
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
        var adoptedPIDs: Set<CyderLifecycle.ProcessID>
        var foregroundPIDs: Set<CyderLifecycle.ProcessID> = []
    }

    var onWindowConfirmed: ((String) -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onOpenGameLibrary: (() -> Void)?
    var onOpenTaskManager: ((URL) -> Void)?
    var onStopPrefixes: (([URL]) -> Void)?
    var onQuit: (() -> Void)?
    var onExecuteStop: ((URL, CyderLifecycle.Stamp, UUID) -> Void)?
    var onLifecycleIdle: (() -> Void)?
    var onSessionEnded: ((URL) -> Void)?
    var onManageEnvironment: ((URL, @escaping (String?) -> Void) -> Void)?
    private var environmentPrefixes: [String: String] = [:]
    var onReconcileEnvironment: ((CyderLifecycle.Stamp) -> Void)?
    let lifecycleEpoch = UUID()

    private var sessions: [String: Session] = [:]
    private var exitedProcesses: Set<CyderLifecycle.ProcessID> = []
    private var isQuiescing = false
    private var pendingEnvironmentAttachments = 0
    private var claimTokens: [String: UUID] = [:]
    private var claimCompletions: [String: () -> Void] = [:]
    private var claimInFlight = 0
    private var sessionVersions: [String: UUID] = [:]
    private var lastPublishedWork: Bool?
    private var externalIngressPending = false
    private var launchIngressPending = false
    private var latestLifecycle = CyderLifecycle.State().snapshot
    private var hasLifecycleSnapshot = false
    private lazy var lifecycleStore: CyderLifecycleStore = CyderLifecycleStore(epoch: lifecycleEpoch) { [weak self] snapshot, effects in
        guard let self else { return }
        self.applyLifecycleSnapshot(snapshot)
        guard !self.isQuiescing else { return }
        for effect in effects {
            if case .reconcile(let stamp) = effect { self.onReconcileEnvironment?(stamp) }
            if case .stop(let stamp, let operation) = effect,
               let environment = snapshot.environments[stamp.environment] {
                self.onExecuteStop?(URL(fileURLWithPath: environment.prefix), stamp, operation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.lifecycleStore.send(.stopFinished(stamp, operation, success: false))
                }
            }
        }
    }
    private(set) var menuMutationCount = 0
    private(set) var statusRemovalCount = 0
    var hasStatusItem: Bool { statusItem != nil }
    var lifecycleSnapshot: CyderLifecycle.Snapshot { latestLifecycle }

    func quiesce() {
        precondition(Thread.isMainThread)
        guard !isQuiescing else { return }
        isQuiescing = true
        animationTimer?.invalidate()
        animationTimer = nil
        lifecycleStore.send(.quit)
        claimTokens.removeAll()
        let completions = Array(claimCompletions.values)
        claimCompletions.removeAll()
        completions.forEach { $0() }
        processQueue.async { [weak self] in
            guard let self else { return }
            self.processQuiescing = true
            for source in self.processSources.values { source.cancel() }
            self.processSources.removeAll()
        }
    }

    func requestStop(prefixes: [URL]) {
        guard !isQuiescing else { return }
        let paths = Set(prefixes.map(\.path))
        for environment in latestLifecycle.environments.values where paths.contains(environment.prefix) {
            let stamp = CyderLifecycle.Stamp(epoch: latestLifecycle.epoch, environment: environment.id, generation: environment.generation)
            lifecycleStore.send(.stopRequested(stamp, UUID()))
        }
    }

    func stopFinished(stamp: CyderLifecycle.Stamp, operation: UUID, success: Bool) {
        lifecycleStore.send(.stopFinished(stamp, operation, success: success))
    }

    func canExecuteStop(stamp: CyderLifecycle.Stamp, operation: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard !isQuiescing, latestLifecycle.epoch == stamp.epoch,
              let environment = latestLifecycle.environments[stamp.environment] else { return false }
        return environment.generation == stamp.generation && environment.operation == operation && environment.existence != .exited
    }

    func setIngressPending(_ pending: Bool) {
        precondition(Thread.isMainThread)
        externalIngressPending = pending
        publishLegacyWork()
    }

    private func publishLegacyWork() {
        let pending = externalIngressPending || launchIngressPending
            || pendingEnvironmentAttachments > 0 || sessions.values.contains { !$0.activated }
        guard lastPublishedWork != pending else { return }
        lastPublishedWork = pending
        lifecycleStore.send(.ingressPending(pending))
    }

    func receiveLifecycleEvent(_ event: CyderLifecycle.Event) { lifecycleStore.send(event) }

    func monitorEnvironment(prefix: URL) {
        guard !isQuiescing, let onManageEnvironment else { return }
        pendingEnvironmentAttachments += 1
        publishLegacyWork()
        onManageEnvironment(prefix) { [weak self] resolved in
            guard let self else { return }
            if let resolved { self.environmentPrefixes[prefix.path] = resolved }
            self.pendingEnvironmentAttachments -= 1
            self.publishLegacyWork()
        }
    }

    func applyLifecycleSnapshot(_ snapshot: CyderLifecycle.Snapshot) {
        precondition(Thread.isMainThread)
        guard !hasLifecycleSnapshot || (snapshot.epoch == latestLifecycle.epoch && snapshot.revision > latestLifecycle.revision) else { return }
        hasLifecycleSnapshot = true
        latestLifecycle = snapshot
        let endedScopes = Set(snapshot.environments.values.filter { $0.existence == .exited }.map {
            "\($0.id.uid):\(Int64(bitPattern: $0.id.device)):\($0.id.inode)"
        })
        let ended = sessions.values.filter { $0.nativeRoot?.prefixScope.map { endedScopes.contains($0) } == true }.map(\.id)
        for id in ended { endLaunch(id: id) }
        if snapshot.keepStatusItem && !isQuiescing { installStatusItemIfNeeded() }
        refresh()
        scheduleLifecycleSettlement()
    }

    private func scheduleLifecycleSettlement() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isQuiescing, !self.menuIsOpen,
                  RunLoop.current.currentMode != .eventTracking else { return }
            self.refresh()
            self.removeStatusItemIfUnused()
            if self.hasLifecycleSnapshot && self.latestLifecycle.canAutoTerminate
                && !self.uiVisible && self.lastPublishedWork == false {
                self.onLifecycleIdle?()
            }
        }
    }

    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var visualState: VisualState = .starting
    private var animationFrame = 0
    private var uiVisible = false
    private var menuIsOpen = false
    private var processSources: [CyderLifecycle.ProcessID: DispatchSourceProcess] = [:]
    private var processQuiescing = false // processQueue only
    private let processQueue = DispatchQueue(label: "local.cyder.status-proc")
    private let observationQueue = DispatchQueue(label: "local.cyder.status-observation", qos: .utility)

    private var visibleSessions: [Session] { sessions.values.filter { !$0.activated || !$0.adoptedPIDs.isEmpty } }
    var hasActiveSessions: Bool { !visibleSessions.isEmpty } // presentation only; never an app exit policy

    /// Keep the menu-bar item available while a Cyder-owned window is open,
    /// even when no Wine process is currently being monitored.
    func setUIVisible(_ visible: Bool) {
        precondition(Thread.isMainThread)
        uiVisible = visible
        lifecycleStore.send(.visibleUI(visible))
        if visible { installStatusItemIfNeeded() }
        refresh()
    }

    func markLaunchStarted() {
        precondition(Thread.isMainThread)
        launchIngressPending = true
        publishLegacyWork()
        visualState = .starting
        installStatusItemIfNeeded()
        refresh()
    }

    func finishLaunchIngress() {
        precondition(Thread.isMainThread)
        launchIngressPending = false
        publishLegacyWork()
        refresh()
    }

    func adoptWindowedProcess(pid: Int32, prefix: String, name: String?) {
        precondition(Thread.isMainThread)
        guard !isQuiescing, pid > 0, claimInFlight < 2 else { return }
        let target = (prefix as NSString).standardizingPath
        let candidates = sessions.filter { target.isEmpty || $0.value.prefix.path == target }.map {
            (id: $0.key, version: sessionVersions[$0.key], roots: roots(for: $0.value))
        }
        claimInFlight += 1
        observationQueue.async { [weak self] in
            var owners: [(String, UUID?, CyderLifecycle.ProcessID)] = []
            if case .live(let target) = CyderProcessEvidence.inspect(pid),
               wineOnscreenWindows(ownedBy: [pid]).contains(where: { $0.pid == pid }) {
                for candidate in candidates where CyderProcessEvidence.tree(roots: candidate.roots).contains(target.id) {
                    if CyderProcessEvidence.live(target.id) { owners.append((candidate.id, candidate.version, target.id)) }
                }
            }
            let confirmed = owners
            DispatchQueue.main.async {
                guard let self else { return }; self.claimInFlight -= 1
                guard !self.isQuiescing, confirmed.count == 1, let owner = confirmed.first,
                      self.sessionVersions[owner.0] == owner.1 else { return }
                self.adoptWindow(id: owner.0, process: owner.2, name: name)
            }
        }
    }

    private func roots(for session: Session) -> Set<CyderLifecycle.ProcessID> {
        var roots = session.adoptedPIDs
        if let root = session.root { roots.insert(root) }
        return roots
    }
    private func adoptWindow(id: String, process: CyderLifecycle.ProcessID, name: String?) {
        guard !isQuiescing, !exitedProcesses.contains(process), var session = sessions[id] else { return }
        session.adoptedPIDs.insert(process)
        session.foregroundPIDs.insert(process)
        applyWindowedHandoff(&session, preferredName: name)
        sessions[id] = session
        watchProcess(process)
        refresh()
        onWindowConfirmed?(id)
    }

    func markActivated(id: String) {
        precondition(Thread.isMainThread)
        guard var session = sessions[id] else { return }
        session.activated = true
        session.hasForeground = true
        sessions[id] = session
        refresh()
    }

    func finishLaunchObservation(id: String, activated: Bool, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard !isQuiescing, !activated else { completion(true); return }
        claimLiveWindows(id: id) { [weak self] in
            guard let self else { completion(false); return }
            guard !self.isQuiescing else { completion(true); return }
            guard var session = self.sessions[id] else { completion(false); return }
            // Live background processes do not prove that a window was activated.
            session.activated = true
            self.sessions[id] = session
            let retained = !session.adoptedPIDs.isEmpty || session.hasForeground
            if retained || session.nativeRoot != nil { self.refresh() } else { self.endLaunch(id: id) }
            completion(retained)
        }
    }

    func hasLiveWatchedPIDs(id: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let session = sessions[id] else { return false }
        return !session.adoptedPIDs.isEmpty
    }

    func hasClaimedWindow(id: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let session = sessions[id] else { return false }
        return session.hasForeground || !session.foregroundPIDs.isEmpty
    }

    /// Snapshot the current Wine tree and adopt any on-screen windows before a
    /// timeout decides whether to keep the LaunchGroup.
    func claimLiveWindows(id: String) {
        claimLiveWindows(id: id, completion: {})
    }

    func claimLiveWindows(id: String, completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard !isQuiescing, let session = sessions[id], claimTokens[id] == nil, claimInFlight < 2 else {
            completion()
            return
        }
        let token = UUID()
        let sessionVersion = sessionVersions[id]
        claimTokens[id] = token
        claimCompletions[id] = completion
        claimInFlight += 1
        let capturedRoots = roots(for: session)
        // Timeout completes observation only. The actual worker still occupies
        // its slot until the OS call returns; retries cannot grow blocked work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.claimTokens[id] == token else { return }
            self.claimTokens.removeValue(forKey: id)
            self.claimCompletions.removeValue(forKey: id)?()
        }
        observationQueue.async { [weak self] in
            let expanded = CyderProcessEvidence.tree(roots: capturedRoots)
            let windows = wineOnscreenWindows(ownedBy: Set(expanded.map(\.pid)))
            let live = Set(expanded.filter { CyderProcessEvidence.live($0) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.claimInFlight -= 1
                guard self.claimTokens[id] == token else { return }
                self.claimTokens.removeValue(forKey: id)
                defer { self.claimCompletions.removeValue(forKey: id)?() }
                guard !self.isQuiescing, self.sessionVersions[id] == sessionVersion, var updated = self.sessions[id] else { return }
                let live = live.subtracting(self.exitedProcesses)
                updated.adoptedPIDs.formUnion(live)
                self.sessions[id] = updated
                for process in live { self.watchProcess(process) }
                for window in windows {
                    guard let process = live.first(where: { $0.pid == window.pid }) else { continue }
                    self.adoptWindow(id: id, process: process, name: window.ownerName)
                }
            }
        }
    }

    func markStopping(prefixes: [URL]) {
        let targets = Set(prefixes.map { $0.standardizedFileURL })
        for (key, var session) in sessions where targets.contains(session.prefix) {
            session.isStopping = true
            sessions[key] = session
        }
        refresh()
    }

    func markStopFailed(prefix: URL) {
        let target = prefix.standardizedFileURL
        for (key, var session) in sessions where session.prefix == target {
            session.isStopping = false
            sessions[key] = session
        }
        refresh()
    }

    func markPrefixStopped(prefix: URL) {
        let target = prefix.standardizedFileURL
        let removed = sessions.filter { $0.value.prefix == target }
        for key in removed.keys {
            sessions.removeValue(forKey: key)
        }
        refresh()
        finishIfEmpty(hadSessions: !removed.isEmpty)
    }

    func beginLaunch(id: String, prefix: URL, executableName: String, authority: CyderLaunchObserver.Authority? = nil) {
        precondition(Thread.isMainThread)
        guard !isQuiescing else { return }
        sessionVersions[id] = UUID()
        launchIngressPending = false
        let name = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "Wine" : name
        sessions[id] = Session(id: id, root: nil, authority: authority, prefix: prefix.standardizedFileURL,
            rootDisplayName: display, fromSentinel: true, displayName: display,
            helperConnected: false, adoptedPIDs: [])
        installStatusItemIfNeeded()
        refresh()
    }

    /// Workspace termination is an invalidation hint, not authority to remove
    /// whichever process happens to own the same numeric PID now.
    func noteProcessExited(_ pid: Int32) {
        precondition(Thread.isMainThread)
        let captured = Set(sessions.values.flatMap { roots(for: $0) }).filter { $0.pid == pid }
        processQueue.async { [weak self] in
            let ended = captured.filter { CyderProcessEvidence.hasEnded($0) }
            DispatchQueue.main.async { ended.forEach { self?.handleProcessExit($0) } }
        }
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
        sessionVersions.removeValue(forKey: id)
        cancelOrphanedProcessSources(removed: session)
        refresh()
        finishIfEmpty(hadSessions: true)
    }

    func attachNativeRoot(_ receipt: CyderLaunchObserver.NativeRoot) {
        precondition(Thread.isMainThread)
        let id = receipt.authority.launch
        guard !isQuiescing, var session = sessions[id], session.authority == receipt.authority,
              receipt.pid > 0, receipt.started > 0, !receipt.boot.isEmpty, receipt.prefixScope != nil,
              ["spawned", "exited"].contains(receipt.phase) else { return }
        if receipt.phase == "exited" {
            guard let status = receipt.status, (0...255).contains(status), let signalled = receipt.signalled,
                  !signalled || (1...127).contains(status) else { return }
        }
        if let previous = session.nativeRoot {
            guard previous.ticket == receipt.ticket, previous.pid == receipt.pid, previous.boot == receipt.boot,
                  previous.started == receipt.started, previous.prefixScope == receipt.prefixScope,
                  previous.phase != "exited" || previous == receipt else { return }
            if previous == receipt { return }
        }
        let process = CyderLifecycle.ProcessID(boot: receipt.boot, pid: receipt.pid, started: receipt.started)
        session.nativeRoot = receipt
        session.root = receipt.phase == "spawned" ? process : nil
        sessions[id] = session
        if receipt.phase == "exited" { handleProcessExit(process) }
        else { watchProcess(process); claimLiveWindows(id: id) }
        refresh()
    }
    func nativeRootPID(id: String) -> Int32 { sessions[id]?.nativeRoot?.pid ?? 0 }

    func isMonitoring(prefix: String) -> Bool {
        precondition(Thread.isMainThread)
        let target = (prefix as NSString).standardizingPath
        return sessions.values.contains { $0.prefix.path == target }
    }

    private func cancelOrphanedProcessSources(removed session: Session) {
        let removed = roots(for: session).union(session.foregroundPIDs)
        let stillWatched = Set(sessions.values.flatMap { roots(for: $0).union($0.foregroundPIDs) })
        let orphaned = removed.subtracting(stillWatched)
        processQueue.async { [weak self] in
            guard let self else { return }
            for process in orphaned { self.processSources.removeValue(forKey: process)?.cancel() }
        }
    }

    private func watchProcess(_ process: CyderLifecycle.ProcessID) {
        processQueue.async { [weak self] in self?.watchProcessOnQueue(process) }
    }
    private func watchProcessOnQueue(_ process: CyderLifecycle.ProcessID, discover: Bool = true) {
        guard !processQuiescing, processSources[process] == nil, processSources.count < 1024 else { return }
        guard CyderProcessEvidence.live(process) else {
            if CyderProcessEvidence.hasEnded(process) {
                DispatchQueue.main.async { [weak self] in self?.handleProcessExit(process) }
            }
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: [.exit, .fork, .exec], queue: processQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.processSources[process] === source else { return }
            let events = source.data
            if events.contains(.fork) || events.contains(.exec) { self.discoverChildren(process) }
            if events.contains(.exit) {
                source.cancel(); self.processSources.removeValue(forKey: process)
                DispatchQueue.main.async { self.handleProcessExit(process) }
            }
        }
        processSources[process] = source; source.resume()
        guard CyderProcessEvidence.live(process) else {
            processSources.removeValue(forKey: process)?.cancel()
            if CyderProcessEvidence.hasEnded(process) {
                DispatchQueue.main.async { [weak self] in self?.handleProcessExit(process) }
            }
            return
        }
        if discover { discoverChildren(process) }
    }
    private func discoverChildren(_ root: CyderLifecycle.ProcessID) {
        guard !processQuiescing else { return }
        let children = CyderProcessEvidence.tree(roots: [root])
        for child in children where child != root { watchProcessOnQueue(child, discover: false) }
        DispatchQueue.main.async { [weak self] in self?.handleProcessSpawn(root: root, children: children) }
    }
    private func handleProcessSpawn(root: CyderLifecycle.ProcessID, children: Set<CyderLifecycle.ProcessID>) {
        precondition(Thread.isMainThread)
        guard !isQuiescing else { return }
        for (key, var session) in sessions {
            let receipt = session.nativeRoot
            let recordedRoot = receipt?.pid == root.pid && receipt?.boot == root.boot && receipt?.started == root.started
            guard roots(for: session).contains(root) || recordedRoot else { continue }
            session.adoptedPIDs.formUnion(children.subtracting(exitedProcesses))
            sessions[key] = session
            claimLiveWindows(id: key)
        }
        refresh()
    }
    private func handleProcessExit(_ process: CyderLifecycle.ProcessID) {
        precondition(Thread.isMainThread)
        guard !isQuiescing else { return }
        exitedProcesses.insert(process)
        processQueue.async { [weak self] in self?.processSources.removeValue(forKey: process)?.cancel() }
        let affected = sessions.filter { roots(for: $0.value).contains(process) || $0.value.foregroundPIDs.contains(process) }
        for (id, var session) in affected {
            session.adoptedPIDs.remove(process)
            if session.root == process { session.root = nil }
            session.foregroundPIDs.remove(process)
            session.hasForeground = !session.foregroundPIDs.isEmpty
            if session.adoptedPIDs.isEmpty { session.leftoverNames = [] }
            sessions[id] = session
            if !session.hasForeground { finishSessionIfIdle(id) }
        }
        if !affected.isEmpty { refresh() }
    }

    private func leftoverNames(for session: Session) -> [String] {
        // Names arrive with observer snapshots; AppKit never reads argv.
        session.leftoverNames
    }

    private func finishSessionIfIdle(_ id: String) {
        guard var session = sessions[id] else { return }
        let live = session.adoptedPIDs
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
        // Keep immutable root provenance for a child snapshot already in
        // flight. An empty completed group is hidden; environment exit retires it.
        sessions[id] = session
        refresh()
    }

    private func installStatusItemIfNeeded() {
        guard !isQuiescing, statusItem == nil else { return }
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
        publishLegacyWork()
        scheduleLifecycleSettlement()
    }

    private func removeStatusItemIfUnused() {
        guard hasLifecycleSnapshot, !latestLifecycle.keepStatusItem, !menuIsOpen,
              latestLifecycle.phase != .active || (!uiVisible && lastPublishedWork == false),
              RunLoop.current.currentMode != .eventTracking else { return }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            statusRemovalCount += 1
        }
        statusItem = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        scheduleLifecycleSettlement()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !menuIsOpen else { return }
        rebuild(menu)
    }

    private func refresh() {
        guard !isQuiescing else { return }
        publishLegacyWork()
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
        menuMutationCount += 1
        menu.removeAllItems()
        let ordered = visibleSessions.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for session in ordered {
            let state: String
            if session.isStopping {
                state = "正在結束 Windows 程序"
            } else if session.hasForeground {
                state = "執行中"
            } else if !session.activated {
                state = "正在啟動"
            } else if let leftover = session.leftoverNames.first {
                state = "背景執行：\(leftover)"
            } else {
                state = "執行中；尚未確認視窗"
            }
            let item = NSMenuItem(title: "\(session.displayName) — \(state)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for environment in latestLifecycle.environments.values.sorted(by: { $0.prefix < $1.prefix })
            where environment.existence != .exited && !ordered.contains(where: { (environmentPrefixes[$0.prefix.path] ?? $0.prefix.path) == environment.prefix }) {
            let state: String
            switch environment.stop {
            case .executing: state = "正在停止 Windows 環境"
            case .unconfirmed, .failed: state = "尚未確認環境停止，可重新檢查"
            default: state = environment.existence == .alive && environment.health == .healthy
                ? "Windows 環境仍在執行" : "暫時無法確認執行狀態"
            }
            let item = menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        if !ordered.isEmpty || latestLifecycle.hasEnvironment { menu.addItem(.separator()) }

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
        let stopTitle = prefixes.count > 1 ? "停止所有 Windows 環境…" : "停止 Windows 環境…"
        let stop = menu.addItem(withTitle: stopTitle, action: #selector(stopWindowsEnvironment), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !prefixes.isEmpty && !latestLifecycle.environments.values.contains { $0.stop == .executing }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Cyder", action: #selector(quitCyder), keyEquivalent: "q")
        quit.target = self
    }

    private var currentVisualState: VisualState {
        if latestLifecycle.environments.values.contains(where: { $0.stop == .executing }) { return .stopping }
        if visibleSessions.contains(where: { !$0.activated && !$0.hasForeground }) { return .starting }
        return .running
    }

    private func updateAnimationTimer() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = !reduceMotion && (visualState == .stopping || visualState == .attention) && !menuIsOpen
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
            let visible = visibleSessions
            if visible.count == 1, let name = visible.first?.displayName {
                return "\(name) 執行中"
            }
            return visible.isEmpty ? (latestLifecycle.hasEnvironment ? "Windows 環境狀態" : "Cyder") : "\(visible.count) 個程式執行中"
        case .background: return "Windows 環境仍在執行"
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
        Array(Set(latestLifecycle.environments.values.filter { $0.existence != .exited }.map { URL(fileURLWithPath: $0.prefix) })).sorted { $0.path < $1.path }
    }

    var monitoredPrefixes: [URL] { activePrefixes }

    @objc private func quitCyder() { onQuit?() }
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
