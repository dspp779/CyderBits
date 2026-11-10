// Only the elected primary owns the menu-bar item and dispatch authority.
// The former directory consumer is deliberately absent: no parallel executor.
import Cocoa
import Darwin
import Foundation

struct CyderInstanceRequest {
    let files: [String]
    let arguments: [String]?
    let urls: [String]
    let showUI: Bool
    let record: CyderRequestRegistry.Record
}

/// Elects the primary, accepts launch requests (locally or from a secondary
/// instance over the request channel) into the in-memory registry, and keeps
/// the app informed of native executor tickets.
///
/// Nothing about requests is persisted. The executor tickets are the only
/// state that outlives Cyder: they say which native process belongs to which
/// launch, and that is all restart recovery needs.
final class CyderInstanceCoordinator {
    enum Role { case primary, secondary, unavailable }
    private let support: URL
    private let path: String
    private let startup = DispatchQueue(label: "local.cyder.instance-start")
    private let forwarding = DispatchQueue(label: "local.cyder.instance-forward")
    private var forwardInFlight = false
    private let registry: CyderRequestRegistry
    private let channel: CyderRequestChannel
    private var onRequest: ((CyderInstanceRequest) -> Void)?
    private var closing = false
    private var startupGeneration: UUID?
    private var startRequested = false
    private var startupCleanupRequested = false
    private var startupInFlight = false
    private var cleanupCompletions: [() -> Void] = []
    private let startupDeadline: TimeInterval
    private let beforeElection: () -> Void
    private let forwardDeadline: TimeInterval
    private var primary = false
    private var delivered = Set<String>()
    /// Every ticket snapshot (current and earlier Cyder processes), delivered
    /// on main before terminal tickets are pruned.
    var onExecutionTickets: (([CyderExecutionOwner.Ticket]) -> Void)?
    var executionEpoch: UUID { registry.executorEpoch }
    private var executionReceiptInFlight = false
    private var executionReceiptRefreshPending = false
    private lazy var executionWatch: CyderExecutionWatch = {
        let watch = CyderExecutionWatch(directory: support.appendingPathComponent("execution-owners"))
        watch.onChange = { [weak self] in self?.refreshExecutionReceipts() }
        return watch
    }()
    private let beforeExecutionRead: () -> Void
    let sentinel: CyderSentinelServer

    init(support: URL = CyderPaths.support,
         bundleID: String = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier ?? "local.cyder.app",
         startupDeadline: TimeInterval = 5, beforeElection: @escaping () -> Void = {},
         forwardDeadline: TimeInterval = 5,
         beforeExecutionRead: @escaping () -> Void = {},
         normalizeSettings: @escaping (Data) throws -> Data = { $0 }) {
        self.support = support
        self.startupDeadline = startupDeadline
        self.beforeElection = beforeElection
        self.forwardDeadline = forwardDeadline
        self.beforeExecutionRead = beforeExecutionRead
        path = support.appendingPathComponent(".requests-v1.sock").path
        registry = CyderRequestRegistry(
            captureSettings: { try normalizeSettings(CyderAcceptedSettings.capture(at: support.appendingPathComponent("settings.json"))) })
        channel = CyderRequestChannel(path: path)
        sentinel = CyderSentinelServer(support: support, bundleID: bundleID)
    }

