import Foundation
import Darwin
import CryptoKit

struct CyderRequestPayload: Codable, Equatable {
    let files: [String]
    let arguments: [String]?
    let urls: [String]
    let showUI: Bool
    var settings: Data? = nil
    var displayName: String {
        let raw = files.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (urls.isEmpty ? "啟動要求" : "開啟連結")
        return String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(100))
    }
    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool {
        files.count + urls.count <= 128 && (arguments?.count ?? 0) <= 1024 && (settings?.count ?? 0) <= 262144
            && (!files.isEmpty || !urls.isEmpty || showUI)
            && files.allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") }
            && urls.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 65536 }
            && (arguments ?? []).allSatisfy { !$0.contains("\0") && $0.utf8.count <= 65536 }
    }
}

/// Read on the journal owner queue, before durable acceptance. An unreadable
/// file is not equivalent to defaults; only ENOENT means no saved preferences.
enum CyderAcceptedSettings {
    static let maxBytes = 262144
    static func capture(at url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                var info = stat()
                if lstat(url.path, &info) != 0, errno == ENOENT { return Data("{}".utf8) }
            }
            throw CyderRequestJournal.Failure.unavailable
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_size >= 0,
              before.st_size <= maxBytes else { throw CyderRequestJournal.Failure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              isValid(data) else { throw CyderRequestJournal.Failure.invalid }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let version = object["schemaVersion"] {
            guard let number = version as? NSNumber,
                  String(cString: number.objCType) != "c",
                  number.doubleValue.rounded() == number.doubleValue,
                  (1...13).contains(number.intValue) else { return false }
        }
        return true
    }
}

/// The durable journal is the only authority for acceptance and dispatch.
/// Its owner queue is exclusively for disk transactions, never LifecycleStore
/// or AppKit. No transport handler may acknowledge before its callback.
final class CyderRequestJournal {
    struct ExecutionReceipt: Codable, Equatable {
        let ticketID: UUID
        let requestID: String
        let launchID: String
        let epoch: UUID
        let digest: String
        let phase: String
        let ownerPID: Int32?
        let ownerBoot: String?
        let ownerStarted: UInt64?
        let childPID: Int32?
        let childBoot: String?
        let childStarted: UInt64?
        let status: Int32?
        var signalled: Bool? = nil
    }
    enum Phase: String, Codable {
        case queued, dispatching, observing, completed, failed, cancelled, uncertain, awaitingUserResume
    }
    struct Record: Codable, Equatable {
        let id: String
        let digest: String
        var version: UInt64
        var phase: Phase
        var payload: CyderRequestPayload?
        var launchID: String?
        var executorEpoch: UUID?
        var supervisorPID: Int32?
        var receiptLayer: String? = nil
        var processBoot: String? = nil
        var processStarted: UInt64? = nil
        var outcome: String?
        var children: [String]? = nil
        var displayName: String? = nil
        var settingsSnapshot: Data? = nil
        var executionReceipt: ExecutionReceipt? = nil
    }
    struct Document: Codable {
        let schema: Int
        let namespace: UUID
        var version: UInt64
        var records: [String: Record]
    }
    enum Failure: Error, Equatable {
        case unavailable, corrupt, unsupported, invalid, conflictingPayload, closing, full, tooLate, missing, wrongExecutor
    }
    enum Fault { case none, beforeWrite, afterCommit }
    typealias Reply = (Result<Record, Failure>) -> Void
    private let directory: URL
    private let file: URL
    private let queue = DispatchQueue(label: "local.cyder.request-journal", qos: .userInitiated)
    private let delivery: DispatchQueue
    private let captureSettings: (() throws -> Data)?
    private var document: Document?
    private var closing = false
    private var fault: Fault = .none
    private let limit: Int
    private let maxBytes = 16 * 1024 * 1024
    private var available = false
    private var ownerFD: Int32 = -1
    let executorEpoch = UUID()

    init(directory: URL, limit: Int = 512, delivery: DispatchQueue = .main, captureSettings: (() throws -> Data)? = nil) {
        self.directory = directory
        file = directory.appendingPathComponent("requests-v1.json")
        self.limit = limit
        self.delivery = delivery
        self.captureSettings = captureSettings
    }

