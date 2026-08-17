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
func cyderDefaultMingLiuFontTarget() -> String {
    cyderSystemProvidesMingLiU() ? "mingliu" : "songti"
}

/// Shared font replacement target ids (order matches UI titles).
let cyderFontTargetIDs: [String] = [
    "mingliu", "songti", "pingfang",
]

let cyderFontTargetTitles: [String] = [
    "細明體", "宋體", "蘋方",
]

func cyderSanitizeFontTarget(_ raw: String?, fallback: String) -> String {
    guard let raw, cyderFontTargetIDs.contains(raw) else {
        return fallback
    }
    return raw
}

enum CyderProduct {
    /// MapleStory OEM ships a dedicated App wrapper that exports this flavor.
    static var isMapleStoryOEM: Bool {
        ProcessInfo.processInfo.environment["CYDER_OEM_FLAVOR"] == "maplestory"
    }

    /// Official and OEM builds leave the global `default` value unchanged.
    /// MapleStory's executable-specific platform policy is resolved only at
    /// launch time, after the actual executable and payload capabilities are
    /// known.
    static var defaultGraphicsBackend: CyderGraphicsBackend { .default }
}

enum CyderGraphicsBackend: String, Codable, CaseIterable {
    case `default`
    case wined3d, dxvk, dxmt, d3dmetal

    var usesDxvkTranslation: Bool { self == .dxvk }

    var usesFrameLimiter: Bool { usesDxvkTranslation || self == .dxmt }
}

enum CyderDxvkFrameRate: String, Codable, CaseIterable {
    case sixty = "60"
    case oneTwenty = "120"
    case oneFortyFour = "144"
    case unlimited

    var fpsValue: String? {
        switch self {
        case .sixty: return "60"
        case .oneTwenty: return "120"
        case .oneFortyFour: return "144"
        case .unlimited: return nil
        }
    }

    var menuIndex: Int {
        switch self {
        case .sixty: return 0
        case .oneTwenty: return 1
        case .oneFortyFour: return 2
        case .unlimited: return 3
        }
    }

    init(menuIndex: Int) {
        switch menuIndex {
        case 1: self = .oneTwenty
        case 2: self = .oneFortyFour
        case 3: self = .unlimited
        default: self = .sixty
        }
    }
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
    /// Wait diagnostics for freezes: logs the handles every wait blocks on, which
    /// is what a deadlock needs, at a fraction of the unwind profile's volume.
    case sync
    case unwind

    var wineDebug: String {
        switch self {
        case .quiet:
            return "-all"
        case .errors:
            return "-all,err+all,+timestamp,+pid,+tid"
        case .sync:
            return "-all,err+all,+timestamp,+pid,+tid,+sync"
        case .unwind:
            return "-all,+timestamp,+pid,+tid,+seh,+unwind"
        }
    }
}

enum CyderSyncMode: Int, CaseIterable {
    case off
    case msync
    case esync

    init(msync: Bool, esync: Bool) {
        if msync {
            self = .msync
        } else if esync {
            self = .esync
        } else {
            self = .off
        }
    }

    var title: String {
        switch self {
        case .off: return "關閉"
        case .msync: return "MSync"
        case .esync: return "ESync"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "不使用額外的同步機制；遇到遊戲凍結或無法啟動時，建議先使用此選項。"
        case .msync:
            return "使用 macOS 原生同步機制改善部分遊戲效能；若遊戲凍結或無法啟動，可改回關閉。"
        case .esync:
            return "使用事件同步機制降低等待開銷；若遊戲凍結或無法啟動，可改回關閉。"
        }
    }
}

struct CyderGraphicsCapabilities: Equatable {
    var hasD3DMetal: Bool
    var hasDxvk: Bool
    var hasDxmt: Bool