    func start(onRequest: @escaping (CyderInstanceRequest) -> Void, completion: @escaping (Role) -> Void) {
        precondition(Thread.isMainThread)
        guard !startRequested, !closing else { completion(.unavailable); return }
        startRequested = true; startupInFlight = true
        self.onRequest = onRequest
        let generation = UUID(); startupGeneration = generation
        let expiresAt = ProcessInfo.processInfo.systemUptime + max(0, startupDeadline)
        func finish(_ role: Role) {
            guard self.startupGeneration == generation, !self.closing else { return }
            self.startupGeneration = nil
            if role == .unavailable { self.closing = true } else { self.startupInFlight = false }
            completion(role)
        }
        func mayContinue() -> Bool {
            if ProcessInfo.processInfo.systemUptime >= expiresAt { finish(.unavailable) }
            return self.startupGeneration == generation && !self.closing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, startupDeadline)) { [weak self] in
            guard let self, self.startupGeneration == generation, !self.closing else { return }
            // This ends only the observation. Physical initialization is still
            // owned, and each later stage is fenced before dispatch authority.
            finish(.unavailable)
        }
        startup.async { [self] in
            beforeElection()
            let role = sentinel.becomePrimary()
            DispatchQueue.main.async {
                guard mayContinue() else { self.releaseStartupResources(); return }
                switch role {
                case .secondary: finish(.secondary)
                case .unavailable: finish(.unavailable); self.releaseStartupResources()
                case .primary:
                    self.startup.async {
                        // 0.14.0-rc.1 persisted requests here. They carry no
                        // authority any more and must never be replayed.
                        for legacy in ["request-journal", "request-outbox"] {
                            try? FileManager.default.removeItem(at: self.support.appendingPathComponent(legacy))
                        }
                        let recoveredExecutors = (try? CyderExecutionOwner.recover(root: self.support.appendingPathComponent("execution-owners"))) != nil
                        let started = recoveredExecutors && self.channel.start { [weak self] message, reply in
                            DispatchQueue.main.async { self?.receive(message, reply: reply) }
                        }
                        DispatchQueue.main.async {
                            guard mayContinue() else { self.releaseStartupResources(); return }
                            self.primary = started
                            if started {
                                finish(.primary)
                                self.refreshExecutionReceipts()
                            } else {
                                finish(.unavailable); self.releaseStartupResources()
                            }
                        }
                    }
                }
            }
        }
    }

    private func releaseStartupResources() {
        precondition(Thread.isMainThread)
        guard !startupCleanupRequested else { return }
        startupCleanupRequested = true
        channel.stop { [self] in
            registry.close { [self] in
                sentinel.stop { DispatchQueue.main.async {
                    self.startupInFlight = false
                    let callbacks = self.cleanupCompletions; self.cleanupCompletions.removeAll()
                    callbacks.forEach { $0() }
                } }
            }
        }
    }

    private func receive(_ message: CyderRequestMessage, reply: @escaping (CyderRequestReply) -> Void) {
        precondition(Thread.isMainThread)
        func respond(_ status: String, _ record: CyderRequestRegistry.Record? = nil) {
            // Acceptance settings belong to the primary executor, not the wire
            // ACK/status projection (which has a smaller transport byte budget).
            var wireRecord = record
            wireRecord?.settingsSnapshot = nil
            reply(.init(protocolVersion: 1, requestID: message.requestID, primaryEpoch: registry.executorEpoch,
                        namespace: registry.namespace, status: status, record: wireRecord))
        }
        guard primary else { respond("unavailable"); return }
        if message.kind == "hello" { respond(closing ? "closing" : "ready"); return }
        guard let id = message.requestID else { respond("rejected"); return }
        switch message.kind {
        case "submit":
            guard let payload = message.payload, payload.matches(message.payloadDigest) else { respond("rejected"); return }
            registry.submit(id: id, payload: payload) { [weak self] result in
                switch result {
                case .failure(let failure): respond(failure == .closing ? "closing" : "rejected")
                case .success(let record):
                    respond("accepted", record)
                    self?.deliver(record)
                }
            }
        case "query":
            registry.query(id: id) { result in
                if case .success(let record) = result { respond("existingStatus", record) }
                else { respond("rejected") }
            }
        default: respond("rejected")
        }
    }

    func submit(_ payload: CyderRequestPayload, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing else { completion(false); return }
        let id = CyderRequestRegistry.makeID(namespace: registry.namespace)
        registry.submit(id: id, payload: payload) { [weak self] result in
            guard case .success(let record) = result else { completion(false); return }
            completion(true) // accepted for dispatch; not game success
            self?.deliver(record)
        }
    }

    private func deliver(_ record: CyderRequestRegistry.Record) {
        guard !closing, !delivered.contains(record.id) else { return }
        delivered.insert(record.id)
        if let children = record.children {
            for id in children {
                registry.query(id: id) { [weak self] result in
                    if case .success(let child) = result { self?.deliver(child) }
                }
            }
            return
        }
        guard record.phase == .queued, let payload = record.payload else { return }
        onRequest?(CyderInstanceRequest(files: payload.files, arguments: payload.arguments,
            urls: payload.urls, showUI: payload.showUI, record: record))
    }

    func authorize(_ record: CyderRequestRegistry.Record,
                   completion: @escaping (CyderRequestRegistry.Record?) -> Void) {
        guard primary, !closing else { completion(nil); return }
        registry.authorizeDispatch(id: record.id) { [weak self] result in
            guard let self, !self.closing, case .success(let authorized) = result else { completion(nil); return }
            completion(authorized)
        }
    }

    func finish(_ record: CyderRequestRegistry.Record, outcome: String, failed: Bool = false, uncertain: Bool = false) {
        guard let launch = record.launchID, let epoch = record.executorEpoch else { return }
        registry.complete(id: record.id, launchID: launch, epoch: epoch, outcome: outcome, failed: failed, uncertain: uncertain) { _ in }
    }

    /// A queued request that cannot be dispatched (for example its environment
    /// could not be resolved) ends here; nothing waits for a later resume.
    func withdraw(_ record: CyderRequestRegistry.Record, reason: String) {
        registry.fail(id: record.id, outcome: reason) { _ in }
    }

    /// Reads executor tickets on change events (see CyderExecutionWatch), hands
    /// them to the app, then prunes the terminal ones it has just delivered.
    /// It never resumes or completes a launch based on a Bash/native exit.
    func refreshExecutionReceipts() {
        precondition(Thread.isMainThread)
        guard primary, !closing else { return }
        guard !executionReceiptInFlight else { executionReceiptRefreshPending = true; return }
        executionReceiptInFlight = true
        let root = support.appendingPathComponent("execution-owners")
        startup.async { [self] in
            beforeExecutionRead()
            let tickets = try? CyderExecutionOwner.snapshot(root: root)
            DispatchQueue.main.async { [self] in
                guard !closing, let tickets else { finishExecutionReceiptRead(); return }
                onExecutionTickets?(tickets)
                updateExecutionWatch(tickets)
                // Delivered above; a settled launch ticket has nothing left to
                // prove. Uncorrelated maintenance tickets keep the executor's
                // own bounded retention (newest 32).
                let settled = tickets.filter { $0.correlation != nil && Self.isSettled($0) }
                startup.async { [self] in
                    try? CyderExecutionOwner.prune(root: root, confirmed: settled)
                    DispatchQueue.main.async { [self] in finishExecutionReceiptRead() }
                }
            }
        }
    }

    static func isSettled(_ ticket: CyderExecutionOwner.Ticket) -> Bool {
        ticket.phase.isTerminal && ticket.nativeSpawn.map { $0.phase.isTerminal } != false
    }

    private func finishExecutionReceiptRead() {
        executionReceiptInFlight = false
        let again = executionReceiptRefreshPending
        executionReceiptRefreshPending = false
        if again { refreshExecutionReceipts() }
    }

    /// Re-read tickets on change events instead of polling: directory writes
    /// (every ticket transition is a rename there) and exits of the processes
    /// an unresolved ticket depends on. See CyderExecutionWatch.
    private func updateExecutionWatch(_ tickets: [CyderExecutionOwner.Ticket]) {
        guard primary, !closing else { return }
        let unresolved = tickets.filter { $0.correlation != nil && !Self.isSettled($0) }
        var pids = Set<Int32>()
        for ticket in unresolved {
            [ticket.owner?.pid, ticket.child?.pid, ticket.nativeSpawn?.bridge.pid, ticket.nativeSpawn?.process?.pid]
                .compactMap { $0 }.forEach { pids.insert($0) }
        }
        executionWatch.update(unresolved: !unresolved.isEmpty, pids: pids)
    }

    /// Same-ID automatic retries are confined to one monotonic five-second
    /// budget; the primary's registry makes a retried submit idempotent.
    /// Nothing is kept on disk: if the primary never answers, this secondary
    /// reports the request as unconfirmed and the user can start it again.
    func forward(files: [String], arguments: [String]?, urls: [String] = [], showUI: Bool,
                 completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard !closing, !forwardInFlight else { completion(false); return }
        forwardInFlight = true
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, forwardDeadline)
        var reported = false // accessed only on main
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, forwardDeadline)) {
            guard !reported else { return }; reported = true
            completion(false) // the worker still owns its physical slot
        }
        let payload = CyderRequestPayload(files: files, arguments: arguments, urls: urls, showUI: showUI)
        forwarding.async { [self] in
            let sender = UUID()
            var id: String?
            var attempts = 0
            func done(_ accepted: Bool) { DispatchQueue.main.async {
                self.forwardInFlight = false
                guard !reported else { return }; reported = true
                completion(accepted)
            } }
            while attempts < 6, ProcessInfo.processInfo.systemUptime < deadline {
                attempts += 1
                if id == nil {
                    let remaining = min(0.7, deadline - ProcessInfo.processInfo.systemUptime)
                    guard remaining > 0 else { break }
                    let hello = CyderRequestMessage(protocolVersion: 1, kind: "hello", requestID: nil,
                        payloadDigest: nil, senderEpoch: sender, payload: nil)
                    if let response = CyderRequestChannel.exchange(path: path, message: hello, timeout: remaining),
                       response.status == "ready", let namespace = response.namespace {
                        id = CyderRequestRegistry.makeID(namespace: namespace)
                    }
                }
                if let id {
                    // The submit reply may use the whole remaining budget; a
                    // retry reuses this ID, so acceptance happens at most once.
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    let message = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id,
                        payloadDigest: payload.digest, senderEpoch: sender, payload: payload)
                    if let response = CyderRequestChannel.exchange(path: path, message: message, timeout: remaining),
                       response.status == "accepted", let record = response.record,
                       record.id == id, payload.matches(record.digest) {
                        done(true)
                        return
                    }
                }
                // Dedicated delivery worker only; no main/store wait or global polling.
                Thread.sleep(forTimeInterval: min(0.2 * Double(attempts), max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
            done(false)
        }
    }

    func quiesce(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        closing = true // invalidate pending delivery callbacks immediately
        executionWatch.stop()
        startupGeneration = nil
        registry.close { completion(true) }
    }

    func stop(completion: @escaping () -> Void = {}) {
        precondition(Thread.isMainThread)
        closing = true
        executionWatch.stop()
        startupGeneration = nil
        guard primary else {
            if startupInFlight { cleanupCompletions.append(completion) } else { completion() }
            return
        }
        primary = false
        channel.stop { [self] in
            registry.close { [self] in
                sentinel.stop { DispatchQueue.main.async { completion() } }
            }
        }
    }
}
