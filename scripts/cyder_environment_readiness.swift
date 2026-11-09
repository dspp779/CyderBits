import Foundation
import Darwin

/// Installation readiness, not a signature/integrity scan or a Wine health test.
/// Mirrors engineNeedsInstall and cyder_shared_prefix_is_ready / baseline checks.
/// Optional graphics backends do not determine whether Windows can be launched.
enum CyderEnvironmentReadiness: Equatable {
    case ready, notPrepared, needsUpdate, needsBootstrapUpdate, unknown

    struct Paths {
        let resources: URL
        let engine: URL
        let bottle: URL
    }

    static func read(_ paths: Paths) -> Self {
        do {
            let expected = try text(paths.resources.appendingPathComponent("engine-version.txt"))
            let expectedPin = try text(paths.resources.appendingPathComponent("engine-artifact-sha256.txt"))
            guard let expected, !expected.isEmpty, let expectedPin, validPin(expectedPin) else { return .unknown }
            guard paths.engine.path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return .unknown }
            let wine = try file(paths.engine.appendingPathComponent("bin/wine"), executable: true)
            let installed = try text(paths.engine.appendingPathComponent("version"))
            let pin = try text(paths.engine.appendingPathComponent(".cyder-engine-artifact-sha256"))
            let signed = try text(paths.engine.appendingPathComponent(".cyder-engine-signed"))
            if let installed, installed.isEmpty || installed.contains("\n") { return .unknown }
            if let pin, !validPin(pin) { return .unknown }
            if let signed, signed != "signed" { return .unknown }
            // Inspect prefix evidence before returning an engine update. A first
            // run with an older engine still needs initialization, not consent
            // to update a previously initialized Windows environment.
            let bootstrap = bootstrapRecord(paths.bottle.appendingPathComponent(".cyder-bootstrap-v1"), engineVersion: installed ?? expected)
            guard bootstrap != .unknown else { return .unknown }
            let baseline = try file(paths.bottle.appendingPathComponent(".cyder-golden-baseline-v2"))
            var registryMissing = false
            for name in ["system.reg", "user.reg"] {
                if let header = try bytes(paths.bottle.appendingPathComponent(name), limit: 64, complete: false) {
                    guard header.starts(with: Data("WINE REGISTRY Version 2".utf8)) else { return .unknown }
                } else { registryMissing = true }
            }
            let kernel64 = try file(paths.bottle.appendingPathComponent("drive_c/windows/system32/kernel32.dll"))
            let kernel32 = try file(paths.bottle.appendingPathComponent("drive_c/windows/syswow64/kernel32.dll"))
            var configurationMissing = false
            if try file(paths.engine.appendingPathComponent("share/crossover/bottle_data/cxbottle.conf")) != nil {
                configurationMissing = try file(paths.bottle.appendingPathComponent("cxbottle.conf")).map { $0.st_size == 0 } ?? true
            }
            if bootstrap == .notPrepared || baseline == nil || registryMissing ||
                (kernel64 == nil && kernel32 == nil) || configurationMissing { return .notPrepared }
            // A populated prefix never authorizes an automatic engine replacement,
            // even when a managed engine file is demonstrably absent.
            guard wine != nil, let installed, let pin, signed != nil else { return .needsUpdate }
            guard cyderEngineVersionsEqual(installed, expected), pin == expectedPin else { return .needsUpdate }
            if bootstrap == .needsBootstrapUpdate { return .needsBootstrapUpdate }
            return .ready
        } catch { return .unknown }
    }

    /// Route only a proven old stamp to the existing bootstrap-only path. It
    /// checks prefix ownership/busy state and salvages system.reg in place.
    /// IO/format uncertainty must not request a destructive rebuild.
    static func bootstrapNeedsUpdate(_ marker: URL, engineVersion: String?) -> Bool {
        guard let engineVersion, !engineVersion.isEmpty else { return false }
        return bootstrapRecord(marker, engineVersion: engineVersion) == .needsBootstrapUpdate
    }
    private static func bootstrapRecord(_ url: URL, engineVersion: String) -> Self {
        do {
            guard let marker = try text(url) else { return .notPrepared }
            let lines = marker.split(whereSeparator: \.isNewline).map(String.init)
            let revisions = lines.filter { $0.hasPrefix("revision=") }
            let engines = lines.filter { $0.hasPrefix("engine=") }
            guard revisions.count == 1, let revision = Int(revisions[0].dropFirst(9)), revision > 0,
                  engines.count <= 1 else { return .unknown }
            guard let marked = engines.first.map({ String($0.dropFirst(7)) }), !marked.isEmpty else { return .needsBootstrapUpdate }
            return cyderEngineVersionsEqual(marked, engineVersion) ? .ready : .needsBootstrapUpdate
        } catch { return .unknown }
    }

    private enum ReadError: Error { case unreadable }
    private static func validPin(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// ENOENT is evidence of absence; permission/IO errors are not.
    private static func file(_ url: URL, executable: Bool = false) throws -> stat? {
        var info = stat()
        if stat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw ReadError.unreadable
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              Darwin.access(url.path, executable ? R_OK | X_OK : R_OK) == 0 else { throw ReadError.unreadable }
        if executable && info.st_size == 0 { throw ReadError.unreadable }
        return info
    }
    private static func bytes(_ url: URL, limit: Int, complete: Bool) throws -> Data? {
        guard try file(url) != nil else { return nil }
        // A concurrently substituted FIFO must not block this read forever.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              !complete || info.st_size <= limit else { throw ReadError.unreadable }
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count >= 0, !complete || (count <= limit && count == info.st_size) else { throw ReadError.unreadable }
        return Data(buffer.prefix(count))
    }
    private static func text(_ url: URL) throws -> String? {
        guard let data = try bytes(url, limit: 16384, complete: true) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else { throw ReadError.unreadable }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Main-thread presentation with at most one physical read. Invalidation does
/// not cancel filesystem IO; a late read cannot overwrite a newer operation.
final class CyderEnvironmentReadinessObserver {
    enum State: Equatable {
        case checking, current(CyderEnvironmentReadiness), preparing(String), failed(String)
        var message: String {
            switch self {
            case .checking: return "正在確認環境狀態…"
            case .current(.ready): return "Windows 環境已準備好"
            case .current(.notPrepared): return "Windows 環境尚未準備"
            case .current(.needsUpdate): return "Windows 環境需要更新"
            case .current(.needsBootstrapUpdate): return "Windows 環境準備記錄需要更新"
            case .current(.unknown): return "暫時無法確認環境狀態"
            case .preparing(let value), .failed(let value): return value
            }
        }
        /// Library controls depend on typed state, never translated message text.
        struct InitializationPresentation: Equatable {
            let message: String?
            let showsButton: Bool
            let canInitialize: Bool
        }
        var initialization: InitializationPresentation {
            switch self {
            case .current(.ready): return .init(message: nil, showsButton: false, canInitialize: false)
            case .current: return .init(message: nil, showsButton: true, canInitialize: true)
            case .checking: return .init(message: message, showsButton: false, canInitialize: false)
            case .preparing: return .init(message: message, showsButton: true, canInitialize: false)
            case .failed: return .init(message: message, showsButton: true, canInitialize: true)
            }
        }
        var busy: Bool { if case .preparing = self { return true }; return false }
        var detail: String {
            if self == .current(.ready) {
                return "已核對目前版本與環境準備記錄；啟動時仍會進行必要檢查。可選圖形元件另行檢查。"
            }
            return message
        }
    }
    private let worker = DispatchQueue(label: "local.cyder.environment-readiness", qos: .utility)
    private let read: () -> CyderEnvironmentReadiness
    private let deadline: TimeInterval
    private var generation: UInt64 = 0
    private var active = false
    private var pending = false
    private var suspended = false
    private var closed = false
    private var failure: String?
    private(set) var state: State = .checking
    var onUpdate: ((State) -> Void)?

    init(deadline: TimeInterval = 5, read: @escaping () -> CyderEnvironmentReadiness) {
        self.deadline = deadline; self.read = read
    }
    func refresh() {
        precondition(Thread.isMainThread)
        guard !closed, !suspended else { return }
        generation &+= 1
        let request = generation
        pending = true
        publish(failure.map(State.failed) ?? .checking)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, !self.closed, !self.suspended, self.generation == request,
                  self.active || self.pending else { return }
            self.publish(self.failure.map(State.failed) ?? .current(.unknown))
        }
        startRead()
    }
    func beginOperation(clearFailure: Bool = true) {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        generation &+= 1; pending = false; suspended = true
        if clearFailure { failure = nil }
        publish(.preparing("正在準備 Windows 環境…"))
    }
    func progress(_ message: String) {
        precondition(Thread.isMainThread)
        guard !closed, suspended else { return }
        publish(.preparing(message))
    }
    func endOperation() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        suspended = false
        refresh()
    }
    func recordFailure(_ message: String) {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        generation &+= 1; pending = false; failure = message
        publish(.failed(message))
    }
    /// Only a confirmed repair may supersede an earlier preparation failure.
    /// Its success is not itself readiness: the next read must still pass.
    func repairSucceeded() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        generation &+= 1; pending = false; failure = nil
        if !suspended { refresh() }
    }
    func quiesce() {
        precondition(Thread.isMainThread)
        closed = true; generation &+= 1; pending = false; onUpdate = nil
    }
    private func publish(_ value: State) { state = value; onUpdate?(value) }
    private func startRead() {
        guard !closed, !suspended, !active, pending else { return }
        active = true; pending = false
        let request = generation
        worker.async { [self] in
            let result = read()
            DispatchQueue.main.async {
                self.active = false
                guard !self.closed else { return }
                if !self.suspended, self.generation == request {
                    self.publish(self.failure.map(State.failed) ?? .current(result))
                }
                self.startRead()
            }
        }
    }
}

