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
    /// Fingerprint over an explicit, versioned byte layout, so it cannot change
    /// with Foundation's JSON formatting (escaping, key order, number style).
    /// Layout: "cyder-request-v2\0", then for each field a tag byte and its
    /// content; strings and data are u64-BE length-prefixed, lists are
    /// u64-BE count-prefixed, optionals carry a 0/1 presence byte.
    var digest: String {
        var bytes = Data("cyder-request-v2\0".utf8)
        func u64(_ value: Int) { withUnsafeBytes(of: UInt64(value).bigEndian) { bytes.append(contentsOf: $0) } }
        func blob(_ data: Data) { u64(data.count); bytes.append(data) }
        func list(_ tag: UInt8, _ values: [String]?) {
            bytes.append(tag)
            guard let values else { bytes.append(0); return }
            bytes.append(1); u64(values.count)
            values.forEach { blob(Data($0.utf8)) }
        }
        list(1, files)
        list(2, arguments)
        list(3, urls)
        bytes.append(4); bytes.append(showUI ? 1 : 0)
        bytes.append(5)
        if let settings { bytes.append(1); blob(settings) } else { bytes.append(0) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// The 0.14.0-rc.1 fingerprint (sorted-key JSONEncoder). Accepted only for
    /// records and peers created by that build; never produced for new ones.
    var legacyDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    func matches(_ digest: String?) -> Bool {
        guard let digest else { return false }
        return digest == self.digest || digest == legacyDigest
    }
    var isValid: Bool {
        files.count + urls.count <= 128 && (arguments?.count ?? 0) <= 1024 && (settings?.count ?? 0) <= 262144
            && (!files.isEmpty || !urls.isEmpty || showUI)
            && files.allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") }
            && urls.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 65536 }
            && (arguments ?? []).allSatisfy { !$0.contains("\0") && $0.utf8.count <= 65536 }
    }
}

/// Read on the registry queue at acceptance. An unreadable
/// file is not equivalent to defaults; only ENOENT means no saved preferences.
///
/// Consistency comes from the writer, not from timestamps: CyderSettingsStore
/// replaces settings.json atomically (write + rename), so one open descriptor
/// always reads one complete version. Comparing ctime/mtime before and after
/// the read rejected valid snapshots, because renaming a new file over the old
/// one updates the old inode's ctime. A non-atomic external editor can expose
/// a partial file; that is detected by parsing and retried a few times.
enum CyderAcceptedSettings {
    static let maxBytes = 262144
    static let retryDelays: [useconds_t] = [10_000, 50_000, 200_000]
    static func capture(at url: URL) throws -> Data {
        for delay in [0] + retryDelays {
            if delay > 0 { usleep(delay) }
            do { return try readOnce(url) } catch Partial.content { continue }
        }
        throw CyderRequestRegistry.Failure.invalid
    }
    /// Possibly an in-progress non-atomic write; owner/type errors are final.
    private enum Partial: Error { case content }

    private static func readOnce(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                var info = stat()
                if lstat(url.path, &info) != 0, errno == ENOENT { return Data("{}".utf8) }
            }
            throw CyderRequestRegistry.Failure.unavailable
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0,
              info.st_size <= maxBytes else { throw CyderRequestRegistry.Failure.invalid }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes + 1) ?? Data()
        guard data.count == info.st_size, isValid(data) else { throw Partial.content }
        return data
    }

    /// Structural check only. Schema meaning and migration belong to
    /// CyderSettings (acceptedSnapshot decodes and re-encodes it); a range here
    /// had to be edited on every schema bump and broke mixed-version snapshots.
    static func isValid(_ data: Data) -> Bool {
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let version = object["schemaVersion"] {
            guard let number = version as? NSNumber,
                  String(cString: number.objCType) != "c",
                  number.doubleValue.rounded() == number.doubleValue,
                  number.intValue >= 1 else { return false }
        }
        return true
    }
}

/// In-memory authority for launch requests accepted by this primary process.
///
/// Nothing is persisted. A request that was queued when Cyder quit or crashed
/// is simply gone, so it can never be replayed; the user starts the game again.
/// What must survive Cyder (which process belongs to which launch) lives in
/// the native executor tickets, not here. The registry only provides:
/// - same-ID idempotency for a secondary instance's retries within a session;
/// - the settings snapshot frozen at acceptance;
/// - the dispatch fence (launch ID + executor epoch) correlated into tickets.
/// Terminal records are evicted oldest-first, so it never fills up.
final class CyderRequestRegistry {
    enum Phase: String, Codable { case queued, dispatching, completed, failed, uncertain }
    struct Record: Codable, Equatable {
        let id: String
        let digest: String
        var version: UInt64
        var phase: Phase
        var payload: CyderRequestPayload?
        var launchID: String?
        var executorEpoch: UUID?
        var outcome: String?
        var children: [String]? = nil
        var displayName: String? = nil
        var settingsSnapshot: Data? = nil
        var isTerminal: Bool { [.completed, .failed, .uncertain].contains(phase) }
    }
    enum Failure: Error, Equatable { case unavailable, invalid, conflictingPayload, closing, full, tooLate, missing, wrongExecutor }
    typealias Reply = (Result<Record, Failure>) -> Void
    private let queue = DispatchQueue(label: "local.cyder.request-registry", qos: .userInitiated)
    private let delivery: DispatchQueue
    private let captureSettings: (() throws -> Data)?
    private var records: [String: Record] = [:]
    private var order: [String] = [] // insertion order for eviction
    private var version: UInt64 = 0
    private var closing = false
    /// Bounds memory, not correctness: only terminal records are evicted, and
    /// active ones are bounded by ingress. A full table of active work refuses.
    private let capacity: Int
    let executorEpoch = UUID()
    /// IDs are "<namespace>:<uuid>"; a fresh namespace per primary process
    /// makes IDs from an earlier process unacceptable instead of colliding.
    let namespace = UUID()

