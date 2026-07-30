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

enum CyderProduct {
    /// MapleStory OEM ships a dedicated App wrapper that exports this flavor.
    static var isMapleStoryOEM: Bool {
        ProcessInfo.processInfo.environment["CYDER_OEM_FLAVOR"] == "maplestory"
    }

    /// Official builds follow CompatDB when unset; OEM uses App-side auto cascade.
    static var defaultGraphicsBackend: CyderGraphicsBackend {
        isMapleStoryOEM ? .auto : .default
    }
}

enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`
    /// App-side cascade: d3dmetal → dxvk → wined3d (CompatDB is not consulted).
    case auto
    case wined3d, dxvk, d3dmetal
}

enum CyderDxvkFrameRate: String, Codable, CaseIterable {
    case sixty = "60"
    case unlimited
}

/// Global-only smoothness overlay. Default is off.
enum CyderGraphicsHud: String, Codable, CaseIterable {
    case off
    case metal
    case dxvk
}

/// Wine trace volume for normal game launches. Keep the default silent because
/// high-volume unwind/SEH tracing can materially change timing-sensitive games.
enum CyderWineDiagnostics: String, Codable, CaseIterable {
    case quiet
    case errors
    case unwind

    var wineDebug: String {
        switch self {
        case .quiet:
            return "-all"
        case .errors:
            return "-all,err+all,+timestamp,+pid,+tid"
        case .unwind:
            return "-all,+timestamp,+pid,+tid,+seh,+unwind"
        }
    }
}

struct CyderGraphicsCapabilities: Equatable {
    var hasD3DMetal: Bool
    var hasDxvk: Bool

    /// Probe local GPTK / DXVK availability. When `engineRoot` is nil, DXVK is
    /// assumed present (0.8 engines ship it); launch paths should pass the real root.
    static func current(engineRoot: URL? = nil) -> CyderGraphicsCapabilities {
        let osOK = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        let hasGptk = CyderGptk.preferredSource() != nil
        return CyderGraphicsCapabilities(
            hasD3DMetal: osOK && hasGptk,
            hasDxvk: hasDxvkPayload(engineRoot: engineRoot)
        )
    }

    static func hasDxvkPayload(engineRoot: URL?) -> Bool {
        let root: URL?
        if let engineRoot {
            root = engineRoot
        } else if let path = ProcessInfo.processInfo.environment["CYDER_GRAPHICS_BACKENDS_ROOT"],
                  !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            // Settings / prefs probes without an engine still allow cascade past d3dmetal.
            return true
        }
        guard let root else { return true }
        let manager = FileManager.default
        let dxvkDLL = root.appendingPathComponent("lib/dxvk/x86_64-windows/d3d11.dll")
        let moltenA = root.appendingPathComponent("lib/wine/x86_64-unix/libMoltenVK.dylib")
        let moltenB = root.appendingPathComponent("lib64/libMoltenVK.dylib")
        return manager.isReadableFile(atPath: dxvkDLL.path)
            && (manager.isReadableFile(atPath: moltenA.path) || manager.isReadableFile(atPath: moltenB.path))
    }
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
    // Schema 7 adds wineDiagnostics. Schema 6 adds dxvkHudFrametimes. Schema 5 adds graphicsHud.
    // Schema 4 adds graphics backend and DXVK frame rate. Schema 3 adds profile-keyed overrides. Keep perExecutable as a
    // legacy basename fallback; never infer a profile from a basename.
    var schemaVersion = 7
    var revision = 0
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontPreset = cyderDefaultFontPreset()
    var fontSmoothing = "cleartype-rgb"
    var graphicsBackend: CyderGraphicsBackend = CyderProduct.defaultGraphicsBackend
    var dxvkFrameRate: CyderDxvkFrameRate = .sixty
    var graphicsHud: CyderGraphicsHud = .off
    var dxvkHudFrametimes = true
    var wineDiagnostics: CyderWineDiagnostics = .quiet
    var perExecutable: [String: CyderExecutableSettings] = [:]
    var perProfile: [String: CyderExecutableSettings] = [:]

    static var defaults: CyderSettings { CyderSettings() }

    init() {
        fontPreset = cyderDefaultFontPreset()
        graphicsBackend = CyderProduct.defaultGraphicsBackend
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 7 else { throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion, in: values, debugDescription: "unsupported settings schema \(version)"
        ) }
        schemaVersion = 7
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
        graphicsHud = Self.sanitizedGraphicsHud(
            try values.decodeIfPresent(String.self, forKey: .graphicsHud)
        )
        dxvkHudFrametimes = try values.decodeIfPresent(Bool.self, forKey: .dxvkHudFrametimes) ?? true
        wineDiagnostics = Self.sanitizedWineDiagnostics(
            try values.decodeIfPresent(String.self, forKey: .wineDiagnostics)
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
        // DXVK HUD is only meaningful with a manual DXVK preference.
        if graphicsHud == .dxvk && graphicsBackend != .dxvk {
            graphicsHud = .off
        }
    }

    static func sanitizedGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend {
        guard let raw, let value = CyderGraphicsBackend(rawValue: raw) else {
            return CyderProduct.defaultGraphicsBackend
        }
        return value
    }

    static func sanitizedDxvkFrameRate(_ raw: String?) -> CyderDxvkFrameRate {
        guard let raw, let value = CyderDxvkFrameRate(rawValue: raw) else { return .sixty }
        return value
    }

    static func sanitizedGraphicsHud(_ raw: String?) -> CyderGraphicsHud {
        guard let raw, let value = CyderGraphicsHud(rawValue: raw) else { return .off }
        return value
    }

    static func sanitizedWineDiagnostics(_ raw: String?) -> CyderWineDiagnostics {
        guard let raw, let value = CyderWineDiagnostics(rawValue: raw) else { return .quiet }
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
        var backend = profile?.graphicsBackend ?? global.graphicsBackend
        // OEM does not use CompatDB graphics; legacy "default" means App auto cascade.
        if CyderProduct.isMapleStoryOEM && backend == .default {
            backend = .auto
        }
        return CyderResolvedGraphics(
            backend: backend,
            dxvkFrameRate: profile?.dxvkFrameRate ?? global.dxvkFrameRate
        )
    }

    /// Preference chain for `auto`: D3DMetal → DXVK → WineD3D.
    static func cascadePreferredBackend(hasD3DMetal: Bool, hasDxvk: Bool) -> CyderGraphicsBackend {
        if hasD3DMetal { return .d3dmetal }
        if hasDxvk { return .dxvk }
        return .wined3d
    }

    /// Concrete backend to inject into Wine, or `nil` to leave CompatDB alone.
    static func effectiveLaunchBackend(
        preference: CyderGraphicsBackend,
        hasD3DMetal: Bool,
        hasDxvk: Bool
    ) -> CyderGraphicsBackend? {
        switch preference {
        case .default:
            if CyderProduct.isMapleStoryOEM {
                return cascadePreferredBackend(hasD3DMetal: hasD3DMetal, hasDxvk: hasDxvk)
            }
            return nil
        case .auto:
            return cascadePreferredBackend(hasD3DMetal: hasD3DMetal, hasDxvk: hasDxvk)
        case .wined3d, .dxvk, .d3dmetal:
            return preference
        }
    }

    /// HUD choice after applying the "DXVK HUD only with manual DXVK" rule.
    static func resolvedGraphicsHud(
        preference: CyderGraphicsBackend,
        requested: CyderGraphicsHud
    ) -> CyderGraphicsHud {
        if requested == .dxvk && preference != .dxvk {
            return .off
        }
        return requested
    }

    /// Copy engine DXVK PE DLLs into the prefix system32/syswow64.
    /// Required for CrossOver OEM: `--dll native` loads from the prefix, not
    /// `lib/dxvk` alone, and builtin still wins without native overrides.
    @discardableResult
    static func provisionDxvkIntoPrefix(engineRoot: URL, prefix: URL) -> Bool {
        let manager = FileManager.default
        let moltenA = engineRoot.appendingPathComponent("lib/wine/x86_64-unix/libMoltenVK.dylib")
        let moltenB = engineRoot.appendingPathComponent("lib64/libMoltenVK.dylib")
        guard manager.isReadableFile(atPath: moltenA.path)
            || manager.isReadableFile(atPath: moltenB.path) else {
            return false
        }
        var installed = 0
        let arches: [(String, String)] = [
            ("x86_64-windows", "system32"),
            ("i386-windows", "syswow64"),
        ]
        let modules = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "dxgi"]
        for (machine, windowsDir) in arches {
            let source = engineRoot
                .appendingPathComponent("lib/dxvk/\(machine)", isDirectory: true)
            let destination = prefix
                .appendingPathComponent("drive_c/windows/\(windowsDir)", isDirectory: true)
            guard manager.fileExists(atPath: source.path) else { continue }
            do {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                return false
            }
            for module in modules {
                let src = source.appendingPathComponent("\(module).dll")
                let dst = destination.appendingPathComponent("\(module).dll")
                guard manager.isReadableFile(atPath: src.path) else { return false }
                let temp = destination.appendingPathComponent(".\(module).dll.cyder-new")
                do {
                    if manager.fileExists(atPath: temp.path) {
                        try manager.removeItem(at: temp)
                    }
                    try manager.copyItem(at: src, to: temp)
                    try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path)
                    if manager.fileExists(atPath: dst.path) {
                        try manager.removeItem(at: dst)
                    }
                    try manager.moveItem(at: temp, to: dst)
                    installed += 1
                } catch {
                    try? manager.removeItem(at: temp)
                    return false
                }
            }
        }
        return installed > 0
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
            guard decoded.schemaVersion <= 7 else {
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
        next.schemaVersion = 7
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
            "CYDER_WINE_DIAGNOSTICS": value.wineDiagnostics.rawValue,
        ]
    }

    func environment(forExecutable basename: String) -> [String: String] {
        environment(profileID: nil, legacyBasename: basename)
    }

    func environment(
        profileID: String?,
        legacyBasename: String?,
        override: CyderExecutableSettings? = nil,
        capabilities: CyderGraphicsCapabilities? = nil,
        engineRoot: URL? = nil
    ) -> [String: String] {
        var result = environment
        let rule = override ?? executableSettings(profileID: profileID, legacyBasename: legacyBasename)
        let graphics = CyderSettings.resolveGraphics(global: value, profile: rule)
        let caps = capabilities ?? CyderGraphicsCapabilities.current(engineRoot: engineRoot)
        let effective = CyderSettings.effectiveLaunchBackend(
            preference: graphics.backend,
            hasD3DMetal: caps.hasD3DMetal,
            hasDxvk: caps.hasDxvk
        )
        if let effective {
            result["CYDER_GRAPHICS_BACKEND"] = effective.rawValue
        }
        // Manual DXVK exposes the limiter everywhere. OEM also preserves the
        // saved limiter when auto/default collapses to a concrete DXVK launch.
        if graphics.dxvkFrameRate == .sixty,
           (graphics.backend == .dxvk || (CyderProduct.isMapleStoryOEM && effective == .dxvk)) {
            result["DXVK_FRAME_RATE"] = "60"
        }
        switch resolvedGraphicsHud(preference: graphics.backend) {
        case .metal:
            result["MTL_HUD_ENABLED"] = "1"
            result["DXVK_HUD"] = "0"
        case .dxvk:
            result["DXVK_HUD"] = value.dxvkHudFrametimes ? "fps,frametimes" : "fps"
            result.removeValue(forKey: "MTL_HUD_ENABLED")
        case .off:
            result["DXVK_HUD"] = "0"
            result.removeValue(forKey: "MTL_HUD_ENABLED")
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

    private func resolvedGraphicsHud(preference: CyderGraphicsBackend) -> CyderGraphicsHud {
        CyderSettings.resolvedGraphicsHud(preference: preference, requested: value.graphicsHud)
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
