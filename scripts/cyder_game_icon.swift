import AppKit
import Foundation
import Darwin
import ImageIO

/// Main-thread memory projection with bounded background PE/cache reads.
/// Browsing a tile never opens a file or launches a Wine client on AppKit.
final class CyderGameIconStore {
    static let shared = CyderGameIconStore()
    typealias Read = (CyderGameRecord) -> CGImage?
    private let preparation = CyderLaunchPreparation<CGImage?>()
    private let read: Read
    private let deadline: TimeInterval
    private var memory: [String: NSImage] = [:]
    private var memoryOrder: [String] = []
    private var checked: Set<String> = []
    private var paths: [String: String] = [:]
    private var pendingCompletions: [String: [() -> Void]] = [:]
    private var closed = false

    init(deadline: TimeInterval = 5, read: Read? = nil) {
        self.deadline = deadline
        self.read = read ?? Self.readIcon
    }

    func image(for game: CyderGameRecord) -> NSImage {
        precondition(Thread.isMainThread)
        if let cached = logo(for: game) { return cached }
        ensureExtracted(game)
        let image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// A snapshot only. Freshness checks happen during background refresh.
    func logo(for game: CyderGameRecord) -> NSImage? {
        precondition(Thread.isMainThread)
        guard paths[game.id] == game.executablePath else { return nil }
        return memory[game.id]
    }

    func extractSelectedGame(_ game: CyderGameRecord, completion: @escaping () -> Void) {
        ensureExtracted(game, force: true, completion: completion)
    }

    func ensureExtracted(_ game: CyderGameRecord, force: Bool = false, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard !closed else { completion?(); return }
        if var callbacks = pendingCompletions[game.id] {
            if let completion {
                // Callers use completion to redraw, not as proof of extraction.
                // Keep even repeated UI refreshes bounded while a read is stuck.
                if callbacks.count < 16 { callbacks.append(completion); pendingCompletions[game.id] = callbacks }
                else { completion() }
            }
            return
        }
        let samePath = paths[game.id] == game.executablePath
        guard force || !samePath || !checked.contains(game.id) else { completion?(); return }
        guard pendingCompletions.count < 512 else { completion?(); return }
        if !samePath { memory.removeValue(forKey: game.id) }
        if paths.count >= 1024 {
            let evictable = paths.keys.filter { pendingCompletions[$0] == nil && memory[$0] == nil }
            for id in evictable { paths.removeValue(forKey: id); checked.remove(id) }
        }
        paths[game.id] = game.executablePath
        pendingCompletions[game.id] = completion.map { [$0] } ?? []
        let reader = read
        preparation.resolve(deadline: deadline, work: { reader(game) }) { [weak self] outcome in
            guard let self, !self.closed else { return }
            self.checked.insert(game.id)
            if case .resolved(let image) = outcome, let image {
                self.memory[game.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.memoryOrder.removeAll { $0 == game.id }; self.memoryOrder.append(game.id)
                while self.memoryOrder.count > 128 {
                    let evicted = self.memoryOrder.removeFirst()
                    self.memory.removeValue(forKey: evicted); self.checked.remove(evicted)
                }
            }
            let callbacks = self.pendingCompletions.removeValue(forKey: game.id) ?? []
            callbacks.forEach { $0() }
        }
    }

    /// Explicit library refresh rechecks mtimes off main, including failed icons.
    func ensureExtracted(games: [CyderGameRecord], completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        let group = DispatchGroup()
        for game in games {
            group.enter()
            ensureExtracted(game, force: true) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in if self?.closed == false { completion?() } }
    }

    func quiesce() {
        precondition(Thread.isMainThread)
        closed = true; preparation.quiesce()
        let callbacks = pendingCompletions.values.flatMap { $0 }
        pendingCompletions.removeAll()
        callbacks.forEach { $0() }
    }

    private static func readIcon(_ game: CyderGameRecord) -> CGImage? {
        precondition(!Thread.isMainThread)
        guard game.id.range(of: "^profile-[0-9a-f]{24}$", options: .regularExpression) != nil else { return nil }
        let cache = CyderPaths.support.appendingPathComponent("game-icons").appendingPathComponent("\(game.id).png")
        let date = try? game.executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let date, let cachedDate = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           cachedDate >= date, let data = readCache(cache), let image = CyderPEIcon.decode(data) { return image }
        guard let image = try? CyderPEIcon.extract(from: game.executableURL) else { return nil }
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (data as Data).write(to: cache, options: .atomic)
            }
        }
        return image
    }

    private static func readCache(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == data.count ? data : nil
    }
}
