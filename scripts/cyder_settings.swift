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

    init() {}

    init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        msync: Bool? = nil,
        esync: Bool? = nil,
        retinaMode: Bool? = nil,
        dpi: Int? = nil,
        fontPreset: String? = nil,
        fontSmoothing: String? = nil,
        powerMode: String? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.msync = msync
        self.esync = esync
        self.retinaMode = retinaMode
        self.dpi = dpi
        self.fontPreset = fontPreset
        self.fontSmoothing = fontSmoothing
        self.powerMode = powerMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync)
        esync = try values.decodeIfPresent(Bool.self, forKey: .esync)
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode)
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi)
        fontPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset)
        fontSmoothing = try values.decodeIfPresent(String.self, forKey: .fontSmoothing)
        powerMode = try values.decodeIfPresent(String.self, forKey: .powerMode)
    }
}

struct CyderSettings: Codable {
    // Schema 3 adds profile-keyed overrides. Keep perExecutable as a legacy
    // basename fallback; never infer a profile from a basename.
    var schemaVersion = 3
    var revision = 0
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontPreset = "songti"
    var fontSmoothing = "grayscale"
    var perExecutable: [String: CyderExecutableSettings] = [:]
    var perProfile: [String: CyderExecutableSettings] = [:]

    static let defaults = CyderSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 3 else { throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion, in: values, debugDescription: "unsupported settings schema \(version)"
        ) }
        schemaVersion = 3
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync) ?? false
        esync = try values.decodeIfPresent(Bool?.self, forKey: .esync) ?? false
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi) ?? 192
        fontPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset) ?? "songti"
        fontSmoothing = try values.decodeIfPresent(String.self, forKey: .fontSmoothing) ?? "grayscale"
        perExecutable = try values.decodeIfPresent([String: CyderExecutableSettings].self, forKey: .perExecutable) ?? [:]
        let decodedProfiles = try values.decodeIfPresent([String: CyderExecutableSettings].self, forKey: .perProfile) ?? [:]
        perProfile = decodedProfiles.reduce(into: [:]) { result, item in
            guard Self.isValidProfileID(item.key) else { return }
            result[item.key] = Self.sanitized(item.value)
        }
        perExecutable = perExecutable.reduce(into: [:]) { result, item in
            result[item.key] = Self.sanitized(item.value)
        }
        dpi = min(480, max(72, dpi))
        if !["songti", "mingliu"].contains(fontPreset) { fontPreset = "songti" }
        if !["off", "grayscale", "cleartype-rgb", "cleartype-bgr"].contains(fontSmoothing) {
            fontSmoothing = "grayscale"
        }
    }

    static func isValidProfileID(_ value: String) -> Bool {
        value.range(of: "^profile-[0-9a-f]{24}$", options: .regularExpression) != nil
    }

    static func isValidEnvironmentKey(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    // Values are passed to Process.environment/arguments, never evaluated as
    // shell syntax. Reject control characters that could corrupt logs or
    // bridge files while preserving spaces, Unicode, quotes and punctuation.
    static func isSafeLaunchValue(_ value: String) -> Bool {
        guard value.utf8.count <= 4096 else { return false }
        return !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }

    static func sanitized(_ value: CyderExecutableSettings) -> CyderExecutableSettings {
        var result = value
        result.environment = value.environment.filter {
            isValidEnvironmentKey($0.key) && isSafeLaunchValue($0.value)
        }
        result.arguments = value.arguments.filter { isSafeLaunchValue($0) }
        if let dpi = value.dpi { result.dpi = min(480, max(72, dpi)) }
        if let preset = value.fontPreset, !["songti", "mingliu"].contains(preset) {
            result.fontPreset = nil
        }
        if let smoothing = value.fontSmoothing,
           !["off", "grayscale", "cleartype-rgb", "cleartype-bgr"].contains(smoothing) {
            result.fontSmoothing = nil
        }
        if let powerMode = value.powerMode,
           !["standard", "energySaving"].contains(powerMode) {
            result.powerMode = nil
        }
        return result
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
            guard decoded.schemaVersion <= 3 else {
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
        next.schemaVersion = 3
        next.perProfile = next.perProfile.reduce(into: [:]) { result, item in
            guard CyderSettings.isValidProfileID(item.key) else { return }
            result[item.key] = CyderSettings.sanitized(item.value)
        }
        next.perExecutable = next.perExecutable.reduce(into: [:]) { result, item in
            result[item.key] = CyderSettings.sanitized(item.value)
        }
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
        environment(profileID: nil, legacyBasename: basename)
    }

    func environment(profileID: String?, legacyBasename: String?) -> [String: String] {
        var result = environment
        let rule: CyderExecutableSettings?
        if let profileID {
            rule = value.perProfile[profileID]
        } else {
            rule = legacyBasename.flatMap { value.perExecutable[$0] }
        }
        guard let rule else { return result }
        if let v = rule.msync { result["CYDER_MSYNC"] = v ? "1" : "0" }
        if let v = rule.esync { result["CYDER_ESYNC"] = v ? "1" : "0" }
        if let v = rule.retinaMode { result["CYDER_RETINA_MODE"] = v ? "1" : "0" }
        if let v = rule.dpi { result["CYDER_DPI"] = String(min(480, max(72, v))) }
        if let v = rule.fontPreset { result["CYDER_FONT_PRESET"] = v }
        if let v = rule.fontSmoothing { result["CYDER_FONT_SMOOTHING"] = v }
        if let v = rule.powerMode { result["CYDER_POWER_MODE"] = v == "energySaving" ? "background" : "normal" }
        result.merge(rule.environment.filter { CyderSettings.isValidEnvironmentKey($0.key) }) { _, override in override }
        return result
    }

    func arguments(forExecutable basename: String) -> [String] {
        arguments(profileID: nil, legacyBasename: basename)
    }

    func hasSettings(forExecutable basename: String) -> Bool {
        value.perExecutable[basename] != nil
    }

    func arguments(profileID: String?, legacyBasename: String?) -> [String] {
        let rule: CyderExecutableSettings?
        if let profileID {
            rule = value.perProfile[profileID]
        } else {
            rule = legacyBasename.flatMap { value.perExecutable[$0] }
        }
        return rule?.arguments ?? []
    }

    func hasSettings(profileID: String?, legacyBasename: String?) -> Bool {
        if let profileID, value.perProfile[profileID] != nil { return true }
        if profileID == nil, let legacyBasename, value.perExecutable[legacyBasename] != nil { return true }
        return false
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
