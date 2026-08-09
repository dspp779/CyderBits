import AppKit
import Foundation

/// Loads cached PE icons and asks the bundled Python PE parser to extract a
/// missing icon off the main thread. Never falls back to macOS's generic
/// `.exe` document icon (`NSWorkspace`); tiles use a neutral SF Symbol until
/// the PE resource is available.
final class CyderGameIconStore {
    static let shared = CyderGameIconStore()

    private let queue = DispatchQueue(label: "local.cyder.game-icons", qos: .utility)
    private var memory: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    func image(for game: CyderGameRecord) -> NSImage {
        if let logo = logo(for: game) { return logo }
        ensureExtracted(game)
        return placeholderImage()
    }

    /// Returns only an icon extracted from the executable. Unlike `image(for:)`,
    /// this does not fall back to a placeholder, so title bars can omit the
    /// image when the game has no logo yet.
    func logo(for game: CyderGameRecord) -> NSImage? {
        if let cached = memory[game.id] { return cached }
        let cacheURL = iconURL(for: game)
        guard isFresh(cacheURL: cacheURL, executableURL: game.executableURL),
              let image = NSImage(contentsOf: cacheURL) else { return nil }
        memory[game.id] = image
        return image
    }

    /// Call immediately after NSOpenPanel returns so the app opens the EXE
    /// while its user-granted file access is active. The child parser receives
    /// an inherited descriptor and never reopens the protected source path.
    func extractSelectedGame(_ game: CyderGameRecord, completion: @escaping () -> Void) {
        failed.remove(game.id)
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
        guard !pending.contains(game.id) else { return }
        guard force || !failed.contains(game.id) else {
            completion?()
            return
        }
        guard let resources = Bundle.main.resourceURL else {
            completion?()
            return
        }
        let helper = resources.appendingPathComponent("ogom-scripts/cyder_create_game_app.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            completion?()
            return
        }
        let executable: FileHandle
        do {
            executable = try FileHandle(forReadingFrom: game.executableURL)
        } catch {
            failed.insert(game.id)
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

    private func isFresh(cacheURL: URL, executableURL: URL) -> Bool {
        guard let iconDate = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let executableDate = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return iconDate >= executableDate
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [helper.path, "--extract-icon-stdin", cacheURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var status: Int32 = -1
            do {
                defer { try? executable.close() }
                process.standardInput = executable
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                try process.run()
                if finished.wait(timeout: .now() + 15) == .success {
                    status = process.terminationStatus
                } else {
                    process.terminate()
                    status = -2
                }
            } catch {
                // Keep the neutral placeholder when extraction is unavailable.
            }
            DispatchQueue.main.async {
                self.pending.remove(game.id)
                let extracted = status == 0 ? NSImage(contentsOf: cacheURL) : nil
                if let extracted {
                    self.memory[game.id] = extracted
                    CyderDiagnostics.shared.info("game-icon extract-success id=\(game.id)")
                } else {
                    self.failed.insert(game.id)
                    CyderDiagnostics.shared.warning("game-icon extract-failed id=\(game.id) status=\(status)")
                }
                completion()
            }
        }
    }
}
