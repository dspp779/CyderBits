import Foundation

struct CyderExecutableSettings: Codable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var msync: Bool?
    var esync: Bool?
    var retinaMode: Bool?
    var dpi: Int?
    var fontPreset: String?
    var fontSmoothing: String?
    var powerMode: String?
}

struct CyderSettings: Codable {
    // Schema 2 adds a revision and per-executable overrides. Keep the global
    // fields flat so schema 1 files remain readable by older launchers.
    var schemaVersion = 2
    var revision = 0
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontPreset = "songti"
    var fontSmoothing = "grayscale"
    var perExecutable: [String: CyderExecutableSettings] = [:]

    static let defaults = CyderSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 2 else { throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion, in: values, debugDescription: "unsupported settings schema \(version)"
        ) }
        schemaVersion = 2
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync) ?? false
        esync = try values.decodeIfPresent(Bool?.self, forKey: .esync) ?? false
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi) ?? 192
        fontPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset) ?? "songti"
        fontSmoothing = try values.decodeIfPresent(String.self, forKey: .fontSmoothing) ?? "grayscale"
        perExecutable = try values.decodeIfPresent([String: CyderExecutableSettings].self, forKey: .perExecutable) ?? [:]
    }
}

final class CyderSettingsStore {
    static let shared = CyderSettingsStore()
    private(set) var value: CyderSettings
    private let url: URL

    init(url: URL = CyderPaths.support.appendingPathComponent("settings.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            value = .defaults
            return
        }
        CyderDiagnostics.shared.enter(.settingsLoad)
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(CyderSettings.self, from: data)
            guard decoded.schemaVersion <= 2 else {
                CyderDiagnostics.shared.warning("unsupported settings schema=\(decoded.schemaVersion); using defaults")
                value = .defaults
                return
            }
            value = decoded
        } catch {
            CyderDiagnostics.shared.warning("unable to read settings; using defaults error=\(error)")
            value = .defaults
        }
    }

    func update(_ work: (inout CyderSettings) -> Void) throws {
        CyderDiagnostics.shared.enter(.settingsSave)
        var next = value
        work(&next)
        next.schemaVersion = 2
        next.revision = max(value.revision + 1, next.revision)
        next.dpi = min(480, max(72, next.dpi))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(next)
        try data.write(to: url, options: .atomic)
        value = next
    }

    func reset() throws { try update { $0 = .defaults } }

    var environment: [String: String] {
        [
            "CYDER_MSYNC": value.msync ? "1" : "0",
            "CYDER_ESYNC": (value.esync ?? false) ? "1" : "0",
            "CYDER_RETINA_MODE": value.retinaMode ? "1" : "0",
            "CYDER_DPI": String(value.dpi),
            "CYDER_FONT_PRESET": value.fontPreset,
            "CYDER_FONT_SMOOTHING": value.fontSmoothing,
            "CYDER_POWER_MODE": "normal",
        ]
    }

    func environment(forExecutable basename: String) -> [String: String] {
        var result = environment
        guard let rule = value.perExecutable[basename] else { return result }
        if let v = rule.msync { result["CYDER_MSYNC"] = v ? "1" : "0" }
        if let v = rule.esync { result["CYDER_ESYNC"] = v ? "1" : "0" }
        if let v = rule.retinaMode { result["CYDER_RETINA_MODE"] = v ? "1" : "0" }
        if let v = rule.dpi { result["CYDER_DPI"] = String(min(480, max(72, v))) }
        if let v = rule.fontPreset { result["CYDER_FONT_PRESET"] = v }
        if let v = rule.fontSmoothing { result["CYDER_FONT_SMOOTHING"] = v }
        if let v = rule.powerMode { result["CYDER_POWER_MODE"] = v == "energySaving" ? "background" : "normal" }
        result.merge(rule.environment) { _, override in override }
        return result
    }

    func arguments(forExecutable basename: String) -> [String] {
        value.perExecutable[basename]?.arguments ?? []
    }

    func hasSettings(forExecutable basename: String) -> Bool {
        value.perExecutable[basename] != nil
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
