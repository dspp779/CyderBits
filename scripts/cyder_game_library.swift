import Foundation

/// A lightweight, user-facing entry in the Cyder game library.  The entry is
/// deliberately separate from a profile: adding a game remembers the EXE and
/// its stable ID, while per-game launch options can be stored without creating
/// a bottle/profile.
struct CyderGameRecord: Codable, Equatable, Identifiable {
    let id: String
    var executablePath: String
    var addedAt: Date
    /// Start Menu / Desktop `.lnk` name when the game was imported from a shortcut.
    var title: String?
    /// Thin macOS `.app` wrapper under ~/Applications/Cyder, if created.
    var macAppPath: String?

    var executableURL: URL {
        URL(fileURLWithPath: executablePath)
    }

    var displayName: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return executableURL.deletingPathExtension().lastPathComponent
    }

    init(id: String, executablePath: String, addedAt: Date = Date(), title: String? = nil, macAppPath: String? = nil) {
        self.id = id
        self.executablePath = executablePath
        self.addedAt = addedAt
        self.title = title
        self.macAppPath = macAppPath
    }
}

private struct CyderGameLibraryFile: Codable {
    var schemaVersion = 1
    var games: [CyderGameRecord] = []
}

enum CyderGameLibraryError: LocalizedError {
    case invalidExecutable(String)
    case duplicateExecutable(String)
    case unableToSave(String)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path):
            return "無法加入這個 EXE：\(path)"
        case .duplicateExecutable(let path):
            return "這個遊戲已經在遊戲庫中：\(path)"
        case .unableToSave(let reason):
            return "無法儲存遊戲庫：\(reason)"
        }
    }
}

/// Persistent game-library metadata.  EXE files remain in their original
/// locations; Cyder only stores their canonical path and a stable executable
/// ID (using the same format as legacy profile IDs).
final class CyderGameLibraryStore {
    static let shared = CyderGameLibraryStore()

    private(set) var games: [CyderGameRecord] = []
    private let url: URL
    private let profileStore: CyderProfileStore

    init(
        url: URL = CyderPaths.support.appendingPathComponent("game-library.json"),
        profileStore: CyderProfileStore = CyderProfileStore(root: CyderPaths.support)
    ) {
        self.url = url
        self.profileStore = profileStore
        load()
    }

    func add(executable: URL, title: String? = nil) throws -> CyderGameRecord {
        let canonical = try profileStore.canonicalExecutablePath(executable)
        guard canonical.lowercased().hasSuffix(".exe") else {
            throw CyderGameLibraryError.invalidExecutable(canonical)
        }
        let id = try profileStore.profileID(for: URL(fileURLWithPath: canonical))
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        if let index = games.firstIndex(where: { $0.id == id }) {
            // Keep the original add date while refreshing a path that was
            // selected through a symlink or a Finder alias.
            games[index].executablePath = canonical
            if let storedTitle {
                games[index].title = storedTitle
            }
            try save()
            return games[index]
        }
        let record = CyderGameRecord(
            id: id,
            executablePath: canonical,
            title: storedTitle
        )
        games.append(record)
        sortGames()
        try save()
        return record
    }

    func remove(id: String) throws {
        games.removeAll { $0.id == id }
        try save()
    }

    /// Existing versions of Cyder already created profile metadata without a
    /// game-library entry.  Import those records on first opening so users do
    /// not lose access to games they already configured.
    func merge(profileRecords: [CyderProfileRecord]) throws {
        var changed = false
        for record in profileRecords {
            guard !games.contains(where: { $0.id == record.profileId }) else { continue }
            games.append(CyderGameRecord(id: record.profileId, executablePath: record.sourcePath))
            changed = true
        }
        guard changed else { return }
        sortGames()
        try save()
    }

    func reload() {
        load()
    }

    func setMacAppPath(_ path: String?, forGameID id: String) throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].macAppPath = path
        try save()
    }

    /// Drop library entries whose EXE path no longer exists on disk.
    @discardableResult
    func removeMissingExecutables() throws -> Int {
        let before = games.count
        games.removeAll { !FileManager.default.fileExists(atPath: $0.executablePath) }
        let removed = before - games.count
        guard removed > 0 else { return 0 }
        try save()
        return removed
    }

    /// Import EXE targets discovered from Start Menu / Desktop shortcuts.
    /// Returns newly added records (duplicates are refreshed in place and omitted).
    @discardableResult
    func importShortcuts(
        from prefix: URL = CyderPaths.sharedBottle
    ) throws -> [CyderGameRecord] {
        var added: [CyderGameRecord] = []
        var known = Set(games.map(\.id))
        for shortcut in CyderBottleShortcutScanner.discover(prefix: prefix) {
            guard let exe = CyderBottleShortcutScanner.hostExecutableURL(
                windowsTarget: shortcut.windowsTarget,
                prefix: prefix
            ) else { continue }
            let record = try add(executable: exe, title: shortcut.displayName)
            if known.insert(record.id).inserted {
                added.append(record)
            }
        }
        return added
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CyderGameLibraryFile.self, from: data),
              file.schemaVersion == 1 else {
            games = []
            return
        }
        games = file.games.filter { game in
            game.id.range(of: "^profile-[0-9a-f]{24}$", options: .regularExpression) != nil
                && !game.executablePath.isEmpty
                && !game.executablePath.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
        sortGames()
    }

    private func sortGames() {
        games.sort {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.executablePath.localizedStandardCompare($1.executablePath) == .orderedAscending
        }
    }

    private func save() throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = CyderGameLibraryFile(games: games)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            throw CyderGameLibraryError.unableToSave(error.localizedDescription)
        }
    }
}