    func open(completion: @escaping (Result<[Record], Failure>) -> Void) {
        queue.async { [self] in
            guard ownerFD < 0 else { delivery.async { completion(.failure(.unavailable)) }; return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                var info = stat()
                guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                      info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unavailable }
                let candidate = Darwin.open(directory.appendingPathComponent(".owner").path,
                                            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard candidate >= 0 else { throw Failure.unavailable }
                guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(candidate); throw Failure.unavailable }
                ownerFD = candidate
                let marker = directory.appendingPathComponent("initialized")
                if FileManager.default.fileExists(atPath: file.path) {
                    let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw Failure.corrupt }
                    defer { Darwin.close(fd) }
                    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                          info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                          info.st_size <= maxBytes else { throw Failure.corrupt }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
                    guard data.count <= maxBytes else { throw Failure.corrupt }
                    var loaded: Document
                    do { loaded = try JSONDecoder().decode(Document.self, from: data) }
                    catch { throw Failure.corrupt }
                    guard loaded.schema == 1 else { throw Failure.unsupported }
                    guard loaded.records.count <= limit,
                          loaded.records.allSatisfy({ $0.key == $0.value.id && validID($0.key, namespace: loaded.namespace) }) else { throw Failure.corrupt }
                    for (id, record) in loaded.records {
                        if let payload = record.payload, !payload.isValid || payload.digest != record.digest { throw Failure.corrupt }
                        if let snapshot = record.settingsSnapshot, !CyderAcceptedSettings.isValid(snapshot) { throw Failure.corrupt }
                        switch record.phase {
                        case .queued:
                            loaded.records[id]?.phase = .awaitingUserResume
                            loaded.records[id]?.version = loaded.version + 1
                        case .dispatching, .observing:
                            loaded.records[id]?.phase = .uncertain
                            loaded.records[id]?.version = loaded.version + 1
                        default: break
                        }
                    }
                    loaded.version += 1
                    try persist(loaded)
                    document = loaded
                } else {
                    // Missing history after initialization cannot authorize old IDs anew.
                    guard !FileManager.default.fileExists(atPath: marker.path) else { throw Failure.corrupt }
                    let initial = Document(schema: 1, namespace: UUID(), version: 0, records: [:])
                    try persist(initial)
                    document = initial
                }
                if !FileManager.default.fileExists(atPath: marker.path) {
                    try Data("1\n".utf8).write(to: marker, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                }
                available = true
                let records = Array(document!.records.values)
                delivery.async { completion(.success(records)) }
            } catch {
                available = false
                if ownerFD >= 0 { Darwin.close(ownerFD); ownerFD = -1 }
                let failure = error as? Failure ?? .unavailable
                delivery.async { completion(.failure(failure)) }
            }
        }
    }

    /// Release only after dispatch is frozen and required state was saved.
    func close(completion: @escaping () -> Void) {
        queue.async { [self] in
            available = false
            closing = true
            if ownerFD >= 0 { Darwin.close(ownerFD); ownerFD = -1 }
            delivery.async { completion() }
        }
    }

    deinit { if ownerFD >= 0 { Darwin.close(ownerFD) } }

    func namespace(completion: @escaping (UUID?) -> Void) {
        queue.async { [self] in
            let result = available ? document?.namespace : nil
            delivery.async { completion(result) }
        }
    }

    static func makeID(namespace: UUID) -> String { namespace.uuidString + ":" + UUID().uuidString }
    private func validID(_ id: String, namespace: UUID) -> Bool {
        let parts = id.split(separator: ":")
        return parts.count == 2 && String(parts[0]) == namespace.uuidString && UUID(uuidString: String(parts[1])) != nil
    }

    func submit(id: String, payload: CyderRequestPayload, completion: @escaping Reply) {
        transaction(completion) { [self] current in
            guard validID(id, namespace: current.namespace), payload.isValid else { throw Failure.invalid }
            if let previous = current.records[id] {
                guard previous.digest == payload.digest else { throw Failure.conflictingPayload }
                return previous
            }
            guard !closing else { throw Failure.closing }
            let settingsSnapshot = try snapshot(for: payload)
            var children: [CyderRequestPayload] = payload.files.map {
                CyderRequestPayload(files: [$0], arguments: payload.arguments, urls: [], showUI: false, settings: payload.settings)
            }
            children += payload.urls.map {
                CyderRequestPayload(files: [], arguments: payload.arguments, urls: [$0], showUI: false, settings: payload.settings)
            }
            if children.count > 1 {
                if payload.showUI { children.append(.init(files: [], arguments: nil, urls: [], showUI: true)) }
                guard current.records.count + children.count + 1 <= limit else { throw Failure.full }
                var childIDs: [String] = []
                for (index, child) in children.enumerated() {
                    let hash = SHA256.hash(data: Data("\(id):\(index)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                    let chars = Array(hash)
                    let uuid = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-").uppercased()
                    let childID = current.namespace.uuidString + ":" + uuid
                    guard current.records[childID] == nil else { throw Failure.conflictingPayload }
                    current.records[childID] = Record(id: childID, digest: child.digest, version: current.version + 1, phase: .queued, payload: child, displayName: child.displayName, settingsSnapshot: child.files.isEmpty && child.urls.isEmpty ? nil : settingsSnapshot)
                    childIDs.append(childID)
                }
                let parent = Record(id: id, digest: payload.digest, version: current.version + 1, phase: .completed,
                                    outcome: "batchAccepted", children: childIDs)
                current.records[id] = parent
                return parent
            }
            guard current.records.count < limit else { throw Failure.full }
            let record = Record(id: id, digest: payload.digest, version: current.version + 1, phase: .queued, payload: payload, displayName: payload.displayName, settingsSnapshot: settingsSnapshot)
            current.records[id] = record
            return record
        }
    }

    private func snapshot(for payload: CyderRequestPayload) throws -> Data? {
        guard !payload.files.isEmpty || !payload.urls.isEmpty, let captureSettings else { return nil }
        let snapshot = try captureSettings()
        guard CyderAcceptedSettings.isValid(snapshot) else { throw Failure.invalid }
        return snapshot
    }

    func query(id: String, completion: @escaping Reply) {
        queue.async { [self] in
            let result: Result<Record, Failure> = available
                ? document?.records[id].map { .success($0) } ?? .failure(.missing) : .failure(.unavailable)
            delivery.async { completion(result) }
        }
    }

    func snapshot(completion: @escaping (Result<[Record], Failure>) -> Void) {
        queue.async { [self] in
            let result: Result<[Record], Failure> = available && document != nil
                ? .success(Array(document!.records.values)) : .failure(.unavailable)
            delivery.async { completion(result) }
        }
    }

    func cancel(id: String, digest: String, completion: @escaping Reply) {
        transaction(completion) { [self] current in
            guard validID(id, namespace: current.namespace), digest.count == 64 else { throw Failure.invalid }
            var record = current.records[id] ?? Record(id: id, digest: digest, version: 0, phase: .queued)
            guard record.digest == digest else { throw Failure.conflictingPayload }
            if let children = record.children {
                guard children.allSatisfy({ current.records[$0].map { [.queued, .awaitingUserResume, .cancelled].contains($0.phase) } == true }) else { throw Failure.tooLate }
                for child in children {
                    current.records[child]?.phase = .cancelled
                    current.records[child]?.payload = nil
                    current.records[child]?.settingsSnapshot = nil
                    current.records[child]?.version = current.version + 1
                }
            } else {
                guard [.queued, .awaitingUserResume, .cancelled].contains(record.phase) else { throw Failure.tooLate }
            }
            guard current.records[id] != nil || current.records.count < limit else { throw Failure.full }
            record.phase = .cancelled
            record.payload = nil
            record.settingsSnapshot = nil
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    /// Once committed, absence of a receipt is uncertain; never put this ID
    /// back in queued or replay it after a primary crash.
    func authorizeDispatch(id: String, completion: @escaping Reply) {
        transaction(completion) { [self] current in
            guard !closing else { throw Failure.closing }
            guard var record = current.records[id] else { throw Failure.missing }
            guard record.phase == .queued, record.payload != nil else { throw Failure.tooLate }
            record.phase = .dispatching
            record.launchID = UUID().uuidString
            record.executorEpoch = executorEpoch
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    func receipt(id: String, launchID: String, epoch: UUID, supervisorPID: Int32, layer: String = "supervisor", boot: String? = nil, started: UInt64? = nil, completion: @escaping Reply) {
        transaction(completion) { current in
            guard var record = current.records[id], record.launchID == launchID,
                  record.executorEpoch == epoch else { throw Failure.wrongExecutor }
            guard record.phase == .dispatching, supervisorPID > 0 else { throw Failure.tooLate }
            record.phase = .observing
            record.supervisorPID = supervisorPID // shell evidence, never a Windows PID
            record.receiptLayer = layer
            record.processBoot = boot
            record.processStarted = started
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    /// A native executor receipt proves only its own layer. Even a successful
    /// Bash exit does not resolve an uncertain Windows launch or authorize retry.
    func reconcileExecutions(_ receipts: [ExecutionReceipt], completion: @escaping (Result<[UUID], Failure>) -> Void) {
        queue.async { [self] in
            do {
                guard !closing, available, var next = document else { throw Failure.unavailable }
                guard receipts.count <= 512 else { throw Failure.full }
                let ranks = ["prepared": 0, "active": 1, "uncertain": 2, "finished": 3, "revoked": 3]
                var confirmed: [UUID] = []
                for receipt in receipts {
                    guard let rank = ranks[receipt.phase], var record = next.records[receipt.requestID],
                          record.digest == receipt.digest, record.launchID == receipt.launchID,
                          record.executorEpoch == receipt.epoch else { continue }
                    if let old = record.executionReceipt {
                        guard old.ticketID == receipt.ticketID,
                              rank >= (ranks[old.phase] ?? 4),
                              !(rank == 3 && ranks[old.phase] == 3 && old != receipt) else { continue }
                        if old.ownerPID != nil {
                            guard old.ownerPID == receipt.ownerPID, old.ownerBoot == receipt.ownerBoot,
                                  old.ownerStarted == receipt.ownerStarted else { continue }
                        }
                        if old.childPID != nil {
                            guard old.childPID == receipt.childPID, old.childBoot == receipt.childBoot,
                                  old.childStarted == receipt.childStarted else { continue }
                        }
                    }
                    if record.executionReceipt != receipt {
                        record.executionReceipt = receipt
                        record.version = next.version + 1
                        next.records[record.id] = record
                    }
                    confirmed.append(receipt.ticketID)
                }
                if next.records != document!.records {
                    next.version += 1
                    try persist(next)
                    document = next
                }
                if fault == .afterCommit { fault = .none; return }
                delivery.async { completion(.success(confirmed)) }
            } catch { let failure = error as? Failure ?? .unavailable; delivery.async { completion(.failure(failure)) } }
        }
    }

    func complete(id: String, launchID: String, epoch: UUID, outcome: String, failed: Bool, uncertain: Bool = false, completion: @escaping Reply) {
        transaction(completion) { current in
            guard var record = current.records[id], record.launchID == launchID,
                  record.executorEpoch == epoch else { throw Failure.wrongExecutor }
            guard [.dispatching, .observing].contains(record.phase) else { throw Failure.tooLate }
            record.phase = uncertain ? .uncertain : (failed ? .failed : .completed)
            if !uncertain { record.payload = nil; record.settingsSnapshot = nil } // uncertain retains recovery context; never automatically replay
            record.outcome = String(outcome.prefix(128))
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    func resume(id: String, completion: @escaping Reply) {
        transaction(completion) { [self] current in
            guard !closing else { throw Failure.closing }
            guard var record = current.records[id], record.phase == .awaitingUserResume,
                  record.payload != nil else { throw Failure.tooLate }
            // Legacy queued records acquire a snapshot only after explicit resume.
            if record.settingsSnapshot == nil { record.settingsSnapshot = try snapshot(for: record.payload!) }
            record.phase = .queued
            record.outcome = nil
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    /// Read-only preparation failed before dispatch. Persist a user-resumable
    /// state; never use this to rewind an executor that may already have spawned.
    func deferDispatch(id: String, outcome: String, completion: @escaping Reply) {
        transaction(completion) { [self] current in
            guard !closing else { throw Failure.closing }
            guard var record = current.records[id], record.phase == .queued,
                  record.payload != nil else { throw Failure.tooLate }
            record.phase = .awaitingUserResume
            record.outcome = String(outcome.prefix(128))
            record.version = current.version + 1
            current.records[id] = record
            return record
        }
    }

    func quiesce(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            closing = true
            guard available, var next = document else { delivery.async { completion(false) }; return }
            for (id, record) in next.records where record.phase == .queued {
                next.records[id]?.phase = .awaitingUserResume
                next.records[id]?.version = next.version + 1
            }
            next.version += 1
            do {
                try persist(next)
                document = next
                delivery.async { completion(true) }
            } catch {
                delivery.async { completion(false) }
            }
        }
    }

    /// Used by the fault harness; exercises the same atomic write/ACK boundary.
    func inject(_ fault: Fault) { queue.async { self.fault = fault } }

    private func transaction(_ reply: @escaping Reply, change: @escaping (inout Document) throws -> Record) {
        queue.async { [self] in
            do {
                guard available, var next = document else { throw Failure.unavailable }
                let record = try change(&next)
                if next.records != document!.records {
                    next.version += 1
                    try persist(next)
                    document = next
                }
                if fault == .afterCommit { fault = .none; return } // simulate a lost ACK
                delivery.async { reply(.success(record)) }
            } catch {
                let failure = error as? Failure ?? .unavailable
                delivery.async { reply(.failure(failure)) }
            }
        }
    }

    private func persist(_ document: Document) throws {
        if fault == .beforeWrite { fault = .none; throw Failure.unavailable }
        let data = try JSONEncoder().encode(document)
        guard data.count <= maxBytes else { throw Failure.full }
        let temporary = directory.appendingPathComponent(".journal-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw Failure.unavailable }
                offset += result
            }
        }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
        // Full sync is supported on local macOS filesystems; don't acknowledge
        // power-loss durability if the filesystem cannot provide it.
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw Failure.unavailable }
        guard rename(temporary.path, file.path) == 0 else { throw Failure.unavailable }
        let parent = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard parent >= 0 else { available = false; throw Failure.unavailable }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { available = false; throw Failure.unavailable }
    }
}
