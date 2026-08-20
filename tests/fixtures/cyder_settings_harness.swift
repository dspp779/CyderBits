import Foundation

@main
struct CyderSettingsHarness {
    static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = CyderSettingsStore(url: path)
        let profileID = "profile-0123456789abcdef01234567"
        precondition(store.value.schemaVersion == 12)
        precondition(store.value.graphicsBackend == .default)
        precondition(store.value.dxvkFrameRate == .sixty)
        precondition(store.value.graphicsHud == .off)
        precondition(store.value.dxvkHudFrametimes)
        precondition(store.value.wineDiagnostics == .quiet)
        precondition(store.value.maplestoryWZCache)
        precondition(store.value.wineLocale == .system)
        precondition(store.environment["CYDER_WINE_DIAGNOSTICS"] == "quiet")
        precondition(store.environment["CYDER_WINE_LOCALE"] == "system")
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
            settings.maplestoryWZCache = false
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
        let updatedAt = saved["updatedAt"] as? String
        precondition(updatedAt?.isEmpty == false)
        let lastModified = saved["lastModified"] as! [String: String]
        precondition(lastModified["global.dpi"] == updatedAt)
        precondition(lastModified["global.msync"] == updatedAt)
        precondition(lastModified["global.maplestoryWZCache"] == updatedAt)
        precondition(lastModified["executable:game.exe"] == updatedAt)
        let profiles = saved["perProfile"] as! [String: Any]
        precondition(profiles["not-a-profile"] == nil)
        let profile = profiles[profileID] as! [String: Any]
        let environment = profile["environment"] as! [String: Any]
        precondition(environment["NOT VALID"] == nil)
        let reloaded = CyderSettingsStore(url: path)
        precondition(reloaded.value.schemaVersion == 12)
        precondition(!reloaded.value.maplestoryWZCache)
        precondition(reloaded.value.revision == 1)

