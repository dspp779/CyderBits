import CoreServices
import Foundation

enum CyderMacLauncherError: LocalizedError {
    case missingHelper
    case missingExecutable(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHelper:
            return "Cyder 缺少建立 macOS 應用程式的 helper 腳本。"
        case .missingExecutable(let path):
            return "找不到遊戲 EXE：\(path)"
        case .scriptFailed(let detail):
            return "無法建立 macOS 應用程式：\(detail)"
        }
    }
}

/// Builds thin `.app` wrappers under `~/Applications/Cyder` that hand off to Cyder.app.
enum CyderMacLauncherInstaller {
    static func outputDirectory() -> URL {
        CyderPaths.macLaunchersRoot
    }

    static func sanitizedAppName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\\0")
        var parts: [String] = []
        for scalar in trimmed.unicodeScalars {
            if invalid.contains(scalar) {
                parts.append("-")
            } else {
                parts.append(String(scalar))
            }
        }
        var sanitized = parts.joined()
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        if sanitized.isEmpty { sanitized = "Game" }
        return String(sanitized.prefix(120))
    }

    static func appURL(for game: CyderGameRecord) -> URL {
        outputDirectory()
            .appendingPathComponent("\(sanitizedAppName(game.displayName)).app", isDirectory: true)
    }

    static func isInstalled(for game: CyderGameRecord) -> Bool {
        if let stored = game.macAppPath,
           FileManager.default.fileExists(atPath: stored) {
            return true
        }
        return FileManager.default.fileExists(atPath: appURL(for: game).path)
    }

    static func iconPNG(for game: CyderGameRecord) -> URL? {
        let url = CyderPaths.support
            .appendingPathComponent("game-icons", isDirectory: true)
            .appendingPathComponent("\(game.id).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Installs a thin launcher under `~/Applications/Cyder`.
    ///
    /// Icon policy: pass `--icon-png` only when `game-icons/<id>.png` exists.
    /// If the library has not extracted a PE icon yet, the shell helper falls
    /// back to Cyder.app's `AppIcon.icns` so the wrapper is never iconless.
    static func install(
        game: CyderGameRecord,
        cyderApp: URL = Bundle.main.bundleURL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try installOnWorker(game: game, cyderApp: cyderApp) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func installOnWorker(game: CyderGameRecord, cyderApp: URL) throws -> URL {
        precondition(!Thread.isMainThread)
        guard FileManager.default.fileExists(atPath: game.executablePath) else {
            throw CyderMacLauncherError.missingExecutable(game.executablePath)
        }
        guard let resources = Bundle.main.resourceURL else {
            throw CyderMacLauncherError.missingHelper
        }
        let helper = resources.appendingPathComponent("ogom-scripts/cyder-create-mac-launcher.sh")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CyderMacLauncherError.missingHelper
        }
        let destination = appURL(for: game)
        var arguments = [
            "--exe", game.executablePath,
            "--cyder-app", cyderApp.path,
            "--output", destination.path,
            "--name", game.displayName,
            "--bundle-id", "local.cyder.launcher.\(game.id)",
        ]
        if let icon = iconPNG(for: game) { arguments.append(contentsOf: ["--icon-png", icon.path]) }
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        // Drain while the child runs, so a full error pipe cannot prevent exit.
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(process.terminationStatus)"
            throw CyderMacLauncherError.scriptFailed(detail)
        }
        registerWithLaunchServices(destination)
        return destination
    }

    private static func registerWithLaunchServices(_ appURL: URL) {
        LSRegisterURL(appURL as CFURL, true)
    }
}
