import Foundation

@main
struct CyderSettingsHarness {
    static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = CyderSettingsStore(url: path)
        let profileID = "profile-0123456789abcdef01234567"
        precondition(store.value.schemaVersion == 9)
        precondition(store.value.graphicsBackend == .default)
        precondition(store.value.dxvkFrameRate == .sixty)
        precondition(store.value.graphicsHud == .off)
        precondition(store.value.dxvkHudFrametimes)
        precondition(store.value.wineDiagnostics == .quiet)
        precondition(store.environment["CYDER_WINE_DIAGNOSTICS"] == "quiet")
        precondition(store.environment["CYDER_DPI"] == "480")
        let profileEnvironment = store.environment(profileID: profileID, legacyBasename: "game.exe")
        precondition(profileEnvironment["PROFILE_VALUE"] == "yes")
        precondition(profileEnvironment["LEGACY_VALUE"] == nil)
        precondition(profileEnvironment["BAD-KEY"] == nil)
        precondition(profileEnvironment["UNICODE_QUOTE"] == "中文 \"測試\"")
        precondition(profileEnvironment["CONTROL"] == nil)
        precondition(profileEnvironment["CYDER_POWER_MODE"] == "normal")
        precondition(store.arguments(profileID: profileID, legacyBasename: "game.exe") == ["--profile"])
        precondition(store.hasSettings(profileID: profileID, legacyBasename: "game.exe"))

        let unknownID = "profile-aaaaaaaaaaaaaaaaaaaaaaaa"
        precondition(store.environment(profileID: unknownID, legacyBasename: "game.exe")["LEGACY_VALUE"] == nil)
        precondition(store.arguments(profileID: unknownID, legacyBasename: "game.exe").isEmpty)
        precondition(!store.hasSettings(profileID: unknownID, legacyBasename: "game.exe"))
        precondition(store.environment(profileID: nil, legacyBasename: "game.exe")["LEGACY_VALUE"] == "yes")

        try store.update { settings in
            settings.dpi = 144
            settings.msync = true
            settings.perExecutable["game.exe"] = CyderExecutableSettings(
                arguments: ["--windowed", "中文 \"測試\"", "bad\nvalue"], environment: ["GAME_PROFILE": "test"],
                msync: false, esync: true, retinaMode: false, dpi: 96,
                powerMode: "energySaving"
            )
            settings.perProfile["not-a-profile"] = CyderExecutableSettings()
            settings.perProfile[profileID]?.environment["NOT VALID"] = "discard"
        }
        let legacy = store.environment(profileID: nil, legacyBasename: "game.exe")
        precondition(legacy["CYDER_DPI"] == "96")
        precondition(legacy["CYDER_MSYNC"] == "0")
        precondition(legacy["CYDER_POWER_MODE"] == "background")
        precondition(legacy["GAME_PROFILE"] == "test")
        precondition(store.arguments(profileID: nil, legacyBasename: "game.exe") == ["--windowed", "中文 \"測試\""])
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let profiles = saved["perProfile"] as! [String: Any]
        precondition(profiles["not-a-profile"] == nil)
        let profile = profiles[profileID] as! [String: Any]
        let environment = profile["environment"] as! [String: Any]
        precondition(environment["NOT VALID"] == nil)
        let reloaded = CyderSettingsStore(url: path)
        precondition(reloaded.value.schemaVersion == 9)
        precondition(reloaded.value.revision == 1)

        try store.update { settings in
            settings.wineDiagnostics = .errors
        }
        precondition(store.environment["CYDER_WINE_DIAGNOSTICS"] == "errors")
        precondition(CyderWineDiagnostics.errors.wineDebug == "-all,err+all,+timestamp,+pid,+tid")
        precondition(CyderWineDiagnostics.sync.wineDebug == "-all,err+all,+timestamp,+pid,+tid,+sync")
        precondition(CyderWineDiagnostics.unwind.wineDebug == "-all,+timestamp,+pid,+tid,+seh,+unwind")
        precondition(CyderSettings.isValidEnvironmentKey("GAME_TOKEN"))
        precondition(!CyderSettings.isValidEnvironmentKey("WINEPREFIX"))
        precondition(!CyderSettings.isValidEnvironmentKey("WINEDEBUG"))
        precondition(!CyderSettings.isValidEnvironmentKey("DYLD_INSERT_LIBRARIES"))
        precondition(!CyderSettings.isValidEnvironmentKey("CYDER_WINE_RESULT_FILE"))
        precondition(!CyderSettings.isValidEnvironmentKey("CYDER_GRAPHICS_HUD_PREFERENCE"))

