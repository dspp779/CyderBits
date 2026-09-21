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
    let record: CyderRequestJournal.Record
}

/// A retained delivery copy is evidence of an attempt, never permission to
/// launch. Only a matching durable journal record acknowledges this copy.
struct CyderOutboxNotice: Equatable {
    let id: String
    let title: String
    let detail: String
    var requestID: String? = nil
    var digest: String? = nil
    var canRecover: Bool { requestID != nil && digest != nil }
}

enum CyderRequestOutbox {
    enum Failure: Error { case unavailable, invalid, full }
    private static let maxEntries = 512
    private static let maxBytes = 16 * 1024 * 1024
    private static func withDirectory<T>(_ support: URL, create: Bool = false,
                                         _ body: (Int32) throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        let path = support.appendingPathComponent("request-outbox").path
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.invalid }
        let lock = openat(fd, ".owner-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o077 == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(fd)
    }
    private static func names(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Failure.unavailable }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", name != ".owner-lock" else { continue }
            guard result.count < maxEntries else { throw Failure.full }
            result.append(name)
        }
        return result.sorted()
    }
    private static func read(_ directory: Int32, _ name: String) throws -> (CyderRequestMessage, stat, Int) {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalid }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_mode & 0o077 == 0,
              before.st_size > 0, before.st_size < CyderRequestChannel.maxFrame else { throw Failure.invalid }
        var bytes = Data(count: Int(before.st_size))
        let count = bytes.withUnsafeMutableBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return -1 }; offset += n
            }
            return offset
        }
        guard count == bytes.count, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let message = try? JSONDecoder().decode(CyderRequestMessage.self, from: bytes),
              valid(message) else { throw Failure.invalid }
        return (message, after, count)
    }
    private static func valid(_ message: CyderRequestMessage) -> Bool {
        guard message.protocolVersion == 1, message.kind == "submit",
              let id = message.requestID, let payload = message.payload,
              payload.isValid, message.payloadDigest == payload.digest else { return false }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }
    private static func filename(_ id: String) -> String { id.replacingOccurrences(of: ":", with: "-") + ".json" }

    static func save(_ message: CyderRequestMessage, support: URL) throws {
        guard valid(message), let id = message.requestID else { throw Failure.invalid }
        let bytes = try JSONEncoder().encode(message)
        guard bytes.count < CyderRequestChannel.maxFrame else { throw Failure.full }
        try withDirectory(support, create: true) { directory in
            let entries = try names(directory)
            guard entries.count < maxEntries else { throw Failure.full }
            var total = bytes.count
            for name in entries {
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unavailable }
                guard info.st_size >= 0, info.st_size <= maxBytes else { throw Failure.full }
                total += Int(info.st_size)
                guard total <= maxBytes else { throw Failure.full }
            }
            let fd = openat(directory, filename(id), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(fd) }
            let written = bytes.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }; offset += n
                }
                return fsync(fd) == 0
            }
            guard written, fsync(directory) == 0 else { throw Failure.unavailable }
        }
    }
    private static func remove(_ directory: Int32, name: String, identity: stat) throws {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_size == identity.st_size,
              current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec else { throw Failure.invalid }
        guard unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else { throw Failure.unavailable }
    }
    static func retainedRequest(id: String, digest: String, support: URL) throws -> CyderRequestMessage {
        try withDirectory(support) { directory in
            let (message, _, _) = try read(directory, filename(id))
            guard message.requestID == id, message.payloadDigest == digest else { throw Failure.invalid }
            return message
        }
    }
    static func acknowledge(_ record: CyderRequestJournal.Record, support: URL) throws {
        try withDirectory(support) { directory in
            let name = filename(record.id)
            let (message, identity, _) = try read(directory, name)
            guard message.requestID == record.id, message.payloadDigest == record.digest else { throw Failure.invalid }
            try remove(directory, name: name, identity: identity)
        }
    }
    static func reconcile(support: URL, records: [CyderRequestJournal.Record], namespace: UUID? = nil) throws -> [CyderOutboxNotice] {
        let path = support.appendingPathComponent("request-outbox").path
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT { return [] }
        let accepted = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return try withDirectory(support) { directory in
            var notices: [CyderOutboxNotice] = [], bytesRead = 0
            for name in try names(directory) {
                let fallback = CyderOutboxNotice(id: "outbox-file:" + name, title: "未確認的舊要求",
                    detail: "無法核對原始要求；已保留檔案，請查看診斷記錄。不會自動啟動。")
                var size = stat()
                guard fstatat(directory, name, &size, AT_SYMLINK_NOFOLLOW) == 0,
                      size.st_mode & S_IFMT == S_IFREG,
                      size.st_size > 0, size.st_size < CyderRequestChannel.maxFrame else {
                    notices.append(fallback); continue
                }
                bytesRead += Int(size.st_size)
                guard bytesRead <= maxBytes else { throw Failure.full }
                guard let (message, identity, _) = try? read(directory, name), let id = message.requestID else {
                    notices.append(fallback); continue
                }
                if let record = accepted[id], record.digest == message.payloadDigest {
                    do { try remove(directory, name: name, identity: identity) }
                    catch { notices.append(.init(id: "outbox:" + id, title: "已核對啟動要求", detail: "要求已被接受；本機副本尚未移除，不會重複派送。")) }
                } else {
                    let recoverable = accepted[id] == nil && name == filename(id) &&
                        namespace.map { id.hasPrefix($0.uuidString + ":") } == true
                    notices.append(.init(id: "outbox:" + id, title: message.payload?.displayName ?? "未確認的啟動要求",
                        detail: accepted[id] == nil
                            ? (recoverable ? "尚無接受紀錄；可核對原要求後重新傳送或取消。" : "無法核對原紀錄；已保留副本，不會自動啟動。")
                            : "原要求與接受紀錄不一致；已保留副本，請查看診斷記錄。",
                        requestID: recoverable ? id : nil, digest: recoverable ? message.payloadDigest : nil))
                }
            }
            return notices
        }
    }
}

