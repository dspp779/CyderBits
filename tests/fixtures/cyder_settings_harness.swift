import Foundation

@main
struct CyderSettingsHarness {
    static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = CyderSettingsStore(url: path)
        let profileID = "profile-0123456789abcdef01234567"
        precondition(store.value.schemaVersion == 6)
        precondition(store.value.graphicsBackend == .default)
        precondition(store.value.dxvkFrameRate == .sixty)
        precondition(store.value.graphicsHud == .off)
        precondition(store.value.dxvkHudFrametimes)
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
        precondition(reloaded.value.schemaVersion == 6)
        precondition(reloaded.value.revision == 1)

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
            settings.graphicsBackend = .auto
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .metal
        }
        let autoEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(hasD3DMetal: false, hasDxvk: true)
        )
        precondition(autoEnv["CYDER_GRAPHICS_BACKEND"] == "dxvk")
        precondition(autoEnv["DXVK_FRAME_RATE"] == nil)
        precondition(autoEnv["MTL_HUD_ENABLED"] == "1")
        precondition(autoEnv["DXVK_HUD"] == "0")

        try store.update { settings in
            settings.graphicsBackend = .default
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let defaultEnv = store.environment(profileID: nil, legacyBasename: nil)
        precondition(defaultEnv["CYDER_GRAPHICS_BACKEND"] == nil)
        precondition(defaultEnv["DXVK_FRAME_RATE"] == nil)
        precondition(defaultEnv["DXVK_HUD"] == "0")
        precondition(defaultEnv["MTL_HUD_ENABLED"] == nil)

        // Cascade resolution is pure App-side preference → concrete backend.
        precondition(
            CyderSettings.cascadePreferredBackend(hasD3DMetal: true, hasDxvk: true) == .d3dmetal
        )
        precondition(
            CyderSettings.cascadePreferredBackend(hasD3DMetal: false, hasDxvk: true) == .dxvk
        )
        precondition(
            CyderSettings.cascadePreferredBackend(hasD3DMetal: false, hasDxvk: false) == .wined3d
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .auto, hasD3DMetal: false, hasDxvk: true
            ) == .dxvk
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: true, hasDxvk: true
            ) == nil
        )
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .dxvk, hasD3DMetal: true, hasDxvk: true
            ) == .dxvk
        )

        try store.update { settings in
            settings.graphicsBackend = .auto
            settings.dxvkFrameRate = .sixty
            settings.graphicsHud = .off
        }
        let autoDxvkEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(hasD3DMetal: false, hasDxvk: true)
        )
        precondition(autoDxvkEnv["CYDER_GRAPHICS_BACKEND"] == "dxvk")
        // Auto cascade to DXVK must not expose the manual frame-rate limiter.
        precondition(autoDxvkEnv["DXVK_FRAME_RATE"] == nil)
        let autoMetalEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(hasD3DMetal: true, hasDxvk: true)
        )
        precondition(autoMetalEnv["CYDER_GRAPHICS_BACKEND"] == "d3dmetal")
        precondition(autoMetalEnv["DXVK_FRAME_RATE"] == nil)

        setenv("CYDER_OEM_FLAVOR", "maplestory", 1)
        defer { unsetenv("CYDER_OEM_FLAVOR") }
        precondition(CyderProduct.isMapleStoryOEM)
        precondition(CyderProduct.defaultGraphicsBackend == .auto)
        let oemDefaults = CyderSettings()
        precondition(oemDefaults.graphicsBackend == .auto)
        let oemResolved = CyderSettings.resolveGraphics(
            global: oemDefaults,
            profile: CyderExecutableSettings(graphicsBackend: .default)
        )
        precondition(oemResolved.backend == .auto)
        // OEM never leaves graphics to CompatDB: default/auto always inject a concrete backend.
        precondition(
            CyderSettings.effectiveLaunchBackend(
                preference: .default, hasD3DMetal: false, hasDxvk: true
            ) == .dxvk
        )
        try store.update { settings in
            settings.graphicsBackend = .auto
            settings.dxvkFrameRate = .sixty
        }
        let oemEnv = store.environment(
            profileID: nil,
            legacyBasename: nil,
            capabilities: CyderGraphicsCapabilities(hasD3DMetal: false, hasDxvk: true)
        )
        precondition(oemEnv["CYDER_GRAPHICS_BACKEND"] == "dxvk")
        precondition(oemEnv["DXVK_FRAME_RATE"] == "60")

        print("PASS cyder-settings-harness")
    }
}
