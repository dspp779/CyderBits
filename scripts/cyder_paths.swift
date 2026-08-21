import Foundation

/// Packaging metadata historically used either a display label
/// (`wine crossover 26.2.0 (wine 11.0)`), its filesystem-safe slug
/// (`crossover-26.2.0-wine-11.0`), or Cyder011-style labels with dots
/// vs hyphens (`CX26.3.0-W11-Cyder011` vs `CX26-3-0-W11-Cyder011`).
/// Keep this in sync with `cyder_engine_versions_equal` in cyder-common.sh.
func cyderEngineVersionsEqual(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    let leftSlug = cyderEngineVersionSlug(lhs)
    let rightSlug = cyderEngineVersionSlug(rhs)
    return leftSlug == rhs || lhs == rightSlug || leftSlug == rightSlug
}

func cyderEngineVersionSlug(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "wine crossover "
    if value.hasPrefix(prefix),
       let wineMarker = value.range(of: " (wine ", options: .backwards),
       value.hasSuffix(")") {
        let crossover = value[value.index(value.startIndex, offsetBy: prefix.count)..<wineMarker.lowerBound]
        let wine = value[wineMarker.upperBound..<value.index(before: value.endIndex)]
        return "crossover-\(crossover)-wine-\(wine)".replacingOccurrences(of: " ", with: "-")
    }
    let sikarugirPrefixes = ["wine sikarugir ", "wine Sikarugir "]
    for sikarugirPrefix in sikarugirPrefixes where value.hasPrefix(sikarugirPrefix) {
        let tail = value.dropFirst(sikarugirPrefix.count)
        let slug = "sikarugir-\(tail)"
            .map { ch -> Character in
                if ch == " " || ch == "." || ch == "(" || ch == ")" || ch == "/" { return "-" }
                return ch
            }
        return collapseEngineVersionSlug(String(slug))
    }
    let mapped = value.map { ch -> Character in
        if ch == " " || ch == "." || ch == "(" || ch == ")" || ch == "/" { return "-" }
        return ch
    }
    return collapseEngineVersionSlug(String(mapped))
}

private func collapseEngineVersionSlug(_ raw: String) -> String {
    var slug = ""
    var previousWasHyphen = false
    for ch in raw {
        if ch == "-" {
            if !previousWasHyphen {
                slug.append(ch)
                previousWasHyphen = true
            }
            continue
        }
        slug.append(ch)
        previousWasHyphen = false
    }
    while slug.hasPrefix("-") { slug.removeFirst() }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug
}

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
    /// Default engine directory under `~/.cyder/runtime/Engines`. Override with
    /// `CYDER_ENGINE_NAME` to point at a non-default engine tree.
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

    /// Bundled sidecar label from the running Cyder.app (`Resources/engine-version.txt`).
    static var bundledEngineVersion: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent("engine-version.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Display label for Preferences. When the on-disk marker is a filesystem
    /// slug that identifies the same engine as the app sidecar, rewrite the
    /// marker to the dotted human label and return that.
    @discardableResult
    static func healInstalledEngineVersionLabelIfNeeded() -> String? {
        guard let installed = installedEngineVersion else { return nil }
        guard let bundled = bundledEngineVersion else { return installed }
        if installed == bundled { return installed }
        guard cyderEngineVersionsEqual(installed, bundled) else { return installed }
        let versionURL = engine.appendingPathComponent("version")
        do {
            try (bundled + "\n").write(to: versionURL, atomically: true, encoding: .utf8)
            return bundled
        } catch {
            return installed
        }
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
    /// Temporary copies of EXEs during icon extraction. Not a Wine prefix.
    static let iconExtractRoot: URL = support
        .appendingPathComponent("icon-extract", isDirectory: true)
    /// Default folder for thin game launchers (CrossOver-style subdirectory).
    static let macLaunchersRoot: URL = home
        .appendingPathComponent("Applications/Cyder", isDirectory: true)
    static let bootstrapMarker = sharedBottle.appendingPathComponent(".cyder-bootstrap-v1")
}