final class CyderInstanceCoordinator {
    enum Role { case primary, secondary, unavailable }
    private let support: URL
    private let path: String
    private let startup = DispatchQueue(label: "local.cyder.instance-start")
    private let forwarding = DispatchQueue(label: "local.cyder.instance-forward")
    private let outboxQueue = DispatchQueue(label: "local.cyder.instance-outbox")
    private var outboxScan: UUID?
    private var outboxAction: UUID?
    private var forwardInFlight = false
    private(set) var outboxNotices: [CyderOutboxNotice] = []
    var onOutboxChanged: (([CyderOutboxNotice]) -> Void)?
    private let journal: CyderRequestJournal
    private let channel: CyderRequestChannel
    private var onRequest: ((CyderInstanceRequest) -> Void)?
    private var namespace: UUID?
    private var closing = false
    private var startupGeneration: UUID?
    private var startRequested = false
    private var startupCleanupRequested = false
    private var startupInFlight = false
    private var cleanupCompletions: [() -> Void] = []
    private let startupDeadline: TimeInterval
    private let beforeElection: () -> Void
    private let outboxDeadline: TimeInterval
    private let beforeOutboxRead: () -> Void
    private let forwardDeadline: TimeInterval
    private let beforeForwardSave: () -> Void
    private var primary = false
    private var delivered = Set<String>()
    private(set) var recovered: [CyderRequestJournal.Record] = []
    var onRecoveryChanged: (([CyderRequestJournal.Record]) -> Void)?
    var onRequestCancelled: ((String) -> Void)?
    var executionEpoch: UUID { journal.executorEpoch }
    private var executionReceiptInFlight = false
    private var executionReceiptRefreshPending = false
    private let beforeExecutionRead: () -> Void
    let sentinel: CyderSentinelServer

