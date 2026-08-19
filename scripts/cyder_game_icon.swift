import AppKit
import Foundation

/// Loads cached PE icons and asks the bundled winemenubuilder helper to extract a
/// missing icon off the main thread. Never falls back to macOS's generic
/// `.exe` document icon (`NSWorkspace`); tiles use a neutral SF Symbol until
/// the PE resource is available.
final class CyderGameIconStore {
    static let shared = CyderGameIconStore()

    private let queue = DispatchQueue(label: "local.cyder.game-icons", qos: .utility)
    private var memory: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var pendingCompletions: [String: [() -> Void]] = [:]
    private var failed: Set<String> = []
    private var failedExecutableDate: [String: Date] = [:]

    func image(for game: CyderGameRecord) -> NSImage {
        if let logo = logo(for: game) { return logo }
        ensureExtracted(game)
        return placeholderImage()
    }

    /// Returns only an icon extracted from the executable. Unlike `image(for:)`,
    /// this does not fall back to a placeholder, so title bars can omit the
    /// image when the game has no logo yet.
    func logo(for game: CyderGameRecord) -> NSImage? {
        let cacheURL = iconURL(for: game)
        if let cached = memory[game.id] {
            if isFresh(cacheURL: cacheURL, executableURL: game.executableURL) {
                return cached
            }
            memory.removeValue(forKey: game.id)
        }
        guard isFresh(cacheURL: cacheURL, executableURL: game.executableURL),
              let image = NSImage(contentsOf: cacheURL) else { return nil }
        memory[game.id] = image
        return image
    }

    /// Call immediately after NSOpenPanel returns so the app opens the EXE
    /// while its user-granted file access is active. The helper receives a
    /// staged copy written from the granted file handle and never reopens the
    /// protected source path.
    func extractSelectedGame(_ game: CyderGameRecord, completion: @escaping () -> Void) {
        failed.remove(game.id)
        failedExecutableDate.removeValue(forKey: game.id)
        ensureExtracted(game, force: true, completion: completion)
    }

