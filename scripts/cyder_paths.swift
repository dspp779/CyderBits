import Foundation

/// Filesystem locations shared by the native launcher and its services.
/// Kept in its own file so path policy can be tested without loading AppKit UI.
enum CyderPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home
        .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
    static let runtimeRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["CYDER_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".cyder/runtime", isDirectory: true)
    }()
    static let engine = runtimeRoot
        .appendingPathComponent("Engines/wine-x86_64", isDirectory: true)
    static let sharedBottle = support
        .appendingPathComponent("bottles/shared", isDirectory: true)
    static let bootstrapMarker = sharedBottle.appendingPathComponent(".cyder-bootstrap-v1")
}