    init(support: URL = CyderPaths.support,
         bundleID: String = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier ?? "local.cyder.app",
         startupDeadline: TimeInterval = 5, beforeElection: @escaping () -> Void = {},
         outboxDeadline: TimeInterval = 5, beforeOutboxRead: @escaping () -> Void = {},
         forwardDeadline: TimeInterval = 5, beforeForwardSave: @escaping () -> Void = {},
         beforeExecutionRead: @escaping () -> Void = {},
         normalizeSettings: @escaping (Data) throws -> Data = { $0 }) {
        self.support = support
        self.startupDeadline = startupDeadline
        self.beforeElection = beforeElection
        self.outboxDeadline = outboxDeadline
        self.beforeOutboxRead = beforeOutboxRead
        self.forwardDeadline = forwardDeadline
        self.beforeForwardSave = beforeForwardSave
        self.beforeExecutionRead = beforeExecutionRead
        path = support.appendingPathComponent(".requests-v1.sock").path
        journal = CyderRequestJournal(directory: support.appendingPathComponent("request-journal"),
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
                    self.journal.open { result in
                        guard mayContinue() else { self.releaseStartupResources(); return }
                        guard case .success(let records) = result else {
                            finish(.unavailable); self.releaseStartupResources(); return
                        }
                        self.journal.namespace { namespace in
                            guard mayContinue() else { self.releaseStartupResources(); return }
                            self.namespace = namespace
                            self.startup.async {
                                let recoveredExecutors = (try? CyderExecutionOwner.recover(root: self.support.appendingPathComponent("execution-owners"))) != nil
                                let started = recoveredExecutors && self.channel.start { [weak self] message, reply in
                                    DispatchQueue.main.async { self?.receive(message, reply: reply) }
                                }
                                DispatchQueue.main.async {
                                    guard mayContinue() else { self.releaseStartupResources(); return }
                                    self.primary = started
                                    if started {
                                        self.recovered = records
                                        self.onRecoveryChanged?(records)
                                        finish(.primary)
                                        self.refreshOutbox(records: records)
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
        }
    }

    private func releaseStartupResources() {
        precondition(Thread.isMainThread)
        guard !startupCleanupRequested else { return }
        startupCleanupRequested = true
        channel.stop { [self] in
            journal.close { [self] in
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
        func respond(_ status: String, _ record: CyderRequestJournal.Record? = nil) {
            // Acceptance settings belong to the primary executor, not the wire
            // ACK/status projection (which has a smaller transport byte budget).
            var wireRecord = record
            wireRecord?.settingsSnapshot = nil
            reply(.init(protocolVersion: 1, requestID: message.requestID, primaryEpoch: journal.executorEpoch,
                        namespace: namespace, status: status, record: wireRecord))
        }
        guard primary else { respond("unavailable"); return }
        if message.kind == "hello" { respond(closing ? "closing" : "ready"); return }
        guard let id = message.requestID else { respond("rejected"); return }
        switch message.kind {
        case "submit":
            guard let payload = message.payload, message.payloadDigest == payload.digest else { respond("rejected"); return }
            journal.submit(id: id, payload: payload) { [weak self] result in
                switch result {
                case .failure(let failure): respond(failure == .closing ? "closing" : "rejected")
                case .success(let record):
                    respond("accepted", record)
                    self?.deliver(record)
                }
            }
        case "query":
            journal.query(id: id) { result in
                if case .success(let record) = result { respond("existingStatus", record) }
                else { respond("rejected") }
            }
        case "cancel":
            guard let digest = message.payloadDigest else { respond("rejected"); return }
            journal.cancel(id: id, digest: digest) { [weak self] result in
                switch result {
                case .success(let record):
                    self?.cancelled(record)
                    respond("cancelled", record)
                case .failure(let failure): respond(failure == .tooLate ? "cancellationTooLate" : "rejected")
                }
            }
        default: respond("rejected")
        }
    }

    func submit(_ payload: CyderRequestPayload, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing, let namespace else { completion(false); return }
        let id = CyderRequestJournal.makeID(namespace: namespace)
        journal.submit(id: id, payload: payload) { [weak self] result in
            guard case .success(let record) = result else { completion(false); return }
            completion(true) // durable acceptance; not game success
            self?.deliver(record)
        }
    }

    private func deliver(_ record: CyderRequestJournal.Record) {
        publish(record)
        guard !closing, !delivered.contains(record.id) else { return }
        delivered.insert(record.id)
        if let children = record.children {
            for id in children {
                journal.query(id: id) { [weak self] result in
                    if case .success(let child) = result { self?.deliver(child) }
                }
            }
            return
        }
        guard record.phase == .queued, let payload = record.payload else { return }
        onRequest?(CyderInstanceRequest(files: payload.files, arguments: payload.arguments,
            urls: payload.urls, showUI: payload.showUI, record: record))
    }

    func authorize(_ record: CyderRequestJournal.Record,
                   completion: @escaping (CyderRequestJournal.Record?) -> Void) {
        guard primary, !closing else { completion(nil); return }
        journal.authorizeDispatch(id: record.id) { [weak self] result in
            guard let self, !self.closing, case .success(let authorized) = result else { completion(nil); return }
            self.publish(authorized)
            completion(authorized)
        }
    }

    func recordSpawn(_ record: CyderRequestJournal.Record, pid: Int32, boot: String?, started: UInt64?) {
        guard let launch = record.launchID, let epoch = record.executorEpoch else { return }
        journal.receipt(id: record.id, launchID: launch, epoch: epoch, supervisorPID: pid,
                        layer: "native-launcher", boot: boot, started: started) { [weak self] result in
            if case .success(let updated) = result { self?.publish(updated) }
        }
    }

    func finish(_ record: CyderRequestJournal.Record, outcome: String, failed: Bool = false, uncertain: Bool = false) {
        guard let launch = record.launchID, let epoch = record.executorEpoch else { return }
        journal.complete(id: record.id, launchID: launch, epoch: epoch, outcome: outcome, failed: failed, uncertain: uncertain) { [weak self] result in
            if case .success(let updated) = result { self?.publish(updated) }
        }
    }

    private func publish(_ record: CyderRequestJournal.Record) {
        precondition(Thread.isMainThread)
        if let index = recovered.firstIndex(where: { $0.id == record.id }) {
            guard record.version >= recovered[index].version else { return }
            recovered[index] = record
        } else { recovered.append(record) }
        onRecoveryChanged?(recovered)
    }

    private func cancelled(_ record: CyderRequestJournal.Record) {
        publish(record)
        onRequestCancelled?(record.id)
        for id in record.children ?? [] {
            onRequestCancelled?(id)
            journal.query(id: id) { [weak self] result in
                if case .success(let child) = result { self?.publish(child) }
            }
        }
    }

    func cancelRequest(id: String, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing, let record = recovered.first(where: { $0.id == id }) else { completion(false); return }
        journal.cancel(id: id, digest: record.digest) { [weak self] result in
            guard case .success(let updated) = result else { completion(false); return }
            self?.cancelled(updated)
            completion(true)
        }
    }

    func resumeRequest(id: String, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing else { completion(false); return }
        journal.resume(id: id) { [weak self] result in
            guard let self, case .success(let updated) = result else { completion(false); return }
            self.delivered.remove(id)
            self.deliver(updated) // deliver also checks quiescing; no automatic replay on open
            completion(true)
        }
    }

    func deferRequest(id: String, reason: String, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing else { completion(false); return }
        journal.deferDispatch(id: id, outcome: reason) { [weak self] result in
            guard let self, case .success(let record) = result else { completion(false); return }
            self.publish(record)
            completion(true)
        }
    }

    func refreshRequests() {
        precondition(Thread.isMainThread)
        guard primary, !closing else { return }
        refreshExecutionReceipts()
        journal.snapshot { [weak self] result in
            guard let self, case .success(let records) = result else { return }
            var latest = Dictionary(uniqueKeysWithValues: self.recovered.map { ($0.id, $0) })
            for record in records where record.version >= (latest[record.id]?.version ?? 0) { latest[record.id] = record }
            self.recovered = Array(latest.values)
            self.onRecoveryChanged?(self.recovered)
            self.refreshOutbox(records: records)
        }
    }

    /// One physical reader persists correlated native evidence before pruning.
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
                let receipts = tickets.compactMap { ticket -> CyderRequestJournal.ExecutionReceipt? in
                    guard let correlation = ticket.correlation else { return nil }
                    return .init(ticketID: ticket.id, requestID: correlation.requestID,
                        launchID: correlation.launchID, epoch: ticket.issuer, digest: correlation.digest,
                        phase: ticket.phase, ownerPID: ticket.owner?.pid, ownerBoot: ticket.owner?.boot,
                        ownerStarted: ticket.owner?.started, childPID: ticket.child?.pid,
                        childBoot: ticket.child?.boot, childStarted: ticket.child?.started, status: ticket.status, signalled: ticket.signalled)
                }
                journal.reconcileExecutions(receipts) { [self] result in
                    guard !closing, case .success(let confirmed) = result else { finishExecutionReceiptRead(); return }
                    let ids = Set(confirmed)
                    startup.async { [self] in
                        try? CyderExecutionOwner.prune(root: root, confirmed: tickets.filter { ids.contains($0.id) })
                        DispatchQueue.main.async { [self] in
                            finishExecutionReceiptRead()
                            guard !closing else { return }
                            journal.snapshot { [weak self] result in
                                guard let self, !self.closing, case .success(let records) = result else { return }
                                var latest = Dictionary(uniqueKeysWithValues: self.recovered.map { ($0.id, $0) })
                                for record in records where record.version >= (latest[record.id]?.version ?? 0) { latest[record.id] = record }
                                self.recovered = Array(latest.values)
                                self.onRecoveryChanged?(self.recovered)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishExecutionReceiptRead() {
        executionReceiptInFlight = false
        let again = executionReceiptRefreshPending
        executionReceiptRefreshPending = false
        if again { refreshExecutionReceipts() }
    }

    /// Reconcile against a durable snapshot without submit, resume, or dispatch.
    /// A deadline does not release the physical scanner or create another one.
    private func refreshOutbox(records: [CyderRequestJournal.Record]) {
        guard primary, !closing, outboxScan == nil, outboxAction == nil else { return }
        let token = UUID(); outboxScan = token
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, outboxDeadline)) { [weak self] in
            guard let self, !self.closing, self.outboxScan == token else { return }
            self.outboxNotices = [.init(id: "outbox-scan", title: "正在核對舊要求",
                detail: "核對尚未確認；不會自動啟動，其他操作仍可使用。")]
            self.onOutboxChanged?(self.outboxNotices)
        }
        let currentNamespace = namespace
        outboxQueue.async { [self] in
            beforeOutboxRead()
            let result = Result { try CyderRequestOutbox.reconcile(support: support, records: records, namespace: currentNamespace) }
            DispatchQueue.main.async { [self] in
                guard outboxScan == token else { return }; outboxScan = nil
                guard !closing else { return }
                switch result {
                case .success(let notices): outboxNotices = notices
                case .failure: outboxNotices = [.init(id: "outbox-scan", title: "舊要求尚未核對",
                    detail: "暫時無法讀取或要求過多；請重新整理或查看診斷記錄。不會自動啟動。")]
                }
                onOutboxChanged?(outboxNotices)
            }
        }
    }

    /// Explicit recovery keeps the original identity. Journal transactions
    /// arbitrate a concurrent submit/cancel; a stale UI is never authority.
    func recoverOutbox(id noticeID: String, cancel: Bool, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard primary, !closing, outboxScan == nil, outboxAction == nil,
              let notice = outboxNotices.first(where: { $0.id == noticeID }),
              let id = notice.requestID, let digest = notice.digest,
              namespace.map({ id.hasPrefix($0.uuidString + ":") }) == true else { completion(false); return }
        let token = UUID(); outboxAction = token
        let expiresAt = ProcessInfo.processInfo.systemUptime + max(0, outboxDeadline)
        var reported = false // main only; observation does not release work
        func report(_ success: Bool) {
            guard !reported else { return }; reported = true; completion(success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, outboxDeadline)) { [weak self] in
            guard let self, self.outboxAction == token, !self.closing else { return }
            report(false)
        }
        outboxQueue.async { [self] in
            beforeOutboxRead()
            let result = Result { try CyderRequestOutbox.retainedRequest(id: id, digest: digest, support: support) }
            DispatchQueue.main.async { [self] in
                guard outboxAction == token else { return }
                guard primary, !closing, !reported, ProcessInfo.processInfo.systemUptime < expiresAt,
                      case .success(let message) = result, let payload = message.payload else {
                    outboxAction = nil; report(false); refreshRequests(); return
                }
                let accepted: CyderRequestJournal.Reply = { [self] result in
                    guard case .success(let record) = result else {
                        outboxAction = nil; report(false); refreshRequests(); return
                    }
                    if !closing {
                        outboxNotices.removeAll { $0.id == noticeID }
                        onOutboxChanged?(outboxNotices)
                        if cancel { cancelled(record) } else { deliver(record) }
                        report(true) // durable result; cleanup is a separate lifetime
                    }
                    outboxQueue.async { [self] in
                        try? CyderRequestOutbox.acknowledge(record, support: support)
                        DispatchQueue.main.async { [self] in
                            guard outboxAction == token else { return }
                            outboxAction = nil
                            if !closing { refreshRequests() }
                        }
                    }
                }
                if cancel { journal.cancel(id: id, digest: digest, completion: accepted) }
                else { journal.submit(id: id, payload: payload, completion: accepted) }
            }
        }
    }

    /// Same-ID automatic retries are confined to one monotonic five-second
    /// budget. Keep an unacknowledged copy; never convert it into a fresh ID.
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
            var outboxSaved = false
            var attempts = 0
            func done(_ accepted: Bool) { DispatchQueue.main.async {
                self.forwardInFlight = false
                guard !reported else { return }; reported = true
                completion(accepted)
            } }
            while attempts < 6, ProcessInfo.processInfo.systemUptime < deadline {
                attempts += 1
                let remaining = min(0.7, deadline - ProcessInfo.processInfo.systemUptime)
                guard remaining > 0 else { break }
                if id == nil {
                    let hello = CyderRequestMessage(protocolVersion: 1, kind: "hello", requestID: nil,
                        payloadDigest: nil, senderEpoch: sender, payload: nil)
                    if let response = CyderRequestChannel.exchange(path: path, message: hello, timeout: remaining),
                       response.status == "ready", let namespace = response.namespace {
                        id = CyderRequestJournal.makeID(namespace: namespace)
                    }
                }
                if let id {
                    let message = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id,
                        payloadDigest: payload.digest, senderEpoch: sender, payload: payload)
                    if !outboxSaved {
                        do {
                            beforeForwardSave()
                            try CyderRequestOutbox.save(message, support: support); outboxSaved = true
                        }
                        catch { done(false); return }
                    }
                    // Persistence can finish after the observation deadline.
                    // Retain that original-ID copy without starting a late send.
                    let remaining = min(0.7, deadline - ProcessInfo.processInfo.systemUptime)
                    guard remaining > 0 else { break }
                    if let response = CyderRequestChannel.exchange(path: path, message: message, timeout: remaining),
                       response.status == "accepted", let record = response.record,
                       record.id == id, record.digest == payload.digest {
                        // Durable acceptance is already known. Best-effort
                        // copy cleanup must not turn it into an unknown result.
                        DispatchQueue.main.async {
                            guard !reported else { return }; reported = true
                            completion(true)
                        }
                        try? CyderRequestOutbox.acknowledge(record, support: support)
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
        startupGeneration = nil
        if primary { journal.quiesce(completion: completion) } else { completion(true) }
    }

    func stop(completion: @escaping () -> Void = {}) {
        precondition(Thread.isMainThread)
        closing = true
        startupGeneration = nil
        guard primary else {
            if startupInFlight { cleanupCompletions.append(completion) } else { completion() }
            return
        }
        primary = false
        channel.stop { [self] in
            journal.close { [self] in
                sentinel.stop { DispatchQueue.main.async { completion() } }
            }
        }
    }
}