/// One automatic attempt per app session. Manual retry and late completion are
/// separate decisions, so refreshing failed readiness can never form a loop.
final class CyderEnvironmentPreparationAdmission {
    struct Entry {
        let primary: Bool
        let readOnly: Bool
        let visible: Bool
        let normalAppEntry: Bool
        let recoveryCompleted: Bool
        let pendingLaunches: Bool
        let operationBusy: Bool
        var permitsAutomatic: Bool {
            primary && !readOnly && visible && normalAppEntry && recoveryCompleted && !pendingLaunches && !operationBusy
        }
    }
    private(set) var automaticAttempted = false
    private(set) var operation: UUID?
    func begin(automatic: Bool, readiness: CyderEnvironmentReadinessObserver.State,
               eligibleForAutomatic: Bool) -> UUID? {
        precondition(Thread.isMainThread)
        guard operation == nil else { return nil }
        if automatic {
            guard !automaticAttempted, eligibleForAutomatic, readiness == .current(.notPrepared) else { return nil }
            automaticAttempted = true
        }
        let id = UUID(); operation = id; return id
    }
    @discardableResult func finish(_ id: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard operation == id else { return false }
        operation = nil; return true
    }
}

/// Keep a multi-step preparation's single operation lease until both its owner
/// and every real executor have finished. An unconfirmed return is not release.
final class CyderEnvironmentPreparationOwnership {
    private let lock = NSLock()
    private var executors = 0
    private var finished = false
    private var release: (() -> Void)?
    init(release: @escaping () -> Void) { self.release = release }
    func executorStarted() { lock.lock(); executors += 1; lock.unlock() }
    func executorReleased() {
        lock.lock(); precondition(executors > 0); executors -= 1
        let action = takeRelease(); lock.unlock(); action?()
    }
    func finish() {
        lock.lock(); finished = true
        let action = takeRelease(); lock.unlock(); action?()
    }
    private func takeRelease() -> (() -> Void)? {
        guard finished, executors == 0 else { return nil }
        let action = release; release = nil; return action
    }
}