        try store.update { settings in
            settings.wineDiagnostics = .errors
            settings.wineLocale = .zhTW
        }
        precondition(store.environment["CYDER_WINE_DIAGNOSTICS"] == "errors")
        precondition(store.environment["CYDER_WINE_LOCALE"] == "zh_TW.UTF-8")
        precondition(CyderSettings.sanitizedWineLocale("ja_JP") == .jaJP)
        precondition(CyderSettings.sanitizedWineLocale("bogus") == .system)
        precondition(CyderWineDiagnostics.errors.wineDebug == "-all,err+all,+timestamp,+pid,+tid")
        precondition(CyderWineDiagnostics.sync.wineDebug == "-all,err+all,+timestamp,+pid,+tid,+sync")
        precondition(CyderWineDiagnostics.unwind.wineDebug == "-all,+timestamp,+pid,+tid,+seh,+unwind")
        precondition(CyderSettings.isValidEnvironmentKey("GAME_TOKEN"))
        precondition(!CyderSettings.isValidEnvironmentKey("WINEPREFIX"))
        precondition(!CyderSettings.isValidEnvironmentKey("WINEDEBUG"))
        precondition(!CyderSettings.isValidEnvironmentKey("DYLD_INSERT_LIBRARIES"))
        precondition(!CyderSettings.isValidEnvironmentKey("CYDER_WINE_RESULT_FILE"))
        precondition(!CyderSettings.isValidEnvironmentKey("CYDER_GRAPHICS_HUD_PREFERENCE"))
        precondition(CyderSettings.isValidEnvironmentKey("CYDER_GRAPHICS_BACKEND_PATH"))

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
            settings.dxvkFrameRate = .oneTwenty
        }
        let dxvk120Env = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxvk120Env["DXVK_FRAME_RATE"] == "120")

        try store.update { settings in
            settings.dxvkFrameRate = .oneFortyFour
        }
        let dxvk144Env = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxvk144Env["DXVK_FRAME_RATE"] == "144")
        precondition(CyderSettings.sanitizedDxvkFrameRate("sixty") == .sixty)
        precondition(CyderSettings.sanitizedDxvkFrameRate("120") == .oneTwenty)
        precondition(CyderSettings.sanitizedDxvkFrameRate("144") == .oneFortyFour)
        precondition(CyderDxvkFrameRate.sixty.fpsValue == "60")
        precondition(CyderDxvkFrameRate.unlimited.fpsValue == nil)

        precondition(CyderSettings.sanitizedGraphicsBackend("dxvk2") == .default)
        precondition(CyderSettings.resolvedGraphicsHud(preference: .wined3d, requested: .dxvk) == .off)

        // Decode of a legacy DXVK 2 setting migrates to the safe default backend.
        let legacyDxvk2JSON = Data("""
        {
          "schemaVersion": 9,
          "graphicsBackend": "dxvk2",
          "graphicsHud": "dxvk"
        }
        """.utf8)
        let decodedLegacyDxvk2 = try JSONDecoder().decode(CyderSettings.self, from: legacyDxvk2JSON)
        precondition(decodedLegacyDxvk2.graphicsBackend == .default)
        precondition(decodedLegacyDxvk2.graphicsHud == .off)

        try store.update { settings in
            settings.graphicsBackend = .dxmt
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let dxmtEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxmtEnv["CYDER_GRAPHICS_BACKEND"] == "dxmt")
        precondition(dxmtEnv["DXVK_FRAME_RATE"] == nil)
        precondition(dxmtEnv["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60;")
        precondition(dxmtEnv["DXVK_HUD"] == "0")
        precondition(dxmtEnv["MTL_HUD_ENABLED"] == nil)

        try store.update { settings in
            settings.dxvkFrameRate = .oneTwenty
        }
        let dxmt120Env = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxmt120Env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=120;")
        precondition(dxmt120Env["DXVK_FRAME_RATE"] == nil)

        try store.update { settings in
            settings.dxvkFrameRate = .unlimited
        }
        let dxmtUnlimitedEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            override: CyderExecutableSettings(
                environment: ["DXMT_CONFIG": "dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=30;"]
            ),
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxmtUnlimitedEnv["DXMT_CONFIG"] == "dxgi.forceSDR=True;")

        try store.update { settings in
            settings.dxvkFrameRate = .sixty
        }
        let dxmtMergedEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            override: CyderExecutableSettings(
                environment: ["DXMT_CONFIG": "dxgi.forceSDR=True;"]
            ),
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(dxmtMergedEnv["DXMT_CONFIG"] == "dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=60;")

        try store.update { settings in
            settings.graphicsBackend = .default
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let defaultEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: true, hasDxvk: true, hasDxmt: true
            )
        )
        precondition(defaultEnv["CYDER_GRAPHICS_BACKEND"] == nil)
        precondition(defaultEnv["DXVK_FRAME_RATE"] == nil)
        precondition(defaultEnv["DXVK_HUD"] == "0")
        precondition(defaultEnv["MTL_HUD_ENABLED"] == nil)

        // General `default` still defers to CompatDB, while the two MapleStory
        // executables use the platform policy when their basename is known.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true, hasDxmt: true,
                osMajorVersion: 15, executableBasename: "MapleStory.exe"
            ) == .dxmt
        )
        let mapleAutoEnvironment = store.environment(
            profileID: nil,
            legacyBasename: "MapleStory.exe",
            capabilities: CyderGraphicsCapabilities(
                hasD3DMetal: true, hasDxvk: true, hasDxmt: true
            )
        )
        // The real host version is not stubbed in this harness; the explicit
        // resolver checks above cover both OS branches. This assertion only
        // verifies that an executable-specific backend, when resolved, drives
        // the same frame-limiter path as a manual backend.
        precondition(mapleAutoEnvironment["DXVK_FRAME_RATE"] == nil)
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true, hasDxmt: true,
                osMajorVersion: 14, executableBasename: "MAPLESTORY_CLASSIC.EXE"
            ) == .dxvk
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true, hasDxmt: true,
                osMajorVersion: 15, executableBasename: "OtherGame.exe"
            ) == nil
        )
        precondition(CyderSettings.isMapleStoryGraphicsExecutable("C:\\Games\\Maplestory_Classic.exe"))
        precondition(!CyderSettings.isMapleStoryGraphicsExecutable("C:\\Games\\OtherGame.exe"))
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk, hasD3DMetal: true, hasDxvk: true, hasDxmt: true
            ) == .dxvk
        )
        // DXMT fails closed without the payload, even on a qualifying OS.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxmt: false, osMajorVersion: 15
            ) == nil
        )
        // DXMT fails closed below macOS 15, even with the payload present.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxmt: true, osMajorVersion: 14
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: true, hasDxvk: true, hasDxmt: true, osMajorVersion: 15
            ) == .dxmt
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .d3dmetal, hasD3DMetal: false, hasDxvk: false, hasDxmt: false
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk, hasD3DMetal: false, hasDxvk: false, hasDxmt: false
            ) == nil
        )
        precondition(
            CyderSettings.coercedGraphicsBackend(
                .dxmt,
                capabilities: CyderGraphicsCapabilities(
                    hasD3DMetal: false, hasDxvk: true, hasDxmt: true
                ),
                osMajorVersion: 12
            ) == .default
        )
        precondition(
            CyderSettings.coercedOptionalGraphicsBackend(
                .dxmt,
                capabilities: CyderGraphicsCapabilities(
                    hasD3DMetal: false, hasDxvk: true, hasDxmt: true
                ),
                osMajorVersion: 12
            ) == nil
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
        let dxmtWindows32 = payloadTmp.appendingPathComponent("lib/dxmt/i386-windows", isDirectory: true)
        let dxmtUnix = payloadTmp.appendingPathComponent("lib/dxmt/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: dxmtWindows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxmtWindows32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxmtUnix, withIntermediateDirectories: true)
        try Data().write(to: dxmtWindows.appendingPathComponent("d3d11.dll"))
        try Data().write(to: dxmtWindows.appendingPathComponent("dxgi.dll"))
        try Data().write(to: dxmtWindows.appendingPathComponent("winemetal.dll"))
        try Data().write(to: dxmtWindows32.appendingPathComponent("d3d11.dll"))
        try Data().write(to: dxmtWindows32.appendingPathComponent("dxgi.dll"))
        try Data().write(to: dxmtWindows32.appendingPathComponent("winemetal.dll"))
        precondition(!CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: payloadTmp))
        try Data().write(to: dxmtUnix.appendingPathComponent("winemetal.so"))
        precondition(CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: payloadTmp))
        precondition(CyderGraphicsCapabilities.hasDxmtPayload(engineRoot: nil))

        precondition(CyderProduct.defaultGraphicsBackend == .default)
        let oemDefaults = CyderSettings()
        precondition(oemDefaults.graphicsBackend == .default)
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: false, hasDxvk: true, hasDxmt: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxmt, hasD3DMetal: false, hasDxvk: true, hasDxmt: true, osMajorVersion: 15
            ) == .dxmt
        )
        precondition(CyderSettings.sanitizedGraphicsBackend("auto") == .default)

        print("PASS cyder-settings-harness")
    }
}