    /// Probe local GPTK / DXVK / DXMT availability. When `engineRoot` is nil,
    /// graphics payload availability is unknown, so the settings-only UI keeps the
    /// options selectable until an engine root is available; launch paths should pass
    /// the real root.
    static func current(engineRoot: URL? = nil) -> CyderGraphicsCapabilities {
        let osOK = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        let hasGptk = CyderGptk.preferredSource() != nil
        return CyderGraphicsCapabilities(
            hasD3DMetal: osOK && hasGptk,
            hasDxvk: hasDxvkPayload(engineRoot: engineRoot),
            hasDxmt: hasDxmtPayload(engineRoot: engineRoot)
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
        let dxvkDXGI = root.appendingPathComponent("lib/dxvk/x86_64-windows/dxgi.dll")
        let moltenA = root.appendingPathComponent("lib/wine/x86_64-unix/libMoltenVK.dylib")
        let moltenB = root.appendingPathComponent("lib64/libMoltenVK.dylib")
        return manager.isReadableFile(atPath: dxvkDLL.path)
            && manager.isReadableFile(atPath: dxvkDXGI.path)
            && (manager.isReadableFile(atPath: moltenA.path) || manager.isReadableFile(atPath: moltenB.path))
    }

    static func hasDxmtPayload(engineRoot: URL?) -> Bool {
        let root: URL?
        if let engineRoot {
            root = engineRoot
        } else if let path = ProcessInfo.processInfo.environment["CYDER_GRAPHICS_BACKENDS_ROOT"],
                  !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            // Settings / prefs probes without an engine still allow manual selection.
            return true
        }
        guard let root else { return true }
        let manager = FileManager.default
        let dxmtDLL = root.appendingPathComponent("lib/dxmt/x86_64-windows/d3d11.dll")
        let dxmtDXGI = root.appendingPathComponent("lib/dxmt/x86_64-windows/dxgi.dll")
        let dxmtWinemetal64 = root.appendingPathComponent("lib/dxmt/x86_64-windows/winemetal.dll")
        let dxmtDLL32 = root.appendingPathComponent("lib/dxmt/i386-windows/d3d11.dll")
        let dxmtDXGI32 = root.appendingPathComponent("lib/dxmt/i386-windows/dxgi.dll")
        let dxmtWinemetal32 = root.appendingPathComponent("lib/dxmt/i386-windows/winemetal.dll")
        let winemetal = root.appendingPathComponent("lib/dxmt/x86_64-unix/winemetal.so")
        return manager.isReadableFile(atPath: dxmtDLL.path)
            && manager.isReadableFile(atPath: dxmtDXGI.path)
            && manager.isReadableFile(atPath: dxmtWinemetal64.path)
            && manager.isReadableFile(atPath: dxmtDLL32.path)
            && manager.isReadableFile(atPath: dxmtDXGI32.path)
            && manager.isReadableFile(atPath: dxmtWinemetal32.path)
            && manager.isReadableFile(atPath: winemetal.path)
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
    var fontMingLiuTarget: String?
    var fontSongtiTarget: String?
    var fontSmoothing: String?
    var powerMode: String?
    var graphicsBackend: CyderGraphicsBackend?
    var dxvkFrameRate: CyderDxvkFrameRate?

    enum CodingKeys: String, CodingKey {
        case arguments, environment, msync, esync, retinaMode, dpi
        case fontMingLiuTarget, fontSongtiTarget, fontSmoothing, powerMode
        case graphicsBackend, dxvkFrameRate
        case fontPreset
    }

    init() {}

    init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        msync: Bool? = nil,
        esync: Bool? = nil,
        retinaMode: Bool? = nil,
        dpi: Int? = nil,
        fontMingLiuTarget: String? = nil,
        fontSongtiTarget: String? = nil,
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
        self.fontMingLiuTarget = fontMingLiuTarget
        self.fontSongtiTarget = fontSongtiTarget
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
        let legacyPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset)
        let migrated = CyderSettings.migrateFontTargets(preset: legacyPreset)
        if let value = try values.decodeIfPresent(String.self, forKey: .fontMingLiuTarget) {
            fontMingLiuTarget = cyderSanitizeFontTarget(value, fallback: cyderDefaultMingLiuFontTarget())
        } else if legacyPreset != nil {
            fontMingLiuTarget = migrated.0
        }
        if let value = try values.decodeIfPresent(String.self, forKey: .fontSongtiTarget) {
            fontSongtiTarget = cyderSanitizeFontTarget(value, fallback: "songti")
        } else if legacyPreset != nil {
            fontSongtiTarget = migrated.1
        }
        fontSmoothing = try values.decodeIfPresent(String.self, forKey: .fontSmoothing)
        powerMode = try values.decodeIfPresent(String.self, forKey: .powerMode)
        graphicsBackend = CyderSettings.sanitizedOptionalGraphicsBackend(
            try values.decodeIfPresent(String.self, forKey: .graphicsBackend)
        )
        dxvkFrameRate = CyderSettings.sanitizedOptionalDxvkFrameRate(
            try values.decodeIfPresent(String.self, forKey: .dxvkFrameRate)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encodeIfPresent(msync, forKey: .msync)
        try container.encodeIfPresent(esync, forKey: .esync)
        try container.encodeIfPresent(retinaMode, forKey: .retinaMode)
        try container.encodeIfPresent(dpi, forKey: .dpi)
        try container.encodeIfPresent(fontMingLiuTarget, forKey: .fontMingLiuTarget)
        try container.encodeIfPresent(fontSongtiTarget, forKey: .fontSongtiTarget)
        try container.encodeIfPresent(fontSmoothing, forKey: .fontSmoothing)
        try container.encodeIfPresent(powerMode, forKey: .powerMode)
        try container.encodeIfPresent(graphicsBackend, forKey: .graphicsBackend)
        try container.encodeIfPresent(dxvkFrameRate, forKey: .dxvkFrameRate)
    }
}

