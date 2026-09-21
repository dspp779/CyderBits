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
    private struct Admission {
        let drained: ((String) -> Void)?
        let completion: (String?) -> Void
    }
    private final class Entry {
        let identity: CyderEnvironmentProbe.Identity
        var generation: UInt64
        var owner: L.ProcessID?
        var pending: UUID?
        var lastProbeStarted: TimeInterval = -.infinity
        var waiter: Process?
        var waiterStarting = false
        var waiterToken: UUID?
        var waiterAttempted = false
        var emptySince: TimeInterval?
        var graceUntil: TimeInterval
        var exited = false
        var retiredAt: TimeInterval?
        var executions: Set<UUID> = []
        var admissions: Set<UUID> = [] // registered, but not yet allowed to spawn
        var drains: [UUID: DrainObservation] = [:]
        var calibration = UUID()
        init(_ saved: Saved, grace: TimeInterval) {
            identity = saved.identity; generation = saved.generation; graceUntil = grace
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.environment-monitor")
    private let workers = DispatchQueue(label: "local.cyder.environment-probe", qos: .utility, attributes: .concurrent)
    private let persistence = DispatchQueue(label: "local.cyder.environment-history", qos: .utility)
    private let identityWorkers: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2
        queue.name = "local.cyder.environment-identity"; return queue
    }()
    private var identityJobs = 0
    private let epoch: UUID
    private let file: URL
    private let event: (L.Event) -> Void
    private let probe: (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result
    private let identify: (URL, URL) -> CyderEnvironmentProbe.Identity?
    private let clock: () -> TimeInterval
    private let waitersEnabled: Bool
    private let expectedEngine: String?
    private let launchWaiter: (Process) throws -> Void
    private var waiterSpawns = 0
    private var admissions: [UUID: Admission] = [:]
    private var entries: [L.EnvironmentID: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var inFlight = 0
    private var registryWritable = true
    private var registryReading = false
    private var registryLoaded = false
    private var registryJobs: [(id: UUID, work: () -> Void, expired: () -> Void)] = []
    private let readRegistry: (URL) throws -> Data?
    private var canonicalExpectedEngine: String?
    private var nextProbeIndex = 0
    var onIssue: ((String) -> Void)?

    init(epoch: UUID, directory: URL, expectedEngine: URL? = nil, waitersEnabled: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         identify: @escaping (URL, URL) -> CyderEnvironmentProbe.Identity? = { CyderEnvironmentProbe.identify(prefix: $0, engine: $1) },
         probe: @escaping (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result = { CyderEnvironmentProbe.inspect($0) },
         launchWaiter: @escaping (Process) throws -> Void = { try $0.run() },
         readRegistry: @escaping (URL) throws -> Data? = { try CyderEnvironmentMonitor.readRegistryFile($0) },
         event: @escaping (L.Event) -> Void) {
        self.epoch = epoch; self.file = directory.appendingPathComponent("managed-environments-v1.json")
        self.expectedEngine = expectedEngine?.path
        self.waitersEnabled = waitersEnabled; self.clock = clock; self.probe = probe; self.event = event
        self.launchWaiter = launchWaiter
        self.identify = identify
        self.readRegistry = readRegistry
    }
    static func readRegistryFile(_ file: URL) throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 65536, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65537) ?? Data()
    }
    func restore(completion: @escaping () -> Void) {
        queue.async { [self] in
            let finish = { DispatchQueue.main.async(execute: completion) }
            afterRegistry(expired: finish, work: finish)
        }
    }
    /// All mutations share the first registry read. Timeout removes the caller,
    /// never the physical reader; no late launch is resurrected after expiry.
    private func afterRegistry(expired: @escaping () -> Void, work: @escaping () -> Void) {
        guard !closed else { expired(); return }
        if registryLoaded { work(); return }
        guard registryJobs.count < 32 else { expired(); return }
        let id = UUID()
        registryJobs.append((id, work, expired))
        queue.asyncAfter(deadline: .now() + 5) { [self] in
            guard let index = registryJobs.firstIndex(where: { $0.id == id }) else { return }
            registryJobs.remove(at: index).expired()
        }
        guard !registryReading else { return }
        registryReading = true
        persistence.async { [self] in
            var records: [Saved] = []
            let expected = expectedEngine.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            var valid = true
            do {
                if let data = try readRegistry(file) {
                    guard data.count <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
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
                }
            } catch { valid = false; records.removeAll() }
            queue.async {
                self.canonicalExpectedEngine = expected
                self.registryReading = false; self.registryLoaded = true
                self.registryWritable = valid
                guard !self.closed else { return }
                // No entry can be installed until this single read finishes.
                // Loading the bounded history first reserves its capacity and
                // prevents a new write from erasing external-prefix recovery.
                for record in records {
                    self.install(Saved(identity: record.identity, generation: record.generation + 1), grace: 0)
                }
                if !valid { DispatchQueue.main.async { self.onIssue?("無法讀取先前的 Windows 環境紀錄；可從遊戲庫重新檢查。") } }
                self.save(); self.startTimer(); self.tick()
                let jobs = self.registryJobs; self.registryJobs.removeAll()
                jobs.forEach { $0.work() }
            }
        }
    }
    /// Orders the caller's final recovery state after all already submitted
    /// verified environments; the UI never waits for this queue synchronously.
    func finishRecovery(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }
    /// Only the read-only bottle recovery adapter supplies this fresh server
    /// proof. It cannot overwrite an execution or newer observation installed
    /// while the directory inventory was in flight.
    func recoverVerified(_ identity: CyderEnvironmentProbe.Identity, owner: L.ProcessID, observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        queue.async { [self] in
            afterRegistry(expired: {}, work: { [self] in
                let previous = entries[identity.environment]
                guard !closed, previous == nil || previous?.exited == true,
                      previous == nil || (previous?.owner != owner && observedAt > (previous?.retiredAt ?? .infinity)),
                      observedAt.isFinite, observedAt <= clock(),
                      previous == nil || previous!.generation < UInt64.max,
                      hasActiveCapacity,
                      identity.environment.uid == getuid(), identity.environment.namespace == "wine-user",
                      owner.pid > 0, owner.started > 0, !owner.boot.isEmpty,
                      expectedEngine == nil || canonicalExpectedEngine == identity.engine else { return }
                install(.init(identity: identity, generation: (previous?.generation ?? 0) + 1), grace: 0)
                guard let entry = entries[identity.environment] else { return }
                entry.owner = owner
                let token = UUID()
                emit(.reconcileStarted(stamp(entry), token))
                emit(.reconciled(stamp(entry), token, .alive, .healthy))
                save(); startTimer(); startWaiter(entry)
            })
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
                finishAdmission(token, prefix: nil)
                entry.emptySince = nil; entry.calibration = UUID()
                entry.graceUntil = entry.drains.values.contains { $0.generation == entry.generation && $0.rootExited }
                    ? clock() : clock() + 30
                schedule(entry)
            }
        }
    }
    /// Captured from the same writer that registered this live executor. A
    /// pathname or the UI's last delivered snapshot cannot supply this stamp.
    func executionStamp(_ token: UUID) async -> L.Stamp? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed, admissions[token] == nil,
                      let entry = entries.values.first(where: { $0.executions.contains(token) && !$0.exited }) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: stamp(entry))
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
            guard identityJobs < 32 else { DispatchQueue.main.async { completion(nil) }; return }
            if let execution {
                guard admissions.count < 32 else { DispatchQueue.main.async { completion(nil) }; return }
                admissions[execution] = Admission(drained: drained, completion: completion)
                // Includes identity resolution and slot contention. A timed-out
                // caller never receives an executor token later.
                queue.asyncAfter(deadline: .now() + 5) { self.finishAdmission(execution, prefix: nil) }
            }
            afterRegistry(expired: { [self] in
                if let execution { finishAdmission(execution, prefix: nil) }
                else { DispatchQueue.main.async { completion(nil) } }
            }, work: { [self] in
                guard identityJobs < 32 else {
                    if let execution { finishAdmission(execution, prefix: nil) }
                    else { DispatchQueue.main.async { completion(nil) } }
                    return
                }
                // Keep physical identity slots until the work returns, even after
                // caller timeout. Two workers prevent one slow prefix from holding
                // unrelated admissions or persistence behind it.
                identityJobs += 1
                identityWorkers.addOperation {
                    let needed = self.queue.sync { !self.closed && (execution == nil || self.admissions[execution!] != nil) }
                    let identity = needed ? self.identify(prefix, engine) : nil
                    self.queue.async {
                        self.identityJobs -= 1
                        var managedPrefix: String?
                        var awaitingProbe = false
                        defer {
                            if let execution {
                                if !awaitingProbe { self.finishAdmission(execution, prefix: nil) }
                            } else { let path = managedPrefix; DispatchQueue.main.async { completion(path) } }
                        }
                        if let execution, self.admissions[execution] == nil { return }
                        guard !self.closed, let identity else { return }
                        if self.entries[identity.environment]?.exited != false {
                            guard self.hasActiveCapacity else {
                                DispatchQueue.main.async { self.onIssue?("監測環境已達上限，請關閉不使用的環境後重新檢查。") }; return
                            }
                            guard (self.entries[identity.environment]?.generation ?? 0) < UInt64.max else { return }
                            let generation = (self.entries[identity.environment]?.generation ?? 0) + 1
                            self.install(Saved(identity: identity, generation: generation), grace: self.clock() + 30)
                        }
                        if let execution, let entry = self.entries[identity.environment] {
                            entry.executions.insert(execution)
                            entry.admissions.insert(execution)
                            awaitingProbe = true
                            entry.emptySince = nil; entry.calibration = UUID()
                            entry.graceUntil = self.clock() + 30
                            self.schedule(entry)
                        }
                        managedPrefix = identity.prefix
                        self.save(); self.startTimer(); self.tick()
                    }
                }
            })
        }
    }
    private func finishAdmission(_ token: UUID, prefix: String?) {
        guard let admission = admissions.removeValue(forKey: token) else { return }
        for entry in entries.values where entry.admissions.remove(token) != nil {
            if let prefix, prefix == entry.identity.prefix {
                if let drained = admission.drained {
                    entry.drains[token] = .init(generation: entry.generation, completed: drained)
                }
            } else {
                entry.executions.remove(token)
                entry.emptySince = nil; entry.calibration = UUID()
            }
        }
        DispatchQueue.main.async { admission.completion(prefix) }
    }
    private func admit(_ entry: Entry) {
        for token in Array(entry.admissions) { finishAdmission(token, prefix: entry.identity.prefix) }
    }
    private func advanceGeneration(_ entry: Entry, reconciliation: UUID) {
        if !entry.waiterStarting, let waiter = entry.waiter, waiter.isRunning { waiter.terminate() }
        entry.drains.removeAll()
        entry.generation += 1; entry.owner = nil
        entry.waiter = nil; entry.waiterStarting = false; entry.waiterToken = nil; entry.waiterAttempted = false
        emit(.manage(.init(id: entry.identity.environment, prefix: entry.identity.prefix,
            engine: entry.identity.engine, generation: entry.generation)))
        emit(.reconcileStarted(stamp(entry), reconciliation))
        save()
    }
    func recheck() { queue.async { [self] in tick() } }
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
            let jobs = registryJobs; registryJobs.removeAll()
            jobs.forEach { $0.expired() }
            for token in Array(admissions.keys) { finishAdmission(token, prefix: nil) }
            for entry in entries.values {
                entry.pending = nil; entry.drains.removeAll()
                // Only the Process object created here with '-w' may be stopped.
                // The lock owner and the Wine client are never signalled.
                if !entry.waiterStarting, let waiter = entry.waiter, waiter.isRunning { waiter.terminate() }
                entry.waiter = nil; entry.waiterStarting = false
            }
        }
    }
    private func emit(_ value: L.Event) { event(value) }
    private func stamp(_ entry: Entry) -> L.Stamp { .init(epoch: epoch, environment: entry.identity.environment, generation: entry.generation) }
    // Retired entries retain their generation fence, but own no active slot.
    // Reactivating one consumes the same capacity as a previously unseen prefix.
    private var hasActiveCapacity: Bool { entries.values.lazy.filter { !$0.exited }.prefix(32).count < 32 }
    private func install(_ saved: Saved, grace: TimeInterval) {
        if let previous = entries[saved.identity.environment] {
            if !previous.waiterStarting, let waiter = previous.waiter, waiter.isRunning { waiter.terminate() }
            previous.waiter = nil; previous.waiterToken = nil
        }
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
    private func scheduleAdmissions() {
        guard !closed, inFlight < 2 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A completed physical slot serves an awaiting executor before routine
        // polling. Unknown/empty results still respect a bounded retry cadence.
        let waiting = entries.values.filter {
            !$0.exited && !$0.admissions.isEmpty && $0.pending == nil && now - $0.lastProbeStarted >= 0.5
        }.sorted { $0.lastProbeStarted == $1.lastProbeStarted
            ? $0.identity.prefix < $1.identity.prefix : $0.lastProbeStarted < $1.lastProbeStarted }
        for entry in waiting { schedule(entry) }
    }
    private func tick() {
        guard !closed else { return }
        scheduleAdmissions()
        let active = entries.values.filter { !$0.exited && $0.admissions.isEmpty }.sorted { $0.identity.prefix < $1.identity.prefix }
        guard !active.isEmpty else { return }
        for offset in 0..<active.count { schedule(active[(nextProbeIndex + offset) % active.count]) }
        nextProbeIndex = (nextProbeIndex + 1) % active.count
    }
    private func schedule(_ entry: Entry) {
        guard !closed, !entry.exited, entry.pending == nil, inFlight < 2 else { return }
        let token = UUID(), observedStamp = stamp(entry), calibration = entry.calibration
        entry.pending = token; inFlight += 1
        entry.lastProbeStarted = ProcessInfo.processInfo.systemUptime
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
                defer { self.scheduleAdmissions() }
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
                        self.advanceGeneration(entry, reconciliation: token)
                    }
                    entry.owner = owner
                    self.emit(.reconciled(self.stamp(entry), token, .alive, .healthy))
                    self.admit(entry)
                    self.startWaiter(entry)
                case .empty:
                    let now = self.clock()
                    if entry.emptySince == nil { entry.emptySince = now }
                    if !entry.admissions.isEmpty {
                        if entry.owner == nil { self.admit(entry) }
                        else if now - entry.emptySince! >= 0.5 {
                            // Retire the old server before returning a new
                            // executor token. Its first server discovery then
                            // belongs to this prepared generation.
                            self.advanceGeneration(entry, reconciliation: token)
                            self.admit(entry)
                        }
                    }
                    if entry.executions.isEmpty, now >= entry.graceUntil, now - entry.emptySince! >= 0.5 {
                        entry.exited = true; entry.retiredAt = now
                        self.emit(.reconciled(self.stamp(entry), token, .exited, .healthy))
                        let callbacks = entry.drains.values.filter { $0.generation == entry.generation && $0.rootExited }.map { $0.completed }
                        entry.drains.removeAll()
                        let scope = entry.identity.executionScope
                        DispatchQueue.main.async { callbacks.forEach { $0(scope) } }
                        self.save()
                    } else { self.emit(.reconciled(self.stamp(entry), token, .unconfirmed, .attaching)) }
                case .unknown:
                    entry.emptySince = nil
                    self.emit(.reconciled(observedStamp, token, .unconfirmed, .degraded))
                }
            }
        }
    }
    private func startWaiter(_ entry: Entry) {
        guard waitersEnabled, !entry.waiterAttempted, !closed, waiterSpawns < 2 else { return }
        entry.waiterAttempted = true
        let process = Process(), token = UUID(), observedStamp = stamp(entry)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", entry.identity.engine, "-w"]
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = entry.identity.prefix
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        entry.waiter = process; entry.waiterStarting = true; entry.waiterToken = token
        emit(.waiterStarted(observedStamp, token))
        process.terminationHandler = { [weak self, weak entry] process in
            guard let self else { return }
            let cancelled = process.terminationReason != .exit || process.terminationStatus != 0
            self.queue.async {
                guard !self.closed, let entry, self.entries[entry.identity.environment] === entry,
                      entry.waiterToken == token else { return }
                entry.waiter = nil
                self.emit(.waiterFinished(observedStamp, token, cancelled: cancelled))
                self.schedule(entry)
            }
        }
        waiterSpawns += 1
        workers.async { [self] in
            let current = queue.sync { !closed && entries[entry.identity.environment] === entry && !entry.exited
                && entry.waiter === process && entry.waiterToken == token }
            var failed = !current
            if current {
                do { try launchWaiter(process) } catch { failed = true }
            }
            let didFail = failed
            queue.async {
                self.waiterSpawns -= 1
                if entry.waiterToken == token { entry.waiterStarting = false }
                guard !self.closed, self.entries[entry.identity.environment] === entry, !entry.exited,
                      entry.waiter === process, entry.waiterToken == token else {
                    // A late spawn belongs to Cyder's own '-w' helper only.
                    if process.isRunning { process.terminate() }
                    return
                }
                if didFail {
                    entry.waiter = nil
                    self.emit(.waiterFinished(observedStamp, token, cancelled: true))
                }
            }
        }
    }
    private func save() {
        guard registryLoaded, registryWritable, !registryReading else { return }
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
