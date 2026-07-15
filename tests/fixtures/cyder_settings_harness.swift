import Foundation

@main
struct CyderSettingsHarness {
    static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = CyderSettingsStore(url: path)
        let profileID = "profile-0123456789abcdef01234567"
        precondition(store.value.schemaVersion == 3)
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
        precondition(reloaded.value.schemaVersion == 3)
        precondition(reloaded.value.revision == 1)
        print("PASS cyder-settings-harness")
    }
}