struct CyderSettings: Codable {
    // Schema 11 adds the MapleStory WZ cache preference. Schema 10 removes the experimental dxvk2 graphics backend. Schema 9 added
    // that backend; old settings are migrated to the default backend on decode.
    // Schema 8 replaces fontPreset with fontMingLiuTarget/fontSongtiTarget.
    // Schema 7 adds wineDiagnostics. Schema 6 adds dxvkHudFrametimes. Schema 5 adds graphicsHud.
    // Schema 4 adds graphics backend and DXVK frame rate. Schema 3 adds profile-keyed overrides. Keep perExecutable as a
    // legacy basename fallback; never infer a profile from a basename.
    var schemaVersion = 11
    var revision = 0
    /// Wall-clock time of the most recent effective settings change. Kept in
    /// settings.json so the state and its provenance travel together.
    var updatedAt: String?
    /// Last-change timestamps for global fields and per-profile/legacy rules.
    /// Keys use `global.<field>`, `profile:<id>`, and `executable:<basename>`.
    var lastModified: [String: String] = [:]
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontMingLiuTarget = cyderDefaultMingLiuFontTarget()
    var fontSongtiTarget = "songti"
    var fontSmoothing = "cleartype-rgb"
    var graphicsBackend: CyderGraphicsBackend = CyderProduct.defaultGraphicsBackend
    var dxvkFrameRate: CyderDxvkFrameRate = .sixty
    var graphicsHud: CyderGraphicsHud = .off
    var dxvkHudFrametimes = true
    var wineDiagnostics: CyderWineDiagnostics = .quiet
    /// Enable MapleStory-only read-ahead for read-only WZ/MS files.
    var maplestoryWZCache = true
    var perExecutable: [String: CyderExecutableSettings] = [:]
    var perProfile: [String: CyderExecutableSettings] = [:]