        try store.update { settings in
            settings.wineDiagnostics = .sync
        }
        precondition(store.environment["CYDER_WINE_DIAGNOSTICS"] == "sync")
        precondition(CyderSettings.sanitizedWineDiagnostics("sync") == .sync)

        var globalDxvk = CyderSettings()
        globalDxvk.graphicsBackend = .dxvk
        globalDxvk.dxvkFrameRate = .sixty
        globalDxvk.graphicsHud = .dxvk
        var resolved = CyderSettings.resolveGraphics(global: globalDxvk, profile: nil)
        precondition(resolved.backend == .dxvk)
        precondition(resolved.dxvkFrameRate == .sixty)

        let profileUnlimited = CyderExecutableSettings(dxvkFrameRate: .unlimited)
        resolved = CyderSettings.resolveGraphics(global: globalDxvk, profile: profileUnlimited)
        precondition(resolved.backend == .dxvk)
        precondition(resolved.dxvkFrameRate == .unlimited)

        var globalWined3d = CyderSettings()
        globalWined3d.graphicsBackend = .wined3d
        let profileDefault = CyderExecutableSettings(graphicsBackend: .default)
        resolved = CyderSettings.resolveGraphics(global: globalWined3d, profile: profileDefault)
        precondition(resolved.backend == .default)
        precondition(resolved.dxvkFrameRate == .sixty)

        try store.update { settings in
            settings.graphicsBackend = .dxvk
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .dxvk
            settings.dxvkHudFrametimes = false
        }
        let dxvkEnv = store.environment(profileID: nil, legacyBasename: nil)
        precondition(dxvkEnv["CYDER_GRAPHICS_BACKEND"] == "dxvk")
        precondition(dxvkEnv["DXVK_FRAME_RATE"] == "60")
        precondition(dxvkEnv["DXVK_HUD"] == "fps")

        try store.update { settings in
            settings.dxvkHudFrametimes = true
        }
        let dxvkFrametimesEnv = store.environment(profileID: nil, legacyBasename: nil)
        precondition(dxvkFrametimesEnv["DXVK_HUD"] == "fps,frametimes")

