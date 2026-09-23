import Foundation

/// Main-thread presentation authority; file reads never own permission to show
/// UI. One physical reader is retained even after cancellation or replacement.
final class CyderSetupProgress {
    private struct Watch {
        let id: UUID
        let presentation: UUID
        let url: URL
        let deliver: (String) -> Void
        var last = ""
    }
    private let worker = DispatchQueue(label: "local.cyder.setup-progress", qos: .utility)
    private let read: (URL) -> String?
    private let interval: TimeInterval
    private var presentation: UUID?
    private var watch: Watch?
    private var timer: DispatchSourceTimer?
    private var reading = false

    init(interval: TimeInterval = 0.25, read: @escaping (URL) -> String? = CyderSetupProgress.readFile) {
        self.interval = interval
        self.read = read
    }

    @discardableResult
    func present() -> UUID {
        precondition(Thread.isMainThread)
        invalidate()
        let id = UUID()
        presentation = id
        return id
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        presentation = nil
        watch = nil
        timer?.cancel()
        timer = nil
        // Do not release `reading`: the underlying call may still be blocked.
    }

    func begin(presentation id: UUID, url: URL, deliver: @escaping (String) -> Void) -> UUID? {
        precondition(Thread.isMainThread)
        guard presentation == id else { return nil }
        timer?.cancel()
        let token = UUID()
        watch = Watch(id: token, presentation: id, url: url, deliver: deliver)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + min(0.2, interval), repeating: interval)
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
        return token
    }

    func end(_ token: UUID) {
        precondition(Thread.isMainThread)
        guard watch?.id == token else { return }
        watch = nil
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        precondition(Thread.isMainThread)
        guard !reading, let current = watch, current.presentation == presentation else { return }
        reading = true
        let reader = read
        worker.async { [weak self] in
            let text = reader(current.url)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.presentation == current.presentation,
                      self.watch?.id == current.id,
                      let text, !text.isEmpty, text != self.watch?.last else { return }
                self.watch?.last = text
                current.deliver(text)
            }
        }
    }

    private static func readFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Progress is a few lines, not an unbounded log. Ignore invalid/oversize
        // transport data without changing the last usable presentation.
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