    init(capacity: Int = 256, delivery: DispatchQueue = .main, captureSettings: (() throws -> Data)? = nil) {
        self.capacity = capacity
        self.delivery = delivery
        self.captureSettings = captureSettings
    }

    static func makeID(namespace: UUID) -> String { namespace.uuidString + ":" + UUID().uuidString }
    private func validID(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && String(parts[0]) == namespace.uuidString && UUID(uuidString: String(parts[1])) != nil
    }

    /// Stops new acceptance and dispatch; in-flight launches still complete.
    func close(completion: @escaping () -> Void = {}) {
        queue.async { [self] in closing = true; delivery.async { completion() } }
    }

    func submit(id: String, payload: CyderRequestPayload, completion: @escaping Reply) {
        transaction(completion) { [self] in
            guard validID(id), payload.isValid else { throw Failure.invalid }
            if let previous = records[id] {
                guard payload.matches(previous.digest) else { throw Failure.conflictingPayload }
                return previous // a retried delivery of the same request
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
                try reserve(children.count + 1)
                var childIDs: [String] = []
                for (index, child) in children.enumerated() {
                    // Deterministic child IDs keep a retried batch idempotent.
                    let hash = SHA256.hash(data: Data("\(id):\(index)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                    let chars = Array(hash)
                    let uuid = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-").uppercased()
                    let childID = namespace.uuidString + ":" + uuid
                    guard records[childID] == nil else { throw Failure.conflictingPayload }
                    insert(Record(id: childID, digest: child.digest, version: nextVersion(), phase: .queued, payload: child,
                                  displayName: child.displayName,
                                  settingsSnapshot: child.files.isEmpty && child.urls.isEmpty ? nil : settingsSnapshot))
                    childIDs.append(childID)
                }
                let parent = Record(id: id, digest: payload.digest, version: nextVersion(), phase: .completed,
                                    outcome: "batchAccepted", children: childIDs)
                insert(parent)
                return parent
            }
            try reserve(1)
            let record = Record(id: id, digest: payload.digest, version: nextVersion(), phase: .queued, payload: payload,
                                displayName: payload.displayName, settingsSnapshot: settingsSnapshot)
            insert(record)
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
            let result: Result<Record, Failure> = records[id].map { .success($0) } ?? .failure(.missing)
            delivery.async { completion(result) }
        }
    }

    /// Fences dispatch: a record is authorized once, and the launch ID plus
    /// this process's executor epoch are what the native ticket correlates.
    func authorizeDispatch(id: String, completion: @escaping Reply) {
        transaction(completion) { [self] in
            guard !closing else { throw Failure.closing }
            guard var record = records[id] else { throw Failure.missing }
            guard record.phase == .queued, record.payload != nil else { throw Failure.tooLate }
            record.phase = .dispatching
            record.launchID = UUID().uuidString
            record.executorEpoch = executorEpoch
            record.version = nextVersion()
            records[id] = record
            return record
        }
    }

    func complete(id: String, launchID: String, epoch: UUID, outcome: String, failed: Bool, uncertain: Bool = false, completion: @escaping Reply) {
        transaction(completion) { [self] in
            guard var record = records[id], record.launchID == launchID,
                  record.executorEpoch == epoch else { throw Failure.wrongExecutor }
            guard record.phase == .dispatching else { throw Failure.tooLate }
            record.phase = uncertain ? .uncertain : (failed ? .failed : .completed)
            record.payload = nil; record.settingsSnapshot = nil
            record.outcome = String(outcome.prefix(128))
            record.version = nextVersion()
            records[id] = record
            return record
        }
    }

    /// Withdraws a request that never reached dispatch (e.g. its environment
    /// could not be resolved). The user simply starts it again.
    func fail(id: String, outcome: String, completion: @escaping Reply) {
        transaction(completion) { [self] in
            guard var record = records[id] else { throw Failure.missing }
            guard record.phase == .queued else { throw Failure.tooLate }
            record.phase = .failed
            record.payload = nil; record.settingsSnapshot = nil
            record.outcome = String(outcome.prefix(128))
            record.version = nextVersion()
            records[id] = record
            return record
        }
    }

    var count: Int { queue.sync { records.count } }

    private func nextVersion() -> UInt64 { version += 1; return version }
    private func insert(_ record: Record) {
        if records[record.id] == nil { order.append(record.id) }
        records[record.id] = record
    }
    /// Evicts the oldest terminal records until `needed` more fit.
    private func reserve(_ needed: Int) throws {
        guard needed <= capacity else { throw Failure.full }
        var index = 0
        while records.count + needed > capacity, index < order.count {
            let id = order[index]
            if let record = records[id], record.isTerminal,
               // keep a batch parent while any child is still active
               (record.children ?? []).allSatisfy({ records[$0]?.isTerminal ?? true }) {
                records[id] = nil; order.remove(at: index)
            } else { index += 1 }
        }
        guard records.count + needed <= capacity else { throw Failure.full }
    }
    private func transaction(_ reply: @escaping Reply, change: @escaping () throws -> Record) {
        queue.async { [self] in
            let result: Result<Record, Failure>
            do { result = .success(try change()) }
            catch { result = .failure(error as? Failure ?? .unavailable) }
            delivery.async { reply(result) }
        }
    }
}
