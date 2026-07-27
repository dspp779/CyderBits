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

enum CyderGptkError: Error {
    case invalidSource(URL)
}

enum CyderGptk {
    static let crossOverAppleGptk = URL(
        fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk",
        isDirectory: true
    )

    private static let evaluationVolumePrefix = "Evaluation environment for Windows games"

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

    static func preferredSource() -> CyderGptkSource? {
        if isValidGptkRoot(crossOverAppleGptk) {
            return .crossOver(crossOverAppleGptk)
        }
        if isValidGptkRoot(CyderPaths.appleGptkRuntime) {
            return .runtime(CyderPaths.appleGptkRuntime)
        }
        return nil
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

        let manifest = RuntimeManifest(
            sourceVolume: candidate.volumeRoot.path,
            displayName: candidate.displayName,
            installedAt: ISO8601DateFormatter().string(from: Date())
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: runtimeManifestURL(), options: .atomic)
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
    }

    static func runtimeManifestURL() -> URL {
        CyderPaths.appleGptkRuntime
            .deletingLastPathComponent()
            .appendingPathComponent("apple_gptk-manifest.json")
    }

    private struct RuntimeManifest: Encodable {
        var sourceVolume: String
        var displayName: String
        var installedAt: String
    }
}
