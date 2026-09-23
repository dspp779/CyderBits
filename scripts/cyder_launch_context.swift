import Foundation

struct CyderLaunchContext {
    static func launcherPath(resourcePath: String) -> String {
        resourcePath + "/ogom-scripts/cyder_launcher.sh"
    }

    let launcher: String
    let engineSrc: String
    let engineVersionFile: String
    let environment: [String: String]

    /// Resource metadata can reside on slow storage. Even a main-actor caller
    /// must suspend while a worker resolves the archive; construction never
    /// synchronously performs that I/O on the caller's thread.
    init(resourcePath: String, resolveEngine: @escaping @Sendable (String) -> String = { resolveEngineSrc(resourcePath: $0) }) async {
        let entitlements = resourcePath + "/entitlements.plist"
        let libarchive = resourcePath + "/addons/libarchive"
        let contentsPath = (resourcePath as NSString).deletingLastPathComponent
        let appPath = (contentsPath as NSString).deletingLastPathComponent
        let engineSrc = await Task.detached(priority: .userInitiated) { resolveEngine(resourcePath) }.value

        launcher = Self.launcherPath(resourcePath: resourcePath)
        self.engineSrc = engineSrc
        engineVersionFile = resourcePath + "/engine-version.txt"

        var env = ProcessInfo.processInfo.environment
        env["CYDER_ENGINE_SRC"] = engineSrc
        env["CYDER_SCRIPTS"] = resourcePath + "/ogom-scripts"
        env["CYDER_LIBARCHIVE_SRC"] = libarchive
        env["CYDER_GUI"] = "1"
        env["OGOM"] = resourcePath
        env["WINE_INSTALL"] = engineSrc
        env["ENTITLEMENTS_PLIST"] = entitlements
        env["CYDER_ENTITLEMENTS"] = entitlements
        env["CYDER_APP"] = appPath
        env["CYDER_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? "local.cyder.app"
        environment = env
    }
}

func resolveEngineSrc(resourcePath: String) -> String {
    let archiveListFile = resourcePath + "/engine-archive.txt"
    if let archiveName = try? String(contentsOfFile: archiveListFile, encoding: .utf8) {
        let trimmedArchive = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArchive.isEmpty {
            let archivePath = resourcePath + "/" + trimmedArchive
            if FileManager.default.fileExists(atPath: archivePath) {
                return archivePath
            }
        }
    }
    let versionFile = resourcePath + "/engine-version.txt"
    if let ver = try? String(contentsOfFile: versionFile, encoding: .utf8) {
        let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let slug = trimmed
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "(", with: "-")
                .replacingOccurrences(of: ")", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let collapsed = slug
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
            for name in [
                "engine-\(trimmed).tar.zst",
                "engine-\(collapsed).tar.zst",
                "engine-wine-x86_64-\(trimmed).tar.xz",
                "engine-wine-x86_64-\(collapsed).tar.xz",
            ] {
                let path = resourcePath + "/" + name
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
    }
    return resourcePath + "/engine-payload"
}
