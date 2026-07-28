import Foundation

enum CyderGptkSource: Equatable {
    case crossOver(URL)
    case runtime(URL)
}

struct CyderGptkVolumeCandidate: Equatable {
    var volumeRoot: URL
    var displayName: String
    var libRoot: URL
}

struct CyderGptkRuntimeManifest: Equatable, Codable {
    var sourceVolume: String
    var displayName: String
    var installedAt: String
}

struct CyderGptkActiveInfo: Equatable {
    var source: CyderGptkSource
    var versionLabel: String
    var statusLine: String
}

enum CyderGptkError: Error {
    case invalidSource(URL)
}

enum CyderGptk {
    static let crossOverAppleGptk = URL(
        fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk",
        isDirectory: true
    )

    private static let evaluationVolumePrefix = "Evaluation environment for Windows games"

    /// Short label like "3.0" / "4.0 beta 1" from a GPTK volume or manifest name.
    static func versionLabel(fromVolumeDisplayName displayName: String) -> String {
        let prefix = evaluationVolumePrefix
        if displayName.hasPrefix(prefix) {
            let suffix = displayName.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { return String(suffix) }
        }
        return displayName
    }

    static func loadRuntimeManifest() -> CyderGptkRuntimeManifest? {
        let url = runtimeManifestURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CyderGptkRuntimeManifest.self, from: data)
    }

    /// GPTK used for D3DMetal, if any. User-installed runtime copy wins over CrossOver.
    static func preferredSource() -> CyderGptkSource? {
        let env = ProcessInfo.processInfo.environment
        // Test-only override; require an explicit allow flag so packaged apps ignore it.
        if env["CYDER_ALLOW_TEST_HOOKS"] == "1",
           let override = env["CYDER_TEST_GPTK_ROOT"], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            if isValidGptkRoot(root) {
                return .runtime(root)
            }
        }
        if isValidGptkRoot(CyderPaths.appleGptkRuntime) {
            return .runtime(CyderPaths.appleGptkRuntime)
        }
        if isValidGptkRoot(crossOverAppleGptk) {
            return .crossOver(crossOverAppleGptk)
        }
        return nil
    }

    static func activeInfo() -> CyderGptkActiveInfo? {
        guard let source = preferredSource() else { return nil }
        switch source {
        case .runtime:
            let version = loadRuntimeManifest()
                .map { versionLabel(fromVolumeDisplayName: $0.displayName) }
                ?? "已安裝"
            return CyderGptkActiveInfo(
                source: source,
                versionLabel: version,
                statusLine: "目前套用：GPTK \(version)（Cyder 已安裝）"
            )
        case .crossOver:
            return CyderGptkActiveInfo(
                source: source,
                versionLabel: "CrossOver",
                statusLine: "目前套用：CrossOver 內附 GPTK"
            )
        }
    }

    /// Point `$engineRoot/lib64/apple_gptk` at the active GPTK root via symlink.
    static func syncEngineLink(engineRoot: URL = CyderPaths.engine) {
        guard let source = preferredSource() else { return }
        let root: URL
        switch source {
        case .crossOver(let url), .runtime(let url):
            root = url
        }
        _ = ensureEngineAppleGptkLink(engineRoot: engineRoot, gptkRoot: root)
    }

    static func isValidGptkRoot(_ root: URL) -> Bool {
        let manager = FileManager.default
        let sharedLibrary = root.appendingPathComponent("external/libd3dshared.dylib")
        let framework = root.appendingPathComponent("external/D3DMetal.framework", isDirectory: true)
        var isFrameworkDirectory: ObjCBool = false
        return manager.fileExists(atPath: sharedLibrary.path)
            && manager.isReadableFile(atPath: sharedLibrary.path)
            && manager.fileExists(atPath: framework.path, isDirectory: &isFrameworkDirectory)
            && isFrameworkDirectory.boolValue
    }

    /// Applies GPTK discovery paths to a Wine launch environment.
    /// Returns the GPTK source label used for diagnostics (`crossOver`, `runtime`, or `none`).
    ///
    /// CrossOver OEM `cxcompatdb` loads D3DMetal PE DLLs from
    /// `$CX_ROOT/lib64/apple_gptk/wine`. When `engineRoot` is provided, link that
    /// tree to the discovered GPTK root so OEM engines without a bundled GPTK
    /// still resolve the payload (without redistributing it inside the App).
    @discardableResult
    static func applyLaunchEnvironment(
        to environment: inout [String: String],
        engineRoot: URL? = nil
    ) -> String {
        let gptkSource: String
        if let source = preferredSource() {
            let root: URL
            switch source {
            case .crossOver(let url):
                root = url
                gptkSource = "crossOver"
            case .runtime(let url):
                root = url
                gptkSource = "runtime"
            }
            environment["CYDER_GPTK_ROOT"] = root.path
            let shared = root.appendingPathComponent("external/libd3dshared.dylib")
            if FileManager.default.isReadableFile(atPath: shared.path) {
                environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared.path
            }
            let external = root.appendingPathComponent("external", isDirectory: true).path
            let existingFrameworkPath = environment["DYLD_FRAMEWORK_PATH"] ?? ""
            environment["DYLD_FRAMEWORK_PATH"] = existingFrameworkPath.isEmpty
                ? external
                : external + ":" + existingFrameworkPath
            if let engineRoot {
                _ = ensureEngineAppleGptkLink(engineRoot: engineRoot, gptkRoot: root)
            }
        } else {
            gptkSource = "none"
        }
        return gptkSource
    }

    /// Ensure `$engineRoot/lib64/apple_gptk` resolves to a usable GPTK tree.
    @discardableResult
    static func ensureEngineAppleGptkLink(engineRoot: URL, gptkRoot: URL) -> Bool {
        let manager = FileManager.default
        guard isValidGptkRoot(gptkRoot) else { return false }
        let lib64 = engineRoot.appendingPathComponent("lib64", isDirectory: true)
        let link = lib64.appendingPathComponent("apple_gptk", isDirectory: true)
        let targetPath = gptkRoot.standardizedFileURL.path

        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: link.path, isDirectory: &isDirectory) {
            if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
                let resolved: String
                if destination.hasPrefix("/") {
                    resolved = URL(fileURLWithPath: destination).standardizedFileURL.path
                } else {
                    resolved = lib64.appendingPathComponent(destination).standardizedFileURL.path
                }
                if resolved == targetPath { return true }
                try? manager.removeItem(at: link)
            } else if isValidGptkRoot(link) {
                return true
            } else {
                return false
            }
        }

        do {
            try manager.createDirectory(at: lib64, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: targetPath)
            return isValidGptkRoot(link)
        } catch {
            return false
        }
    }

    static func scanEvaluationVolumes() -> [CyderGptkVolumeCandidate] {
        let manager = FileManager.default
        let volumesRoot: URL
        if let override = ProcessInfo.processInfo.environment["CYDER_TEST_VOLUMES_ROOT"], !override.isEmpty {
            volumesRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }

        guard let volumeURLs = try? manager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return volumeURLs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { volumeRoot in
                let displayName = volumeRoot.lastPathComponent
                guard displayName.hasPrefix(evaluationVolumePrefix) else {
                    return nil
                }
                let libRoot = volumeRoot.appendingPathComponent("redist/lib", isDirectory: true)
                guard isValidGptkRoot(libRoot) else {
                    return nil
                }
                return CyderGptkVolumeCandidate(
                    volumeRoot: volumeRoot,
                    displayName: displayName,
                    libRoot: libRoot
                )
            }
    }

    static func install(from candidate: CyderGptkVolumeCandidate) throws {
        guard isValidGptkRoot(candidate.libRoot) else {
            throw CyderGptkError.invalidSource(candidate.libRoot)
        }

        let manager = FileManager.default
        let destination = CyderPaths.appleGptkRuntime
        let runtimeRoot = destination.deletingLastPathComponent()
        try manager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)

        let staging = runtimeRoot.appendingPathComponent(
            ".apple_gptk-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }

        for item in try manager.contentsOfDirectory(at: candidate.libRoot, includingPropertiesForKeys: nil) {
            try manager.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }

        guard isValidGptkRoot(staging) else {
            throw CyderGptkError.invalidSource(staging)
        }

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        let manifest = CyderGptkRuntimeManifest(
            sourceVolume: candidate.volumeRoot.path,
            displayName: candidate.displayName,
            installedAt: ISO8601DateFormatter().string(from: Date())
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: runtimeManifestURL(), options: .atomic)
        syncEngineLink()
    }

    static func removeRuntimeInstall() throws {
        let manager = FileManager.default
        let destination = CyderPaths.appleGptkRuntime
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }

        let manifest = runtimeManifestURL()
        if manager.fileExists(atPath: manifest.path) {
            try manager.removeItem(at: manifest)
        }
        syncEngineLink()
    }

    static func runtimeManifestURL() -> URL {
        CyderPaths.appleGptkRuntime
            .deletingLastPathComponent()
            .appendingPathComponent("apple_gptk-manifest.json")
    }
}