    static var defaults: CyderSettings { CyderSettings() }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, updatedAt, lastModified, msync, esync, retinaMode, dpi
        case fontMingLiuTarget, fontSongtiTarget, fontSmoothing
        case graphicsBackend, dxvkFrameRate, graphicsHud, dxvkHudFrametimes, wineDiagnostics
        case maplestoryWZCache
        case perExecutable, perProfile
        case fontPreset
    }

    static func migrateFontTargets(preset: String?) -> (String, String) {
        switch preset {
        case "mingliu":
            return ("mingliu", "songti")
        case "songti":
            return ("songti", "songti")
        default:
            return (cyderDefaultMingLiuFontTarget(), "songti")
        }
    }

    init() {
        fontMingLiuTarget = cyderDefaultMingLiuFontTarget()
        fontSongtiTarget = "songti"
        graphicsBackend = CyderProduct.defaultGraphicsBackend
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 11 else { throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion, in: values, debugDescription: "unsupported settings schema \(version)"
        ) }
        schemaVersion = 11
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        lastModified = try values.decodeIfPresent([String: String].self, forKey: .lastModified) ?? [:]
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync) ?? false
        esync = try values.decodeIfPresent(Bool?.self, forKey: .esync) ?? false
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi) ?? 192
        let legacyPreset = try values.decodeIfPresent(String.self, forKey: .fontPreset)
        let migrated = Self.migrateFontTargets(preset: legacyPreset)
        fontMingLiuTarget = cyderSanitizeFontTarget(
            try values.decodeIfPresent(String.self, forKey: .fontMingLiuTarget) ?? migrated.0,
            fallback: cyderDefaultMingLiuFontTarget()
        )
        fontSongtiTarget = cyderSanitizeFontTarget(
            try values.decodeIfPresent(String.self, forKey: .fontSongtiTarget) ?? migrated.1,
            fallback: "songti"
        )
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
        maplestoryWZCache = try values.decodeIfPresent(Bool.self, forKey: .maplestoryWZCache) ?? true
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
        fontMingLiuTarget = cyderSanitizeFontTarget(fontMingLiuTarget, fallback: cyderDefaultMingLiuFontTarget())
        fontSongtiTarget = cyderSanitizeFontTarget(fontSongtiTarget, fallback: "songti")
        if !["off", "grayscale", "cleartype-rgb", "cleartype-bgr"].contains(fontSmoothing) {
            fontSmoothing = "cleartype-rgb"
        }
        // DXVK HUD is only meaningful with a manual DXVK preference.
        if graphicsHud == .dxvk && !graphicsBackend.usesDxvkTranslation {
            graphicsHud = .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(msync, forKey: .msync)
        try container.encode(esync, forKey: .esync)
        try container.encode(retinaMode, forKey: .retinaMode)
        try container.encode(dpi, forKey: .dpi)
        try container.encode(fontMingLiuTarget, forKey: .fontMingLiuTarget)
        try container.encode(fontSongtiTarget, forKey: .fontSongtiTarget)
        try container.encode(fontSmoothing, forKey: .fontSmoothing)
        try container.encode(graphicsBackend, forKey: .graphicsBackend)
        try container.encode(dxvkFrameRate, forKey: .dxvkFrameRate)
        try container.encode(graphicsHud, forKey: .graphicsHud)
        try container.encode(dxvkHudFrametimes, forKey: .dxvkHudFrametimes)
        try container.encode(wineDiagnostics, forKey: .wineDiagnostics)
        try container.encode(maplestoryWZCache, forKey: .maplestoryWZCache)
        try container.encode(perExecutable, forKey: .perExecutable)
        try container.encode(perProfile, forKey: .perProfile)
    }

    static func sanitizedGraphicsBackend(_ raw: String?) -> CyderGraphicsBackend {
        guard let raw else { return CyderProduct.defaultGraphicsBackend }
        // Legacy "auto" preference collapses to default now that the App-side
        // cascade has been removed.
        if raw == "auto" { return .default }
        guard let value = CyderGraphicsBackend(rawValue: raw) else {
            return CyderProduct.defaultGraphicsBackend
        }
        return value
    }

    static func sanitizedDxvkFrameRate(_ raw: String?) -> CyderDxvkFrameRate {
        sanitizedOptionalDxvkFrameRate(raw) ?? .sixty
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
        if raw == "auto" { return .default }
        return CyderGraphicsBackend(rawValue: raw)
    }

    static func sanitizedOptionalDxvkFrameRate(_ raw: String?) -> CyderDxvkFrameRate? {
        guard let raw else { return nil }
        switch raw {
        case "sixty", "60": return .sixty
        case "120": return .oneTwenty
        case "144": return .oneFortyFour
        case "unlimited": return .unlimited
        default: return CyderDxvkFrameRate(rawValue: raw)
        }
    }

    static func mergingDxmtPreferredMaxFrameRate(existing: String?, fps: String?) -> String? {
        var parts = (existing ?? "")
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts.removeAll { part in
            let key = part.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return key == "d3d11.preferredmaxframerate"
        }
        if let fps {
            parts.append("d3d11.preferredMaxFrameRate=\(fps)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ";") + ";"
    }

    static func applyGraphicsFrameLimiter(
        _ env: inout [String: String],
        backend: CyderGraphicsBackend,
        rate: CyderDxvkFrameRate
    ) {
        if backend.usesDxvkTranslation, let fps = rate.fpsValue {
            env["DXVK_FRAME_RATE"] = fps
        }
        guard backend == .dxmt else { return }
        if let merged = mergingDxmtPreferredMaxFrameRate(existing: env["DXMT_CONFIG"], fps: rate.fpsValue) {
            env["DXMT_CONFIG"] = merged
        } else {
            env.removeValue(forKey: "DXMT_CONFIG")
        }
    }

    static func resolveGraphics(
        global: CyderSettings,
        profile: CyderExecutableSettings?
    ) -> CyderResolvedGraphics {
        let backend = profile?.graphicsBackend ?? global.graphicsBackend
        return CyderResolvedGraphics(
            backend: backend,
            dxvkFrameRate: profile?.dxvkFrameRate ?? global.dxvkFrameRate
        )
    }

    /// Concrete backend to inject into Wine, or `nil` to leave CompatDB alone.
    /// `default` remains CompatDB-driven except for the two MapleStory
    /// executables, whose platform policy is resolved when the executable name
    /// is available.
    ///
    /// DXMT additionally fails closed on `hasDxmt` + `osMajorVersion`: a stale
    /// or hand-edited `dxmt` preference must never launch DXMT on an engine
    /// missing the payload or on macOS < 15, even though the UI already
    /// disables that menu item.
    static func effectiveLaunchBackend(
        preference: CyderGraphicsBackend,
        hasD3DMetal: Bool,
        hasDxvk: Bool,
        hasDxmt: Bool,
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        executableBasename: String? = nil
    ) -> CyderGraphicsBackend? {
        switch preference {
        case .default:
            if isMapleStoryGraphicsExecutable(executableBasename) {
                if osMajorVersion >= 15, hasDxmt {
                    return .dxmt
                }
                if hasDxvk {
                    return .dxvk
                }
            }
            return nil
        case .dxmt:
            return (hasDxmt && osMajorVersion >= 15) ? .dxmt : nil
        case .wined3d, .dxvk, .d3dmetal:
            return preference
        }
    }

    /// Return true for the exact MapleStory executables that use the
    /// platform-dependent automatic graphics policy. Normalize both POSIX and
    /// Windows separators because callers may pass a basename or a Wine path.
    static func isMapleStoryGraphicsExecutable(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let basename = value
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)?
            .lowercased()
        return basename == "maplestory.exe" || basename == "maplestory_classic.exe"
    }

    /// HUD choice after applying the "DXVK HUD only with DXVK-family backends" rule.
    static func resolvedGraphicsHud(
        preference: CyderGraphicsBackend,
        requested: CyderGraphicsHud
    ) -> CyderGraphicsHud {
        if requested == .dxvk && !preference.usesDxvkTranslation {
            return .off
        }
        return requested
    }

    static func isValidProfileID(_ value: String) -> Bool {
        value.range(of: "^profile-[0-9a-f]{24}$", options: .regularExpression) != nil
    }

    static func isValidEnvironmentKey(_ value: String) -> Bool {
        guard value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            return false
        }
        let exactReserved: Set<String> = [
            "BASH_ENV", "ENV", "IFS", "PATH", "HOME", "TMPDIR", "SHELLOPTS", "BASHOPTS",
            "CDPATH", "GLOBIGNORE", "WINEPREFIX", "WINESERVER", "WINEARCH", "WINEDEBUG",
            "CX_ROOT", "CX_BOTTLE", "CX_APPLEGPTK_LIBD3DSHARED_PATH", "CYDER_SUPPORT",
            "CYDER_RUNTIME_ROOT", "CYDER_ENGINES", "CYDER_ENGINE_NAME", "CYDER_ENGINE_SRC",
            "CYDER_SCRIPTS", "CYDER_APP", "CYDER_RESULT_FILE", "CYDER_PROGRESS_FILE",
            "CYDER_GPTK_ROOT", "CYDER_GRAPHICS_BACKENDS_ROOT", "CYDER_GAME_ARGUMENTS",
        ]
        // Explicit advanced override: cxcompatdb canonicalizes and validates
        // the directory, PE machine, builtin signature and dependencies.
        if value == "CYDER_GRAPHICS_BACKEND_PATH" { return true }
        if exactReserved.contains(value) { return false }
        return !["DYLD_", "LD_", "CYDER_WINE_", "CYDER_SESSION_", "CYDER_DIAGNOSTIC_", "CYDER_TEST_", "CYDER_GRAPHICS_"]
            .contains { value.hasPrefix($0) }
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
        if let target = value.fontMingLiuTarget,
           !cyderFontTargetIDs.contains(target) {
            result.fontMingLiuTarget = nil
        }
        if let target = value.fontSongtiTarget,
           !cyderFontTargetIDs.contains(target) {
            result.fontSongtiTarget = nil
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

    /// Return stable metadata keys for values that changed during one store
    /// update. The UI writes a complete settings snapshot, so comparing the
    /// post-sanitization snapshot avoids marking every field as modified on
    /// each control event.
    static func changedMetadataKeys(from before: CyderSettings, to after: CyderSettings) -> [String] {
        var keys = Set<String>()
        func mark(_ field: String, _ changed: Bool) {
            if changed { keys.insert("global.\(field)") }
        }
        mark("msync", before.msync != after.msync)
        mark("esync", before.esync != after.esync)
        mark("retinaMode", before.retinaMode != after.retinaMode)
        mark("dpi", before.dpi != after.dpi)
        mark("fontMingLiuTarget", before.fontMingLiuTarget != after.fontMingLiuTarget)
        mark("fontSongtiTarget", before.fontSongtiTarget != after.fontSongtiTarget)
        mark("fontSmoothing", before.fontSmoothing != after.fontSmoothing)
        mark("graphicsBackend", before.graphicsBackend.rawValue != after.graphicsBackend.rawValue)
        mark("dxvkFrameRate", before.dxvkFrameRate.rawValue != after.dxvkFrameRate.rawValue)
        mark("graphicsHud", before.graphicsHud.rawValue != after.graphicsHud.rawValue)
        mark("dxvkHudFrametimes", before.dxvkHudFrametimes != after.dxvkHudFrametimes)
        mark("wineDiagnostics", before.wineDiagnostics.rawValue != after.wineDiagnostics.rawValue)
        mark("maplestoryWZCache", before.maplestoryWZCache != after.maplestoryWZCache)

        let profileIDs = Set(before.perProfile.keys).union(after.perProfile.keys)
        for profileID in profileIDs {
            if encoded(before.perProfile[profileID]) != encoded(after.perProfile[profileID]) {
                keys.insert("profile:\(profileID)")
            }
        }
        let executableNames = Set(before.perExecutable.keys).union(after.perExecutable.keys)
        for basename in executableNames {
            if encoded(before.perExecutable[basename]) != encoded(after.perExecutable[basename]) {
                keys.insert("executable:\(basename)")
            }
        }
        return keys.sorted()
    }

    private static func encoded<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder.pretty.encode(value)
    }
}

