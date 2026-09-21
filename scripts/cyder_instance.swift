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

final class CyderInstanceCoordinator {
    enum Role { case primary, secondary, unavailable }
    private let support: URL
    private let path: String
    private let startup = DispatchQueue(label: "local.cyder.instance-start")
    private let forwarding = DispatchQueue(label: "local.cyder.instance-forward")
    private let journal: CyderRequestJournal
    private let channel: CyderRequestChannel
    private var onRequest: ((CyderInstanceRequest) -> Void)?
    private var namespace: UUID?
    private var closing = false
    private var primary = false
    private var delivered = Set<String>()
    private(set) var recovered: [CyderRequestJournal.Record] = []
    var onRecoveryChanged: (([CyderRequestJournal.Record]) -> Void)?
    var onRequestCancelled: ((String) -> Void)?
    let sentinel: CyderSentinelServer

    init(support: URL = CyderPaths.support,
         bundleID: String = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier ?? "local.cyder.app") {
        self.support = support
        path = support.appendingPathComponent(".requests-v1.sock").path
        journal = CyderRequestJournal(directory: support.appendingPathComponent("request-journal"))
        channel = CyderRequestChannel(path: path)
        sentinel = CyderSentinelServer(support: support, bundleID: bundleID)
    }

    func start(onRequest: @escaping (CyderInstanceRequest) -> Void, completion: @escaping (Role) -> Void) {
        precondition(Thread.isMainThread)
        self.onRequest = onRequest
        startup.async { [self] in
            let role = sentinel.becomePrimary()
            DispatchQueue.main.async {
                switch role {
                case .secondary: completion(.secondary)
                case .unavailable: completion(.unavailable)
                case .primary:
                    self.journal.open { result in
                        guard case .success(let records) = result else {
                            self.sentinel.stop { DispatchQueue.main.async { completion(.unavailable) } }
                            return
                        }
                        self.recovered = records
                        self.journal.namespace { namespace in
                            self.namespace = namespace
                            self.startup.async {
                                let started = self.channel.start { [weak self] message, reply in
                                    DispatchQueue.main.async { self?.receive(message, reply: reply) }
                                }
                                DispatchQueue.main.async {
                                    self.primary = started
                                    if started {
                                        self.onRecoveryChanged?(records)
                                        completion(.primary)
                                    } else {
                                        self.journal.close {
                                            self.sentinel.stop { DispatchQueue.main.async { completion(.unavailable) } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func receive(_ message: CyderRequestMessage, reply: @escaping (CyderRequestReply) -> Void) {
        precondition(Thread.isMainThread)
        func respond(_ status: String, _ record: CyderRequestJournal.Record? = nil) {
            reply(.init(protocolVersion: 1, requestID: message.requestID, primaryEpoch: journal.executorEpoch,
                        namespace: namespace, status: status, record: record))
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
        guard !closing else { completion(nil); return }
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

    func refreshRequests() {
        precondition(Thread.isMainThread)
        guard primary, !closing else { return }
        journal.snapshot { [weak self] result in
            guard let self, case .success(let records) = result else { return }
            var latest = Dictionary(uniqueKeysWithValues: self.recovered.map { ($0.id, $0) })
            for record in records where record.version >= (latest[record.id]?.version ?? 0) { latest[record.id] = record }
            self.recovered = Array(latest.values)
            self.onRecoveryChanged?(self.recovered)
        }
    }

    /// Same-ID automatic retries are confined to one monotonic five-second
    /// budget. Keep an unacknowledged copy; never convert it into a fresh ID.
    func forward(files: [String], arguments: [String]?, urls: [String] = [], showUI: Bool,
                 completion: @escaping (Bool) -> Void) {
        let payload = CyderRequestPayload(files: files, arguments: arguments, urls: urls, showUI: showUI)
        forwarding.async { [self] in
            let sender = UUID()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var id: String?
            var outbox: URL?
            var attempts = 0
            func done(_ accepted: Bool) { DispatchQueue.main.async { completion(accepted) } }
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
                    if outbox == nil {
                        let directory = support.appendingPathComponent("request-outbox")
                        do {
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                                    attributes: [.posixPermissions: 0o700])
                            let url = directory.appendingPathComponent(id.replacingOccurrences(of: ":", with: "-") + ".json")
                            let data = try JSONEncoder().encode(message)
                            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                            guard fd >= 0 else { done(false); return }
                            defer { Darwin.close(fd) }
                            let written = data.withUnsafeBytes { bytes -> Bool in
                                var offset = 0
                                while offset < bytes.count {
                                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                    if count < 0 && errno == EINTR { continue }
                                    guard count > 0 else { return false }
                                    offset += count
                                }
                                return Darwin.fsync(fd) == 0
                            }
                            guard written else { done(false); return }
                            outbox = url
                        } catch { done(false); return }
                    }
                    if let response = CyderRequestChannel.exchange(path: path, message: message, timeout: remaining),
                       response.status == "accepted", let record = response.record,
                       record.id == id, record.digest == payload.digest {
                        if let outbox { try? FileManager.default.removeItem(at: outbox) }
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
        if primary { journal.quiesce(completion: completion) } else { completion(true) }
    }

    func stop(completion: @escaping () -> Void = {}) {
        precondition(Thread.isMainThread)
        closing = true
        guard primary else { completion(); return }
        primary = false
        channel.stop { [self] in
            journal.close { [self] in
                sentinel.stop { DispatchQueue.main.async { completion() } }
            }
        }
    }
}
