import Foundation

/// Applies the dual-variant MoltenVK `.real` symlink via the shared bash helper.
enum CyderMoltenvk {
    static var helperURL: URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("ogom-scripts/cyder-moltenvk-variant.sh")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        // Development / test: scripts next to the repo checkout.
        let env = ProcessInfo.processInfo.environment
        if let scripts = env["CYDER_SCRIPTS"], !scripts.isEmpty {
            let candidate = URL(fileURLWithPath: scripts)
                .appendingPathComponent("cyder-moltenvk-variant.sh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    static func ensureVariant(preference: String, engineRoot: URL = CyderPaths.engine) -> Bool {
        guard let helper = helperURL else {
            CyderDiagnostics.shared.warning("moltenvk variant helper missing")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, "apply-if-present", engineRoot.path, preference]
        process.environment = ProcessInfo.processInfo.environment
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                CyderDiagnostics.shared.warning(
                    "moltenvk variant apply failed status=\(process.terminationStatus) pref=\(preference)"
                )
                return false
            }
            return true
        } catch {
            CyderDiagnostics.shared.warning("moltenvk variant apply error=\(error)")
            return false
        }
    }
}
