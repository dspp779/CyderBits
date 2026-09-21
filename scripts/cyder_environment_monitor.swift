import Foundation
import Darwin

/// One waiter per verified server generation, with bounded independent probes.
/// A waiter completion is merely a reason to calibrate; it is never exit proof.
final class CyderEnvironmentMonitor {
    typealias L = CyderLifecycle
    struct Saved: Codable { let identity: CyderEnvironmentProbe.Identity; let generation: UInt64 }
    private struct Registry: Codable { let schema: Int; let records: [Saved] }
    private struct DrainObservation {
        let generation: UInt64
        let completed: (String) -> Void
        var rootExited = false
    }
    private final class Entry {
        let identity: CyderEnvironmentProbe.Identity
        var generation: UInt64
        var owner: L.ProcessID?
        var pending: UUID?
        var waiter: Process?
        var waiterToken: UUID?
        var waiterAttempted = false
        var emptySince: TimeInterval?
        var graceUntil: TimeInterval
        var exited = false
        var executions: Set<UUID> = []
        var drains: [UUID: DrainObservation] = [:]
        var calibration = UUID()
        init(_ saved: Saved, grace: TimeInterval) {
            identity = saved.identity; generation = saved.generation; graceUntil = grace
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.environment-monitor")
    private let workers = DispatchQueue(label: "local.cyder.environment-probe", qos: .utility, attributes: .concurrent)
    private let persistence = DispatchQueue(label: "local.cyder.environment-history", qos: .utility)
    private let epoch: UUID
    private let file: URL
    private let event: (L.Event) -> Void
    private let probe: (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result
    private let clock: () -> TimeInterval
    private let waitersEnabled: Bool
    private let expectedEngine: String?
    private var entries: [L.EnvironmentID: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var inFlight = 0
    private var registryWritable = true
    private var nextProbeIndex = 0
    var onIssue: ((String) -> Void)?

    init(epoch: UUID, directory: URL, expectedEngine: URL? = nil, waitersEnabled: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         probe: @escaping (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result = { CyderEnvironmentProbe.inspect($0) },
         event: @escaping (L.Event) -> Void) {
        self.epoch = epoch; self.file = directory.appendingPathComponent("managed-environments-v1.json")
        self.expectedEngine = expectedEngine?.path
        self.waitersEnabled = waitersEnabled; self.clock = clock; self.probe = probe; self.event = event
    }
    func restore(completion: @escaping () -> Void) {
        persistence.async { [self] in
            var records: [Saved] = []
            let expected = expectedEngine.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            var valid = true
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                    defer { Darwin.close(fd) }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_size <= 65536, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65537) ?? Data()
                    let registry = try JSONDecoder().decode(Registry.self, from: data)
                    records = registry.records
                    guard registry.schema == 1, records.count <= 32,
                          Set(records.map { $0.identity.environment }).count == records.count,
                          records.allSatisfy({ record in
                              record.generation < UInt64.max && record.identity.environment.uid == getuid()
                                && record.identity.environment.namespace == "wine-user"
                                && record.identity.prefix.hasPrefix("/")
                                && (expected == nil || expected == record.identity.engine)
                          }) else { throw CocoaError(.fileReadCorruptFile) }
                } catch { valid = false; records.removeAll() }
            }
            queue.async {
                self.registryWritable = valid
                guard !self.closed else { DispatchQueue.main.async(execute: completion); return }
                for record in records {
                    // A new app epoch rejects every observer from the old run.
                    // Persisted ownership is only permission to inspect this prefix.
                    self.install(Saved(identity: record.identity, generation: record.generation + 1), grace: 0)
                }
                if !valid { DispatchQueue.main.async { self.onIssue?("無法讀取先前的 Windows 環境紀錄；可從遊戲庫重新檢查。") } }
                self.startTimer(); self.tick()
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
    func track(prefix: URL, engine: URL, completion: @escaping (String?) -> Void = { _ in }) {
        manage(prefix: prefix, engine: engine, execution: nil, drained: nil, completion: completion)
    }
    /// Keep empty samples provisional while a native executor can still spawn
    /// Wine. Observation deadlines never release this ownership.
    func beginExecution(prefix: URL, engine: URL, drained: ((String) -> Void)? = nil) async -> UUID? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            manage(prefix: prefix, engine: engine, execution: token, drained: drained) { path in
                continuation.resume(returning: path == nil ? nil : token)
            }
        }
    }
    func endExecution(_ token: UUID, completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            defer { DispatchQueue.main.async(execute: completion) }
            guard !closed else { return }
            for entry in entries.values where entry.executions.remove(token) != nil {
                entry.emptySince = nil; entry.calibration = UUID()
                entry.graceUntil = entry.drains.values.contains { $0.generation == entry.generation && $0.rootExited }
                    ? clock() : clock() + 30
                schedule(entry)
            }
        }
    }
    /// Native root proof shortens the launch grace only for the registration
    /// whose actual prefix identity matches the native spawn ticket. Two probes
    /// begun after both proof and executor release are still required.
    func confirmRootExit(_ token: UUID, prefixScope: String) {
        queue.async { [self] in
            guard !closed else { return }
            for entry in entries.values {
                guard var observation = entry.drains[token], !observation.rootExited,
                      observation.generation == entry.generation,
                      entry.identity.executionScope == prefixScope, !entry.exited else { continue }
                observation.rootExited = true; entry.drains[token] = observation
                entry.emptySince = nil; entry.calibration = UUID()
                if entry.executions.isEmpty { entry.graceUntil = clock() }
                schedule(entry)
            }
        }
    }
    func cancelDrainObservation(_ token: UUID) {
        queue.async { [self] in
            for entry in entries.values { entry.drains.removeValue(forKey: token) }
        }
    }
    private func manage(prefix: URL, engine: URL, execution: UUID?, drained: ((String) -> Void)?, completion: @escaping (String?) -> Void) {
        // Identity resolution has its own bounded slot; it never shares AppKit
        // or the state queue. Per-launch calls coalesce after identity resolves.
        queue.async { [self] in
            guard !closed else { DispatchQueue.main.async { completion(nil) }; return }
            // Resolve on the persistence worker so a slow prefix does not block
            // cancellation, menu delivery, or other environment probes.
            persistence.async {
                let identity = CyderEnvironmentProbe.identify(prefix: prefix, engine: engine)
                self.queue.async {
                    var managedPrefix: String?
                    defer { let path = managedPrefix; DispatchQueue.main.async { completion(path) } }
                    guard !self.closed, let identity else { return }
                    if self.entries[identity.environment]?.exited != false {
                        guard self.entries.count < 32 || self.entries[identity.environment] != nil else {
                            DispatchQueue.main.async { self.onIssue?("監測環境已達上限，請關閉不使用的環境後重新檢查。") }; return
                        }
                        let generation = (self.entries[identity.environment]?.generation ?? 0) + 1
                        self.install(Saved(identity: identity, generation: generation), grace: self.clock() + 30)
                    }
                    if let execution, let entry = self.entries[identity.environment] {
                        entry.executions.insert(execution)
                        entry.emptySince = nil; entry.calibration = UUID()
                        entry.graceUntil = self.clock() + 30
                        if let drained { entry.drains[execution] = .init(generation: entry.generation, completed: drained) }
                    }
                    managedPrefix = identity.prefix
                    self.save(); self.startTimer(); self.tick()
                }
            }
        }
    }
    func reconcile(_ stamp: L.Stamp) {
        queue.async { [self] in
            guard stamp.epoch == epoch, let entry = entries[stamp.environment], entry.generation == stamp.generation else { return }
            schedule(entry)
        }
    }
    func stop() {
        queue.async { [self] in
            guard !closed else { return }; closed = true
            timer?.cancel(); timer = nil
            for entry in entries.values {
                entry.pending = nil; entry.drains.removeAll()
                // Only the Process object created here with '-w' may be stopped.
                // The lock owner and the Wine client are never signalled.
                if let waiter = entry.waiter, waiter.isRunning { waiter.terminate() }
                entry.waiter = nil
            }
        }
    }
    private func emit(_ value: L.Event) { event(value) }
    private func stamp(_ entry: Entry) -> L.Stamp { .init(epoch: epoch, environment: entry.identity.environment, generation: entry.generation) }
    private func install(_ saved: Saved, grace: TimeInterval) {
        let entry = Entry(saved, grace: grace)
        entries[saved.identity.environment] = entry
        emit(.manage(.init(id: saved.identity.environment, prefix: saved.identity.prefix, engine: saved.identity.engine, generation: saved.generation)))
    }
    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source; source.resume()
    }
    private func tick() {
        guard !closed else { return }
        let active = entries.values.filter { !$0.exited }.sorted { $0.identity.prefix < $1.identity.prefix }
        guard !active.isEmpty else { return }
        for offset in 0..<active.count { schedule(active[(nextProbeIndex + offset) % active.count]) }
        nextProbeIndex = (nextProbeIndex + 1) % active.count
    }
    private func schedule(_ entry: Entry) {
        guard !closed, !entry.exited, entry.pending == nil, inFlight < 2 else { return }
        let token = UUID(), observedStamp = stamp(entry), calibration = entry.calibration
        entry.pending = token; inFlight += 1
        emit(.reconcileStarted(observedStamp, token))
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak entry] in
            guard let self, !self.closed, let entry, entry.pending == token, entry.calibration == calibration else { return }
            self.emit(.reconciled(observedStamp, token, .unconfirmed, .degraded))
            // Retain the underlying in-flight slot. A timed-out syscall does
            // not authorize a second copy of that syscall for this environment.
        }
        workers.async { [self] in
            let result = probe(entry.identity)
            queue.async {
                self.inFlight -= 1
                guard !self.closed, self.entries[entry.identity.environment] === entry,
                      entry.pending == token else { return }
                entry.pending = nil
                guard entry.calibration == calibration else { self.schedule(entry); return }
                // Timeout may have consumed this token; start a fresh revision
                // before applying a late but identity-checked calibration.
                self.emit(.reconcileStarted(observedStamp, token))
                switch result {
                case .alive(let owner):
                    entry.emptySince = nil
                    if let previous = entry.owner, previous != owner {
                        if let waiter = entry.waiter, waiter.isRunning { waiter.terminate() }
                        entry.drains.removeAll() // Old-generation launch observations cannot finish a new server.
                        entry.generation += 1; entry.waiter = nil; entry.waiterToken = nil; entry.waiterAttempted = false
                        self.emit(.manage(.init(id: entry.identity.environment, prefix: entry.identity.prefix,
                            engine: entry.identity.engine, generation: entry.generation)))
                        self.emit(.reconcileStarted(self.stamp(entry), token))
                        self.save()
                    }
                    entry.owner = owner
                    self.emit(.reconciled(self.stamp(entry), token, .alive, .healthy))
                    self.startWaiter(entry)
                case .empty:
                    let now = self.clock()
                    if entry.emptySince == nil { entry.emptySince = now }
                    if entry.executions.isEmpty, now >= entry.graceUntil, now - entry.emptySince! >= 0.5 {
                        entry.exited = true
                        self.emit(.reconciled(observedStamp, token, .exited, .healthy))
                        let callbacks = entry.drains.values.filter { $0.generation == entry.generation && $0.rootExited }.map { $0.completed }
                        entry.drains.removeAll()
                        let scope = entry.identity.executionScope
                        DispatchQueue.main.async { callbacks.forEach { $0(scope) } }
                        self.save()
                    } else { self.emit(.reconciled(observedStamp, token, .unconfirmed, .attaching)) }
                case .unknown:
                    entry.emptySince = nil
                    self.emit(.reconciled(observedStamp, token, .unconfirmed, .degraded))
                }
            }
        }
    }
    private func startWaiter(_ entry: Entry) {
        guard waitersEnabled, !entry.waiterAttempted, !closed else { return }
        entry.waiterAttempted = true
        let process = Process(), token = UUID(), observedStamp = stamp(entry)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", entry.identity.engine, "-w"]
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = entry.identity.prefix
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        entry.waiter = process; entry.waiterToken = token
        emit(.waiterStarted(observedStamp, token))
        process.terminationHandler = { [weak self, weak entry] process in
            guard let self else { return }
            self.queue.async {
                guard !self.closed, let entry, entry.waiterToken == token else { return }
                entry.waiter = nil
                self.emit(.waiterFinished(observedStamp, token, cancelled: process.terminationReason != .exit || process.terminationStatus != 0))
                self.schedule(entry)
            }
        }
        do { try process.run() }
        catch {
            entry.waiter = nil
            emit(.waiterFinished(observedStamp, token, cancelled: true))
        }
    }
    private func save() {
        guard registryWritable else { return }
        let records = entries.values.filter { !$0.exited }.map { Saved(identity: $0.identity, generation: $0.generation) }
            .sorted { $0.identity.prefix < $1.identity.prefix }
        persistence.async { [self] in
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(Registry(schema: 1, records: records))
                guard data.count <= 65536 else { throw CocoaError(.fileWriteOutOfSpace) }
                let temporary = file.deletingLastPathComponent().appendingPathComponent(".environments-\(UUID().uuidString)")
                let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                try handle.write(contentsOf: data)
                guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
                if parent >= 0 { _ = fsync(parent); Darwin.close(parent) }
            } catch { DispatchQueue.main.async { self.onIssue?("Windows 環境紀錄尚未保存；下次開啟可能需要重新檢查。") } }
        }
    }
}
