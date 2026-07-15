import Foundation

@main
struct CyderSettingsHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyder-settings-harness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CyderSettingsStore(url: root.appendingPathComponent("settings.json"))
        precondition(store.value.schemaVersion == 2)
        precondition(store.environment["CYDER_DPI"] == "192")

        try store.update {
            $0.dpi = 144
            $0.msync = true
            $0.perExecutable["game.exe"] = CyderExecutableSettings(
                arguments: ["--windowed"],
                environment: ["GAME_PROFILE": "test"],
                msync: false,
                esync: true,
                retinaMode: false,
                dpi: 96,
                fontPreset: nil,
                fontSmoothing: nil,
                powerMode: "energySaving"
            )
        }

        let environment = store.environment(forExecutable: "game.exe")
        precondition(environment["CYDER_DPI"] == "96")
        precondition(environment["CYDER_MSYNC"] == "0")
        precondition(environment["CYDER_POWER_MODE"] == "background")
        precondition(environment["GAME_PROFILE"] == "test")
        precondition(store.arguments(forExecutable: "game.exe") == ["--windowed"])

        let reloaded = CyderSettingsStore(url: root.appendingPathComponent("settings.json"))
        precondition(reloaded.value.revision == 1)
        print("PASS cyder-settings-harness")
    }
}
