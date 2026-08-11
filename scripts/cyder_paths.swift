import Foundation

/// Filesystem locations shared by the native launcher and its services.
/// Kept in its own file so path policy can be tested without loading AppKit UI.
enum CyderPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support: URL = {
        if let override = ProcessInfo.processInfo.environment["CYDER_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
    }()
    static var appleGptkRuntime: URL {
        support.appendingPathComponent("runtime/apple_gptk", isDirectory: true)
    }
    static let runtimeRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["CYDER_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".cyder/runtime", isDirectory: true)
    }()
    /// Regular Cyder uses `wine-x86_64`; MapleStory OEM special sets
    /// `CYDER_ENGINE_NAME` so the flavor can share `~/.cyder/runtime` without
    /// colliding with the official engine tree.
    static let engineName: String = {
        if let override = ProcessInfo.processInfo.environment["CYDER_ENGINE_NAME"], !override.isEmpty {
            return override
        }
        return "wine-x86_64"
    }()
    static let engine = runtimeRoot
        .appendingPathComponent("Engines/\(engineName)", isDirectory: true)

    /// Label written by ensure-engine (`version`, with a legacy marker fallback).
    static var installedEngineVersion: String? {
        let files = [
            engine.appendingPathComponent("version"),
            engine.appendingPathComponent(".cyder-engine-version"),
        ]
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
    /// Prefer an absolute `CYDER_PREFIX`, then its compatibility alias;
    /// `bottles/$CYDER_BOTTLE_NAME` (default `shared`).
    static let sharedBottle: URL = {
        if let override = ProcessInfo.processInfo.environment["CYDER_PREFIX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let override = ProcessInfo.processInfo.environment["CYDER_SHARED_PREFIX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let bottleName: String = {
            if let override = ProcessInfo.processInfo.environment["CYDER_BOTTLE_NAME"], !override.isEmpty {
                return override
            }
            return "shared"
        }()
        return support.appendingPathComponent("bottles/\(bottleName)", isDirectory: true)
    }()
    static let bootstrapMarker = sharedBottle.appendingPathComponent(".cyder-bootstrap-v1")
}
