import Foundation
import CoreText

/// True when the Mac already has a MingLiU / 細明體 family the user can select.
func cyderSystemProvidesMingLiU() -> Bool {
    let markers: Set<String> = [
        "MingLiU", "PMingLiU", "MingLiU-ExtB", "MingLiU_HKSCS",
        "細明體", "新細明體",
    ]
    if let postscript = CTFontManagerCopyAvailablePostScriptNames() as? [String] {
        for name in postscript where markers.contains(name) {
            return true
        }
    }
    if let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] {
        for name in families where markers.contains(name) {
            return true
        }
    }
    let fontDirs = [
        "\(NSHomeDirectory())/Library/Fonts",
        "/Library/Fonts",
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
    ]
    let fileMarkers = ["mingliu", "pmingliu", "細明體", "新細明體"]
    let fm = FileManager.default
    for dir in fontDirs {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for item in items {
            let lower = item.lowercased()
            if fileMarkers.contains(where: { lower.contains($0.lowercased()) }) {
                return true
            }
        }
    }
    return false
}

/// Prefer MingLiU when present; otherwise Songti TC (always available on macOS).
func cyderDefaultFontPreset() -> String {
    cyderSystemProvidesMingLiU() ? "mingliu" : "songti"
}

enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`, wined3d, dxvk, d3dmetal
}

enum CyderDxvkFrameRate: String, Codable, CaseIterable {
    case sixty = "60"
    case unlimited
}

struct CyderResolvedGraphics {
    var backend: CyderGraphicsBackend
    var dxvkFrameRate: CyderDxvkFrameRate
}

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
    var graphicsBackend: CyderGraphicsBackend?
    var dxvkFrameRate: CyderDxvkFrameRate?

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
        powerMode: String? = nil,
        graphicsBackend: CyderGraphicsBackend? = nil,
        dxvkFrameRate: CyderDxvkFrameRate? = nil
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
        self.graphicsBackend = graphicsBackend
        self.dxvkFrameRate = dxvkFrameRate
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
        graphicsBackend = CyderSettings.sanitizedOptionalGraphicsBackend(
            try values.decodeIfPresent(String.self, forKey: .graphicsBackend)
        )
        dxvkFrameRate = CyderSettings.sanitizedOptionalDxvkFrameRate(
            try values.decodeIfPresent(String.self, forKey: .dxvkFrameRate)
        )
    }
}

struct CyderSettings: Codable {
    // Schema 4 adds graphics backend and DXVK frame rate. Schema 3 adds
    // profile-keyed overrides. Keep perExecutable as a legacy basename fallback;
    // never infer a profile from a basename.
    var schemaVersion = 4
    var revision = 0
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontPreset = cyderDefaultFontPreset()
    var fontSmoothing = "cleartype-rgb"
    var graphicsBackend: CyderGraphicsBackend = .default
    var dxvkFrameRate: CyderDxvkFrameRate = .sixty
    var perExecutable: [String: CyderExecutableSettings] = [:]
    var perProfile: [String: CyderExecutableSettings] = [:]

    static let defaults = CyderSettings()

    init() {
        fontPreset = cyderDefaultFontPreset()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 4 else { throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion, in: values, debugDescription: "unsupported settings schema \(version)"
        ) }
        schemaVersion = 4
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync) ?? false
        esync = try values.decodeIfPresent(Bool?.self, forKey: .esync) ?? false
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi) ?? 192
        fontPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset) ?? cyderDefaultFontPreset()
        fontSmoothing = try values.decodeIfPresent(String.self, forKey: .fontSmoothing) ?? "cleartype-rgb"
        graphicsBackend = Self.sanitizedGraphicsBackend(
            try values.decodeIfPresent(String.self, forKey: .graphicsBackend)
        )
        dxvkFrameRate = Self.sanitizedDxvkFrameRate(
            try values.decodeIfPresent(String.self, forKey: .dxvkFrameRate)
        )
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
            fontSmoothing = "cleartype-rgb"
        }
    }

    static func sanitizedGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend {
        guard let raw, let value = CyderGraphicsBackend(rawValue: raw) else { return .default }
        return value
    }

    static func sanitizedDxvkFrameRate(_ raw: String?) -> CyderDxvkFrameRate {
        guard let raw, let value = CyderDxvkFrameRate(rawValue: raw) else { return .sixty }
        return value
    }

    static func sanitizedOptionalGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend? {
        guard let raw else { return nil }
        return CyderGraphicsBackend(rawValue: raw)
    }

    static func sanitizedOptionalDxvkFrameRate(_ raw: String?) -> CyderDxvkFrameRate? {
        guard let raw else { return nil }
        return CyderDxvkFrameRate(rawValue: raw)
    }

    static func resolveGraphics(
        global: CyderSettings,
        profile: CyderExecutableSettings?
    ) -> CyderResolvedGraphics {
        CyderResolvedGraphics(
            backend: profile?.graphicsBackend ?? global.graphicsBackend,
            dxvkFrameRate: profile?.dxvkFrameRate ?? global.dxvkFrameRate
        )
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
        if let backend = value.graphicsBackend,
           !CyderGraphicsBackend.allCases.contains(backend) {
            result.graphicsBackend = nil
        }
        if let frameRate = value.dxvkFrameRate,
           !CyderDxvkFrameRate.allCases.contains(frameRate) {
            result.dxvkFrameRate = nil
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
            guard decoded.schemaVersion <= 4 else {
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
        next.schemaVersion = 4
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

    func environment(
        profileID: String?,
        legacyBasename: String?,
        override: CyderExecutableSettings? = nil
    ) -> [String: String] {
        var result = environment
        let rule = override ?? executableSettings(profileID: profileID, legacyBasename: legacyBasename)
        let graphics = CyderSettings.resolveGraphics(global: value, profile: rule)
        if graphics.backend != .default {
            result["CYDER_GRAPHICS_BACKEND"] = graphics.backend.rawValue
        }
        if graphics.backend == .dxvk, graphics.dxvkFrameRate == .sixty {
            result["DXVK_FRAME_RATE"] = "60"
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

    func arguments(
        profileID: String?,
        legacyBasename: String?,
        override: CyderExecutableSettings? = nil
    ) -> [String] {
        (override ?? executableSettings(profileID: profileID, legacyBasename: legacyBasename))?.arguments ?? []
    }

    func executableSettings(profileID: String?, legacyBasename: String?) -> CyderExecutableSettings? {
        if let profileID { return value.perProfile[profileID] }
        if let legacyBasename { return value.perExecutable[legacyBasename] }
        return nil
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