final class CyderSettingsStore {
    static let shared = CyderSettingsStore()
    private(set) var value: CyderSettings
    private let url: URL

    private static let modificationTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
            guard decoded.schemaVersion <= 11 else {
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
        next.schemaVersion = 11
        next.perProfile = next.perProfile.reduce(into: [:]) { result, item in
            guard CyderSettings.isValidProfileID(item.key) else { return }
            result[item.key] = CyderSettings.sanitized(item.value)
        }
        next.perExecutable = next.perExecutable.reduce(into: [:]) { result, item in
            result[item.key] = CyderSettings.sanitized(item.value)
        }
        next.dpi = min(480, max(72, next.dpi))
        let changedKeys = CyderSettings.changedMetadataKeys(from: value, to: next)
        if !changedKeys.isEmpty || next.updatedAt == nil {
            let timestamp = Self.modificationTimestampFormatter.string(from: Date())
            next.updatedAt = timestamp
            for key in changedKeys {
                next.lastModified[key] = timestamp
            }
        }
        next.revision = max(value.revision + 1, next.revision)
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
            "CYDER_FONT_MINGLIU_TARGET": value.fontMingLiuTarget,
            "CYDER_FONT_SONGTI_TARGET": value.fontSongtiTarget,
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
            hasDxvk: caps.hasDxvk,
            hasDxmt: caps.hasDxmt,
            executableBasename: legacyBasename
        )
        if let effective {
            result["CYDER_GRAPHICS_BACKEND"] = effective.rawValue
        }
        let runtimeBackend = effective ?? graphics.backend
        switch resolvedGraphicsHud(preference: runtimeBackend) {
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
        if let rule {
            if let v = rule.msync { result["CYDER_MSYNC"] = v ? "1" : "0" }
            if let v = rule.esync { result["CYDER_ESYNC"] = v ? "1" : "0" }
            if let v = rule.retinaMode { result["CYDER_RETINA_MODE"] = v ? "1" : "0" }
            if let v = rule.dpi { result["CYDER_DPI"] = String(min(480, max(72, v))) }
            if let v = rule.fontMingLiuTarget { result["CYDER_FONT_MINGLIU_TARGET"] = v }
            if let v = rule.fontSongtiTarget { result["CYDER_FONT_SONGTI_TARGET"] = v }
            if let v = rule.fontSmoothing { result["CYDER_FONT_SMOOTHING"] = v }
            if let v = rule.powerMode { result["CYDER_POWER_MODE"] = v == "energySaving" ? "background" : "normal" }
            result.merge(rule.environment.filter { CyderSettings.isValidEnvironmentKey($0.key) }) { _, override in override }
        }
        // Apply after per-game env so DXMT_CONFIG keys merge instead of clobber.
        CyderSettings.applyGraphicsFrameLimiter(
            &result, backend: runtimeBackend, rate: graphics.dxvkFrameRate
        )
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
