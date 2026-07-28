import Foundation

/// Exercises the same GPTK + graphics settings merge that `wineEnvironment` performs
/// before spawning Wine. Wine CompatDB runtime sets `CX_ACTIVE_GRAPHICS_BACKEND`
/// inside `apply_graphics_backend()` after reading `CYDER_GRAPHICS_BACKEND`:
/// - `dxvk` → active `dxvk`, DLL overrides `n,b`, prepend `lib/dxvk`
/// - `d3dmetal` → active `d3dmetal`, DLL overrides `b`, prepend GPTK `wine/`
/// - unavailable backend → fallback active `wined3d`
/// This harness cannot spawn Wine, so it asserts App-side inputs only.
@main
enum CyderWineEnvironmentHarness {
    static func main() throws {
        let tmp = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let engineRoot = tmp.appendingPathComponent("engine", isDirectory: true)
        let gptkRoot = tmp.appendingPathComponent("fake-gptk", isDirectory: true)
        let external = gptkRoot.appendingPathComponent("external", isDirectory: true)
        let manager = FileManager.default

        try manager.createDirectory(at: external.appendingPathComponent("D3DMetal.framework"), withIntermediateDirectories: true)
        try "shared library payload\n".write(
            to: external.appendingPathComponent("libd3dshared.dylib"),
            atomically: true,
            encoding: .utf8
        )
        try manager.createDirectory(at: engineRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)

        setenv("CYDER_SUPPORT", tmp.appendingPathComponent("support").path, 1)
        setenv("CYDER_ALLOW_TEST_HOOKS", "1", 1)
        setenv("CYDER_TEST_GPTK_ROOT", gptkRoot.path, 1)

        let settingsURL = tmp.appendingPathComponent("support/settings.json")
        try manager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settingsURL)
        let store = CyderSettingsStore(url: settingsURL)

        // Inherited shell graphics env must not leak through a default selection.
        setenv("CYDER_GRAPHICS_BACKEND", "d3dmetal", 1)
        setenv("DXVK_FRAME_RATE", "60", 1)
        let defaultEnv = launchEnvironment(
            store: store,
            profileID: nil,
            gameSettings: CyderExecutableSettings(graphicsBackend: .default),
            engineRoot: engineRoot
        )
        precondition(defaultEnv["CYDER_GRAPHICS_BACKEND"] == nil)
        precondition(defaultEnv["DXVK_FRAME_RATE"] == nil)

        let d3dmetalRule = CyderExecutableSettings(
            graphicsBackend: .d3dmetal,
            dxvkFrameRate: .unlimited
        )
        let d3dmetalEnv = launchEnvironment(
            store: store,
            profileID: "profile-0123456789abcdef01234567",
            gameSettings: d3dmetalRule,
            engineRoot: engineRoot
        )
        precondition(d3dmetalEnv["CYDER_GRAPHICS_BACKEND"] == "d3dmetal")
        precondition(d3dmetalEnv["CX_GRAPHICS_BACKEND"] == "d3dmetal")
        precondition(d3dmetalEnv["DXVK_FRAME_RATE"] == nil)
        precondition(d3dmetalEnv["CYDER_GPTK_ROOT"] == gptkRoot.path)
        precondition(
            d3dmetalEnv["CX_APPLEGPTK_LIBD3DSHARED_PATH"]
                == external.appendingPathComponent("libd3dshared.dylib").path
        )
        let frameworkPath = d3dmetalEnv["DYLD_FRAMEWORK_PATH"] ?? ""
        precondition(frameworkPath.hasPrefix(external.path))
        precondition(d3dmetalEnv["CYDER_GRAPHICS_BACKENDS_ROOT"] == engineRoot.path)
        precondition(!d3dmetalEnv.values.contains(where: { $0.contains("lib64/apple_gptk") }))
        let engineGptk = engineRoot.appendingPathComponent("lib64/apple_gptk")
        precondition(
            (try? manager.destinationOfSymbolicLink(atPath: engineGptk.path)) == gptkRoot.path
                || CyderGptk.isValidGptkRoot(engineGptk)
        )

        let dxvkRule = CyderExecutableSettings(
            graphicsBackend: .dxvk,
            dxvkFrameRate: .sixty
        )
        let dxvkEnv = launchEnvironment(
            store: store,
            profileID: "profile-0123456789abcdef01234567",
            gameSettings: dxvkRule,
            engineRoot: engineRoot
        )
        precondition(dxvkEnv["CYDER_GRAPHICS_BACKEND"] == "dxvk")
        precondition(dxvkEnv["DXVK_FRAME_RATE"] == "60")
        precondition(dxvkEnv["CYDER_GPTK_ROOT"] == gptkRoot.path)
        precondition(dxvkEnv["CX_APPLEGPTK_LIBD3DSHARED_PATH"] != nil)
        precondition((dxvkEnv["DYLD_FRAMEWORK_PATH"] ?? "").contains("/external"))
        // Wine would set CX_ACTIVE_GRAPHICS_BACKEND=dxvk after apply_graphics_backend().

        print("PASS cyder-wine-environment-harness")
    }

    private static func launchEnvironment(
        store: CyderSettingsStore,
        profileID: String?,
        gameSettings: CyderExecutableSettings?,
        engineRoot: URL
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CYDER_GRAPHICS_BACKEND")
        environment.removeValue(forKey: "DXVK_FRAME_RATE")
        for (key, value) in store.environment(
            profileID: profileID,
            legacyBasename: nil,
            override: gameSettings,
            engineRoot: engineRoot
        ) {
            environment[key] = value
        }
        if let backend = environment["CYDER_GRAPHICS_BACKEND"] {
            environment["CX_GRAPHICS_BACKEND"] = backend
        }
        environment["CYDER_GRAPHICS_BACKENDS_ROOT"] = engineRoot.path
        _ = CyderGptk.applyLaunchEnvironment(to: &environment, engineRoot: engineRoot)
        return environment
    }
}
