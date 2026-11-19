import Foundation
import Darwin

final class WineActivationWaiter {
    let prefix: String
    let launchID: String?
    private let lock = NSLock()
    private var activated = false
    private var presented = false
    private var presentedPIDs: Set<Int32> = []
    private var frontmostPID: Int32 = 0
    private var handler: (() -> Void)?
    private var presentedHandler: (() -> Void)?
    init(prefix: String, launchID: String? = nil) { self.prefix = (prefix as NSString).standardizingPath; self.launchID = launchID }
    func signal() {
        lock.lock(); activated = true; let callback = handler; lock.unlock()
        callback?()
    }
    /// A window of this launch is on screen, though it may never become the
    /// active app (a launch from the background cannot take focus).
    /// `process` is the program whose window is on screen, when known.
    func markPresented(process: Int32 = 0) {
        lock.lock()
        let first = !presented; presented = true
        if process > 0 { presentedPIDs.insert(process) }
        let nowActive = process > 0 && process == frontmostPID
        let callback = presentedHandler; lock.unlock()
        if nowActive { signal() }
        if first { callback?() }
    }
    /// The frontmost app changed to `pid`. Wine asks Cyder to yield before
    /// its window is on screen, so activation and presentation arrive in
    /// either order; the launch is activated once one process has both.
    func noteFrontmost(_ pid: Int32) {
        lock.lock(); frontmostPID = pid; let match = pid > 0 && presentedPIDs.contains(pid); lock.unlock()
        if match { signal() }
    }
    var wasPresented: Bool { lock.lock(); defer { lock.unlock() }; return presented }
    func observe(_ callback: (() -> Void)?) {
        lock.lock(); handler = callback; let ready = activated; lock.unlock()
        if ready { callback?() }
    }
    func observePresented(_ callback: (() -> Void)?) {
        lock.lock(); presentedHandler = callback; let ready = presented; lock.unlock()
        if ready { callback?() }
    }
}