    /// Extract a PE icon when missing. Safe for bottle paths under Application Support.
    func ensureExtracted(
        _ game: CyderGameRecord,
        force: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let cacheURL = iconURL(for: game)
        if !force,
           isFresh(cacheURL: cacheURL, executableURL: game.executableURL),
           FileManager.default.fileExists(atPath: cacheURL.path) {
            completion?()
            return
        }
        if pending.contains(game.id) {
            if let completion {
                pendingCompletions[game.id, default: []].append(completion)
            }
            return
        }
        if !force, failed.contains(game.id) {
            if let stamped = failedExecutableDate[game.id],
               let current = executableDate(game.executableURL),
               stamped == current {
                completion?()
                return
            }
            failed.remove(game.id)
            failedExecutableDate.removeValue(forKey: game.id)
        }
        guard let resources = Bundle.main.resourceURL else {
            completion?()
            return
        }
        let helper = resources.appendingPathComponent("ogom-scripts/cyder-extract-exe-icon.sh")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            completion?()
            return
        }
        let wine = CyderPaths.engine.appendingPathComponent("bin/wine")
        guard FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path),
              FileManager.default.fileExists(atPath: wine.path) else {
            completion?()
            return
        }
        let executable: FileHandle
        do {
            executable = try FileHandle(forReadingFrom: game.executableURL)
        } catch {
            recordFailure(id: game.id, executableURL: game.executableURL)
            CyderDiagnostics.shared.warning("game-icon source-open-failed id=\(game.id)")
            completion?()
            return
        }
        pending.insert(game.id)
        extract(game: game, cacheURL: cacheURL, helper: helper, executable: executable, completion: completion ?? {})
    }

    func ensureExtracted(games: [CyderGameRecord], completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for game in games {
            group.enter()
            ensureExtracted(game) { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    private func placeholderImage() -> NSImage {
        let symbol = NSImage(
            systemSymbolName: "gamecontroller.fill",
            accessibilityDescription: nil
        ) ?? NSImage()
        symbol.isTemplate = true
        return symbol
    }

    private func iconURL(for game: CyderGameRecord) -> URL {
        CyderPaths.support
            .appendingPathComponent("game-icons", isDirectory: true)
            .appendingPathComponent("\(game.id).png")
    }

    private func executableDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func isFresh(cacheURL: URL, executableURL: URL) -> Bool {
        guard let iconDate = executableDate(cacheURL),
              let exeDate = executableDate(executableURL) else {
            return false
        }
        return iconDate >= exeDate
    }

    private func recordFailure(id: String, executableURL: URL) {
        failed.insert(id)
        failedExecutableDate[id] = executableDate(executableURL)
    }

    private func finishExtract(id: String, extra: () -> Void) {
        pending.remove(id)
        extra()
        let queued = pendingCompletions.removeValue(forKey: id) ?? []
        queued.forEach { $0() }
    }

    private func extract(
        game: CyderGameRecord,
        cacheURL: URL,
        helper: URL,
        executable: FileHandle,
        completion: @escaping () -> Void
    ) {
        CyderDiagnostics.shared.info("game-icon extract-start id=\(game.id) helper=\(helper.path)")

        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let scratch = CyderPaths.iconExtractRoot
                .appendingPathComponent(game.id, isDirectory: true)
            let stagedExe = scratch.appendingPathComponent("game.exe")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            do {
                if FileManager.default.fileExists(atPath: stagedExe.path) {
                    try FileManager.default.removeItem(at: stagedExe)
                }
                FileManager.default.createFile(atPath: stagedExe.path, contents: nil)
                let dest = try FileHandle(forWritingTo: stagedExe)
                defer { try? dest.close() }
                while true {
                    let chunk = executable.readData(ofLength: 1024 * 1024)
                    if chunk.isEmpty { break }
                    dest.write(chunk)
                }
            } catch {
                try? executable.close()
                try? FileManager.default.removeItem(at: scratch)
                DispatchQueue.main.async {
                    self.recordFailure(id: game.id, executableURL: game.executableURL)
                    CyderDiagnostics.shared.warning("game-icon stage-failed id=\(game.id)")
                    self.finishExtract(id: game.id, extra: completion)
                }
                return
            }
            try? executable.close()

            let wine = CyderPaths.engine.appendingPathComponent("bin/wine")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                helper.path,
                "--exe", stagedExe.path,
                "--png", cacheURL.path,
                "--wine", wine.path,
                "--scratch", scratch.path,
            ]
            // Cost of reusing bottles/shared: the first extract per EXE attaches
            // to that wineserver (a running game on shared can hitch). Timeout
            // only SIGTERM's this bash helper — never terminate wineserver.
            // Independent profile tiles also extract against shared. After
            // game-icons/<id>.png is written, later library opens do not start Wine.
            process.environment = ProcessInfo.processInfo.environment.merging([
                "WINEPREFIX": CyderPaths.sharedBottle.path,
                "WINESERVER": CyderPaths.engine.appendingPathComponent("bin/wineserver").path,
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var status: Int32 = -1
            do {
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                try process.run()
                if finished.wait(timeout: .now() + 45) == .success {
                    status = process.terminationStatus
                } else {
                    process.terminate()
                    status = -2
                }
            } catch {
                // Keep the neutral placeholder when extraction is unavailable.
            }
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async {
                let extracted = status == 0 ? NSImage(contentsOf: cacheURL) : nil
                if let extracted {
                    self.failed.remove(game.id)
                    self.failedExecutableDate.removeValue(forKey: game.id)
                    self.memory[game.id] = extracted
                    CyderDiagnostics.shared.info("game-icon extract-success id=\(game.id)")
                } else {
                    self.recordFailure(id: game.id, executableURL: game.executableURL)
                    CyderDiagnostics.shared.warning("game-icon extract-failed id=\(game.id) status=\(status)")
                }
                self.finishExtract(id: game.id, extra: completion)
            }
        }
    }
}