        try store.update { settings in
            settings.graphicsBackend = .dxvk2
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .dxvk
            settings.dxvkHudFrametimes = true
        }
        let dxvk2Env = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            )
        )
        precondition(dxvk2Env["CYDER_GRAPHICS_BACKEND"] == "dxvk2")
        precondition(dxvk2Env["DXVK_FRAME_RATE"] == "60")
        precondition(dxvk2Env["DXVK_HUD"] == "fps,frametimes")

        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk2, hasD3DMetal: true, hasDxvk: true, hasDxvk2: false, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk2, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            ) == .dxvk2
        )
        precondition(CyderSettings.sanitizedGraphicsBackend("dxvk2") == .dxvk2)
        precondition(CyderSettings.resolvedGraphicsHud(preference: .dxvk2, requested: .dxvk) == .dxvk)
        precondition(CyderSettings.resolvedGraphicsHud(preference: .wined3d, requested: .dxvk) == .off)

        try store.update { settings in
            settings.graphicsBackend = .dxmt
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let dxmtEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            )
        )
        precondition(dxmtEnv["CYDER_GRAPHICS_BACKEND"] == "dxmt")
        precondition(dxmtEnv["DXVK_FRAME_RATE"] == nil)
        precondition(dxmtEnv["DXVK_HUD"] == "0")
        precondition(dxmtEnv["MTL_HUD_ENABLED"] == nil)

        try store.update { settings in
            settings.graphicsBackend = .default
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let defaultEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            )
        )
        precondition(defaultEnv["CYDER_GRAPHICS_BACKEND"] == nil)
        precondition(defaultEnv["DXVK_FRAME_RATE"] == nil)
        precondition(defaultEnv["DXVK_HUD"] == "0")
        precondition(defaultEnv["MTL_HUD_ENABLED"] == nil)

        // No cascade: `default` never resolves to a concrete backend regardless
        // of what capabilities are available.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            ) == .dxvk
        )
        // DXMT fails closed without the payload, even on a qualifying OS.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: false, osMajorVersion: 15
            ) == nil
        )
        // DXMT fails closed below macOS 15, even with the payload present.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true, osMajorVersion: 14
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxvk2: true, hasDxmt: true, osMajorVersion: 15
            ) == .dxmt
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .d3dmetal, hasD3DMetal: false, hasDxvk: false, hasDxvk2: false, hasDxmt: false
            ) == .d3dmetal
        )
        precondition(CyderSettings.sanitizedGraphicsBackend("auto") == .default)
        precondition(CyderSettings.sanitizedGraphicsBackend(nil) == .default)
        precondition(CyderSettings.sanitizedGraphicsBackend("dxmt") == .dxmt)
        precondition(CyderSettings.sanitizedOptionalGraphicsBackend("auto") == .default)
        precondition(CyderSettings.sanitizedOptionalGraphicsBackend("dxmt") == .dxmt)
        precondition(CyderSettings.sanitizedOptionalGraphicsBackend(nil) == nil)

        // hasDxmtPayload mirrors hasDxvkPayload's path resolution / defaulting.
        let payloadTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyder-dxmt-payload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: payloadTmp) }
        precondition(!CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: payloadTmp))
        let dxmtWindows = payloadTmp.appendingPathComponent("lib/dxmt/x86_64-windows", isDirectory: true)
        let dxmtUnix = payloadTmp.appendingPathComponent("lib/dxmt/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: dxmtWindows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxmtUnix, withIntermediateDirectories: true)
        try Data().write(to: dxmtWindows.appendingPathComponent("d3d11.dll"))
        precondition(!CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: payloadTmp))
        try Data().write(to: dxmtUnix.appendingPathComponent("winemetal.so"))
        precondition(CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: payloadTmp))
        precondition(CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: nil))

        // hasDxvk2Payload mirrors hasDxvkPayload (d3d11 under lib/dxvk2 + MoltenVK).
        let dxvk2PayloadTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyder-dxvk2-payload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dxvk2PayloadTmp) }
        precondition(!CyderGraphicsCapabilities.hasDxvk2Payload(engineRoot: dxvk2PayloadTmp))
        let dxvk2Windows = dxvk2PayloadTmp.appendingPathComponent("lib/dxvk2/x86_64-windows", isDirectory: true)
        let moltenUnix = dxvk2PayloadTmp.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: dxvk2Windows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moltenUnix, withIntermediateDirectories: true)
        try Data().write(to: dxvk2Windows.appendingPathComponent("d3d11.dll"))
        precondition(!CyderGraphicsCapabilities.hasDxvk2Payload(engineRoot: dxvk2PayloadTmp))
        try Data().write(to: moltenUnix.appendingPathComponent("libMoltenVK.dylib"))
        precondition(CyderGraphicsCapabilities.hasDxvk2Payload(engineRoot: dxvk2PayloadTmp))
        precondition(CyderGraphicsCapabilities.hasDxvk2Payload(engineRoot: nil))

        setenv("CYDER_OEM_FLAVOR", "maplestory", 1)
        defer { unsetenv("CYDER_OEM_FLAVOR") }
        precondition(CyderProduct.isMapleStoryOEM)
        precondition(CyderProduct.defaultGraphicsBackend == .default)
        let oemDefaults = CyderSettings()
        precondition(oemDefaults.graphicsBackend == .default)
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: false, hasDxvk: true, hasDxvk2: true, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: false, hasDxvk: true, hasDxvk2: true, hasDxmt: true, osMajorVersion: 15
            ) == .dxmt
        )
        precondition(CyderSettings.sanitizedGraphicsBackend("auto") == .default)

        print("PASS cyder-settings-harness")
    }
}
