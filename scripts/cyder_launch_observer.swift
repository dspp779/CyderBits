import Foundation
import Darwin

final class WineActivationWaiter {
    let prefix: String
    private let lock = NSLock()
    private var activated = false
    private var handler: (() -> Void)?
    init(prefix: String) { self.prefix = (prefix as NSString).standardizingPath }
    func signal() {
        lock.lock(); activated = true; let callback = handler; lock.unlock()
        callback?()
    }
    func observe(_ callback: (() -> Void)?) {
        lock.lock(); handler = callback; let ready = activated; lock.unlock()
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
        let phase: String
        let pid: Int32
        let boot: String
        let started: UInt64
        let status: Int32?
        let signalled: Bool?
    }
    struct Sample { let rootStatus: Int32?; let lifecycle: String? }
    enum Result: Equatable { case activated, finishedWithoutWindow, rootFailed(Int32), unconfirmed }
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

    init(authority: Authority? = nil) { self.authority = authority }

    func receive(_ root: NativeRoot) {
        guard authority == root.authority else { return }
        queue.async { [self] in
            guard !finished, authority == root.authority, root.pid > 0, root.started > 0, !root.boot.isEmpty,
                  ["spawned", "exited"].contains(root.phase) else { return }
            if root.phase == "exited" {
                guard let status = root.status, (0...255).contains(status), let signalled = root.signalled,
                      !signalled || (1...127).contains(status) else { return }
            }
            if let previous = nativeRoot {
                guard previous.ticket == root.ticket, previous.pid == root.pid, previous.boot == root.boot,
                      previous.started == root.started, previous.phase != "exited" || previous == root else { return }
            }
            nativeRoot = root
            evaluateNativeRoot()
        }
    }

    private func evaluateNativeRoot() {
        guard completion != nil, let root = nativeRoot, root.phase == "exited", let status = root.status else { return }
        if root.signalled == true { finish(.rootFailed(128 + status)) }
        else if status != 0 { finish(.rootFailed(status)) }
        // Clean root exit is not proof that a successor or its environment
        // ended. Keep the original deadline while activation may still arrive.
    }

    func wait(until deadline: TimeInterval, signal: WineActivationWaiter,
              read: (() -> Sample)? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finished else { continuation.resume(returning: .unconfirmed); return }
                completion = { continuation.resume(returning: $0) }
                observationDeadline = deadline
                self.signal = signal
                signal.observe { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.finish(.activated) }
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
                if let status = sample.rootStatus, status != 0 { self.finish(.rootFailed(status)) }
                else if sample.rootStatus == 0 && sample.lifecycle == "stopped" { self.finish(.finishedWithoutWindow) }
            }
        }
    }
    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        signal?.observe(nil); signal = nil
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
