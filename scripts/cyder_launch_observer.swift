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

/// Bounded legacy-sidecar adapter for the formal launch path. Completion is
/// serialized independently from file reads so even a stuck filesystem cannot
/// extend the original launch observation deadline or accumulate read workers.
final class CyderLaunchObserver {
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

    func wait(until deadline: TimeInterval, signal: WineActivationWaiter,
              read: @escaping () -> Sample) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finished else { continuation.resume(returning: .unconfirmed); return }
                completion = { continuation.resume(returning: $0) }
                self.signal = signal
                signal.observe { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.finish(.activated) }
                }
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                queue.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.finish(.unconfirmed) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 0.25)
                timer.setEventHandler { [weak self] in self?.sample(read) }
                self.timer = timer; timer.resume()
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
        callback?(result)
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
