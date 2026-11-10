import Foundation
import Darwin

/// Event-driven trigger for re-reading native executor tickets.
///
/// Every ticket transition is an atomic rename inside the owner directory, so a
/// kqueue vnode event on that directory covers all helper writes. A helper that
/// dies without writing is covered by a kqueue process-exit event on each
/// recorded owner/bridge/native PID. Events are only triggers: the reader still
/// verifies process births and ticket contents, so PID reuse cannot forge a
/// result. A slow fallback timer exists only for filesystems that do not deliver
/// vnode events (e.g. some network volumes); it is not the normal path.
final class CyderExecutionWatch {
    private let directory: URL
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let fallback: TimeInterval
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSources: [Int32: DispatchSourceProcess] = [:]
    private var fallbackTimer: DispatchSourceTimer?
    private var pending = false
    private var stopped = false
    var onChange: (() -> Void)?

    init(directory: URL, queue: DispatchQueue = .main, debounce: DispatchTimeInterval = .milliseconds(50),
         fallback: TimeInterval = 60) {
        self.directory = directory; self.queue = queue; self.debounce = debounce; self.fallback = fallback
    }

    /// Call on `queue` after every ticket read. `pids` are the live processes the
    /// unresolved tickets depend on; `unresolved` keeps the fallback armed.
    func update(unresolved: Bool, pids: Set<Int32>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        if directorySource == nil { openDirectory() }
        for (pid, source) in processSources where !pids.contains(pid) {
            source.cancel(); processSources[pid] = nil
        }
        for pid in pids where pid > 0 && processSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                self?.processSources[pid]?.cancel(); self?.processSources[pid] = nil
                self?.trigger()
            }
            processSources[pid] = source
            source.resume()
            // The process may already be gone; kqueue cannot report a past exit.
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { trigger() }
        }
        if unresolved, fallbackTimer == nil, fallback > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + fallback, repeating: fallback, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.trigger() }
            fallbackTimer = timer; timer.resume()
        } else if !unresolved {
            fallbackTimer?.cancel(); fallbackTimer = nil
        }
    }

    /// Coalesces bursts (a ticket write plus its process exit) into one read.
    func trigger() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending = false
            self.onChange?()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        directorySource?.cancel(); directorySource = nil
        processSources.values.forEach { $0.cancel() }; processSources.removeAll()
        fallbackTimer?.cancel(); fallbackTimer = nil
    }

    var watchedProcesses: Set<Int32> { Set(processSources.keys) }
    var isWatchingDirectory: Bool { directorySource != nil }
    var hasFallback: Bool { fallbackTimer != nil }

    private func openDirectory() {
        let fd = Darwin.open(directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return } // created lazily by the first ticket; retried on next update
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) || source.data.contains(.revoke) {
                // The directory itself moved away; reopen on the next update.
                source.cancel(); self.directorySource = nil
            }
            self.trigger()
        }
        source.setCancelHandler { Darwin.close(fd) }
        directorySource = source
        source.resume()
    }
}