/// Native receipts and optional legacy readers share a fixed observation
/// deadline. Neither log drainage nor a stuck filesystem extends that deadline.
final class CyderLaunchObserver {
    struct Authority: Equatable {
        let request: String
        let launch: String
        let digest: String
        let epoch: UUID
    }
    struct NativeRoot: Equatable {
        let authority: Authority
        let ticket: UUID
        let phase: CyderSpawnPhase
        let pid: Int32
        let boot: String
        let started: UInt64
        let status: Int32?
        let signalled: Bool?
        var prefixScope: String? = nil
    }
    struct Sample { let rootStatus: Int32?; let lifecycle: String? }
    /// `exitedAfterWindow`: the root exited non-zero after one of its windows
    /// was on screen, so the user saw the program (an installer returns 1 on
    /// Cancel). It is not a launch that failed before showing a window.
    /// `presented`: a window was on screen for `presentationGrace` without the
    /// program becoming active (opened from the background, or the user moved
    /// on). The launch has visibly started; holding the observation for the
    /// full deadline only kept the next queued launch waiting (up to 30 s).
    enum Result: Equatable { case activated, presented, finishedWithoutWindow, rootFailed(Int32), exitedAfterWindow(Int32), unconfirmed }
    static let presentationGrace: TimeInterval = 1
    private final class ReadPool {
        let lock = NSLock()
        var count = 0
        func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard count < 2 else { return false }; count += 1; return true }
        func release() { lock.lock(); count -= 1; lock.unlock() }
    }
    private static let pool = ReadPool()
    private let queue = DispatchQueue(label: "local.cyder.launch-observation")
    private let worker = DispatchQueue.global(qos: .utility)
    private var timer: DispatchSourceTimer?
    private var completion: ((Result) -> Void)?
    private var signal: WineActivationWaiter?
    private var finished = false
    private var reading = false
    private let authority: Authority?
    private var nativeRoot: NativeRoot?
    private var observationDeadline: TimeInterval?
    private var drainRequest: ((String) -> Void)?
    private var drainRequested = false
    private var environmentEnded = false
    /// A launcher may start the real program and exit non-zero before that
    /// program's window appears. A root failure is reported only after
    /// `successorSettle` and only while no other user program of the launch
    /// is alive; otherwise the observation continues (window, activation, the
    /// successors ending, or the deadline decides).
    private let successorSettle: TimeInterval
    private var successorsAlive = false
    private var rootFailure: Int32?
    private var rootFailureSettled = false

    init(authority: Authority? = nil, successorSettle: TimeInterval = 2) {
        self.authority = authority
        self.successorSettle = successorSettle
    }

    /// Whether a user program of this launch other than the root is alive
    /// (from the lifecycle snapshot; Wine helpers such as conhost do not count).
    func noteSuccessors(alive: Bool) {
        queue.async { [self] in
            successorsAlive = alive
            settleRootFailure()
        }
    }
    private func failRoot(_ status: Int32) {
        guard !finished, rootFailure == nil else { return }
        rootFailure = status
        queue.asyncAfter(deadline: .now() + successorSettle) { [weak self] in
            guard let self else { return }
            self.rootFailureSettled = true
            self.settleRootFailure()
        }
    }
    private func settleRootFailure() {
        guard !finished, rootFailureSettled, let status = rootFailure, !successorsAlive else { return }
        finish(.rootFailed(status))
    }

    func receive(_ root: NativeRoot) {
        guard authority == root.authority else { return }
        queue.async { [self] in
            guard !finished, authority == root.authority, root.pid > 0, root.started > 0, !root.boot.isEmpty,
                  root.phase.hasProcess else { return }
            if root.phase == .exited {
                guard let status = root.status, (0...255).contains(status), let signalled = root.signalled,
                      !signalled || (1...127).contains(status) else { return }
            }
            if let previous = nativeRoot {
                var comparable = previous
                if comparable.prefixScope == nil { comparable.prefixScope = root.prefixScope }
                guard previous.ticket == root.ticket, previous.pid == root.pid, previous.boot == root.boot,
                      previous.started == root.started,
                      previous.prefixScope == nil || previous.prefixScope == root.prefixScope, previous.phase != .exited || comparable == root else { return }
            }
            nativeRoot = root
            evaluateNativeRoot()
        }
    }

    /// The monitor binds this request to the exact execution registration; a
    /// prefix path or a waiter returning zero cannot call the completion path.
    func observeDrain(using request: @escaping (String) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            drainRequest = request
            evaluateNativeRoot()
        }
    }
    func receiveEnvironmentEnded(prefixScope: String) {
        queue.async { [self] in
            guard !finished, nativeRoot?.prefixScope == prefixScope,
                  nativeRoot?.phase == .exited, nativeRoot?.status == 0,
                  nativeRoot?.signalled == false, drainRequested else { return }
            environmentEnded = true
            evaluateNativeRoot()
        }
    }
    private func evaluateNativeRoot() {
        guard !finished, let root = nativeRoot, root.phase == .exited, let status = root.status else { return }
        if status == 0, root.signalled == false, let scope = root.prefixScope,
           let request = drainRequest, !drainRequested {
            drainRequested = true
            request(scope)
        }
        guard completion != nil else { return }
        if root.signalled == true { failRoot(128 + status) }
        else if status != 0 { failRoot(status) }
        else if environmentEnded { finish(.finishedWithoutWindow) }
        // Root zero alone keeps the original deadline for a late successor.
    }

    /// Start this budget only when preparation/handoff has completed. Queue
    /// time and native preparation have their own observation owner and budget.
    func wait(duration: TimeInterval, signal: WineActivationWaiter,
              onStarted: @escaping (TimeInterval) -> Void = { _ in }) async -> Result {
        await wait(signal: signal, read: nil, deadline: { ProcessInfo.processInfo.systemUptime + max(0, duration) }, onStarted: onStarted)
    }
    func wait(until deadline: TimeInterval, signal: WineActivationWaiter,
              read: (() -> Sample)? = nil) async -> Result {
        await wait(signal: signal, read: read, deadline: { deadline })
    }
    private func wait(signal: WineActivationWaiter, read: (() -> Sample)?, deadline: @escaping () -> TimeInterval,
                      onStarted: @escaping (TimeInterval) -> Void = { _ in }) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finished, completion == nil else { continuation.resume(returning: .unconfirmed); return }
                let deadline = deadline()
                completion = { continuation.resume(returning: $0) }
                observationDeadline = deadline
                onStarted(deadline)
                self.signal = signal
                signal.observe { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.finish(.activated) }
                }
                // Activation usually follows the first window; let it win.
                signal.observePresented { [weak self] in
                    guard let self else { return }
                    self.queue.asyncAfter(deadline: .now() + Self.presentationGrace) { self.finish(.presented) }
                }
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                queue.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.finish(.unconfirmed) }
                if let read, authority == nil {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: 0.25)
                    timer.setEventHandler { [weak self] in self?.sample(read) }
                    self.timer = timer; timer.resume()
                }
                // An activation already observed before wait takes precedence.
                queue.async { self.evaluateNativeRoot() }
            }
        }
    }
    func cancel() { queue.async { [self] in finish(.unconfirmed) } }
    private func sample(_ read: @escaping () -> Sample) {
        guard !finished, !reading, Self.pool.acquire() else { return }
        reading = true
        worker.async { [self] in
            let sample = read()
            Self.pool.release()
            queue.async {
                self.reading = false
                guard !self.finished else { return }
                if let status = sample.rootStatus, status != 0 { self.failRoot(status) }
                else if sample.rootStatus == 0 && sample.lifecycle == "stopped" { self.finish(.finishedWithoutWindow) }
            }
        }
    }
    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        var result = result
        if case .rootFailed(let status) = result, signal?.wasPresented == true { result = .exitedAfterWindow(status) }
        timer?.cancel(); timer = nil
        drainRequest = nil
        signal?.observe(nil); signal?.observePresented(nil); signal = nil
        let callback = completion; completion = nil
        let expired = observationDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
        callback?(expired ? .unconfirmed : result)
    }
    static func readSidecar(_ url: URL) -> [String: String] {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [:] }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 2048,
              info.st_uid == getuid() else { return [:] }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 2049),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields["schema"] == "1" ? fields : [:]
    }
}
