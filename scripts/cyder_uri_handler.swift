// gamaniagames:// URI handler — registry scan, Launch Services, session diff.
import AppKit
import CoreServices
import Foundation

struct CyderURIHandlerRecord: Codable, Equatable {
    let scheme: String
    let sectionTimestamp: Int
    let windowsCommand: String
    let resolvedExecutable: String
    let installPath: String
    let version: String
    let status: String
    let source: String

    var isValid: Bool { status == "valid" && !resolvedExecutable.isEmpty }
    var executableName: String { URL(fileURLWithPath: resolvedExecutable).lastPathComponent }
}

private struct CyderURISessionState {
    let sessionStartedAt: TimeInterval
    let systemRegMtime: Date
    let userRegMtime: Date
    let baselineCommand: String?
    var sessionDeclined = false
}

@available(macOS 11.0, *)
enum CyderURIHandlerError: LocalizedError {
    case notDefaultHandler
    case invalidHandler
    case launchUnavailable

    var errorDescription: String? {
        switch self {
        case .notDefaultHandler:
            return "Cyder 尚未設為 gamaniagames:// 的預設處理程式。請至 Cyder 設定 → URI 協定 啟用。"
        case .invalidHandler:
            return "找不到 gamania Games Manager。請重新安裝遊戲橘子啟動器，或在 Cyder 設定 → URI 協定 檢查。"
        case .launchUnavailable:
            return "Cyder 無法啟動 Windows 程式。"
        }
    }
}

@available(macOS 11.0, *)
final class CyderURIHandlerManager {
    static let scheme = "gamaniagames"
    static let shared = CyderURIHandlerManager()

    private let defaults: UserDefaults
    private let bundleID: String
    private var activeSession: CyderURISessionState?
    private var consentHandler: ((CyderURIHandlerRecord, @escaping (Bool) -> Void) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        bundleID: String = Bundle.main.bundleIdentifier ?? "local.cyder.app"
    ) {
        self.defaults = defaults
        self.bundleID = bundleID
    }

    func setConsentHandler(_ handler: @escaping (CyderURIHandlerRecord, @escaping (Bool) -> Void) -> Void) {
        consentHandler = handler
    }

    func scan(prefix: URL, launcher: String) -> CyderURIHandlerRecord? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            launcher,
            "--scan-uri-handlers",
            prefix.path,
            Self.scheme,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CyderDiagnostics.shared.warning("uri-handler scan failed: \(error)")
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let records = try? JSONDecoder().decode([CyderURIHandlerRecord].self, from: data) else {
            return nil
        }
        return records.first
    }

    func scanAsync(
        prefix: URL,
        launcher: String,
        completion: @escaping (CyderURIHandlerRecord?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let record = self.scan(prefix: prefix, launcher: launcher)
            DispatchQueue.main.async {
                completion(record)
            }
        }
    }

    func regModificationTimes(prefix: URL) -> (system: Date, user: Date) {
        let system = prefix.appendingPathComponent("system.reg")
        let user = prefix.appendingPathComponent("user.reg")
        let systemDate = (try? system.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let userDate = (try? user.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return (systemDate, userDate)
    }

    func beginWineSession(prefix: URL, launcher: String) {
        guard isSharedPrefix(prefix) else { return }
        let mtimes = regModificationTimes(prefix: prefix)
        let handler = scan(prefix: prefix, launcher: launcher)
        activeSession = CyderURISessionState(
            sessionStartedAt: Date().timeIntervalSince1970,
            systemRegMtime: mtimes.system,
            userRegMtime: mtimes.user,
            baselineCommand: handler?.windowsCommand
        )
    }

    func wineSessionEnded(prefix: URL, launcher: String) {
        guard isSharedPrefix(prefix), var session = activeSession else { return }
        defer { activeSession = session }
        guard !session.sessionDeclined else { return }

        let mtimes = regModificationTimes(prefix: prefix)
        let handler = scan(prefix: prefix, launcher: launcher)
        let startedAt = session.sessionStartedAt
        let regChanged = mtimes.system > session.systemRegMtime
            || mtimes.user > session.userRegMtime
            || (handler?.sectionTimestamp ?? 0) > Int(startedAt)
        guard regChanged else { return }
        guard let handler, handler.isValid else { return }

        let baseline = session.baselineCommand
        let isNew = baseline == nil || baseline != handler.windowsCommand
        guard isNew else { return }
        guard !isCyderDefaultHandler() else { return }

        consentHandler?(handler) { accepted in
            if accepted {
                _ = self.enableCyderHandler(for: handler)
            } else {
                session.sessionDeclined = true
                self.activeSession = session
            }
        }
    }

    func isCyderDefaultHandler() -> Bool {
        currentDefaultHandlerBundleID() == bundleID
    }

    func currentDefaultHandlerBundleID() -> String? {
        guard let probe = URL(string: "\(Self.scheme)://"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return nil
        }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    @discardableResult
    func enableCyderHandler(for handler: CyderURIHandlerRecord) -> Bool {
        guard handler.isValid else { return false }
        if let current = currentDefaultHandlerBundleID(), current != bundleID {
            defaults.set(current, forKey: Self.previousHandlerDefaultsKey)
        }
        let status = LSSetDefaultHandlerForURLScheme(Self.scheme as CFString, bundleID as CFString)
        if status == noErr {
            CyderDiagnostics.shared.info("uri-handler enabled scheme=\(Self.scheme)")
            return true
        }
        CyderDiagnostics.shared.warning("uri-handler enable failed status=\(status)")
        return false
    }

    @discardableResult
    func disableCyderHandler() -> Bool {
        guard isCyderDefaultHandler() else { return true }
        if let previous = defaults.string(forKey: Self.previousHandlerDefaultsKey), !previous.isEmpty {
            let status = LSSetDefaultHandlerForURLScheme(Self.scheme as CFString, previous as CFString)
            defaults.removeObject(forKey: Self.previousHandlerDefaultsKey)
            if status != noErr {
                CyderDiagnostics.shared.warning("uri-handler restore failed status=\(status)")
            }
        }
        return true
    }

    func validateLaunch(prefix: URL, launcher: String) -> Result<CyderURIHandlerRecord, CyderURIHandlerError> {
        guard isCyderDefaultHandler() else { return .failure(.notDefaultHandler) }
        guard let handler = scan(prefix: prefix, launcher: launcher), handler.isValid else {
            return .failure(.invalidHandler)
        }
        return .success(handler)
    }

    func filterHandledURLs(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            guard url.scheme?.lowercased() == Self.scheme else { return nil }
            // Preserve percent-encoding (e.g. %20) for Windows %1 semantics.
            return url.absoluteString
        }
    }

    private func isSharedPrefix(_ prefix: URL) -> Bool {
        prefix.standardizedFileURL.path == CyderPaths.sharedBottle.standardizedFileURL.path
    }

    private static var previousHandlerDefaultsKey: String {
        "uriHandler.previous.\(scheme)"
    }
}
