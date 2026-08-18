// Cross-process coordinator for the native Cyder application.
//
// A LaunchServices `open -n` request can create another process even when the
// original Cyder process is still resident.  Only the primary process owns
// the menu-bar item; secondary processes write a short-lived request and exit
// after the primary has consumed it.
import Cocoa
import Darwin
import Foundation

struct CyderInstanceRequest {
    let files: [String]
    let arguments: [String]?
    let urls: [String]
    let showUI: Bool
}

final class CyderInstanceCoordinator {
    enum Role {
        case primary
        case secondary
        case unavailable
    }

    private let support: URL
    private let requestDirectory: URL
    private let notificationName = Notification.Name("local.cyder.app.instance-request")
    private var observer: NSObjectProtocol?
    private var requestPollTimer: Timer?
    private var ownsLock = false
    private var onRequest: ((CyderInstanceRequest) -> Void)?
    let sentinel: CyderSentinelServer

    init(
        support: URL = CyderPaths.support,
        bundleID: String = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? "local.cyder.app"
    ) {
        self.support = support
        requestDirectory = support.appendingPathComponent("native-instance-requests", isDirectory: true)
        sentinel = CyderSentinelServer(support: support, bundleID: bundleID)
    }

    @discardableResult
    func start(onRequest: @escaping (CyderInstanceRequest) -> Void) -> Role {
        self.onRequest = onRequest
        guard ensureDirectory(support), ensureDirectory(requestDirectory) else {
            return .unavailable
        }
        switch sentinel.becomePrimary() {
        case .primary:
            ownsLock = true
            installObserver()
            drainRequests()
            return .primary
        case .secondary:
            return .secondary
        case .unavailable:
            return .unavailable
        }
    }

    func forward(files: [String], arguments: [String]?, urls: [String] = [], showUI: Bool) {
        guard !files.isEmpty || arguments != nil || !urls.isEmpty || showUI else { return }
        guard ensureDirectory(requestDirectory) else { return }
        let payload: [String: Any] = [
            "files": files,
            "arguments": arguments ?? [],
            "hasArguments": arguments != nil,
            "urls": urls,
            "showUI": showUI,
            "createdAt": Date().timeIntervalSince1970,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        ) else { return }
        let url = requestDirectory.appendingPathComponent("request-\(UUID().uuidString).plist")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        } catch {
            return
        }
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: ["path": url.path]
        )
    }

    func stop() {
        requestPollTimer?.invalidate()
        requestPollTimer = nil
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        guard ownsLock else { return }
        ownsLock = false
        sentinel.stop()
    }

    deinit { stop() }

    private func installObserver() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.drainRequests(preferredPath: note.userInfo?["path"] as? String)
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.drainRequests()
        }
        RunLoop.main.add(timer, forMode: .common)
        requestPollTimer = timer
    }

    private func drainRequests(preferredPath: String? = nil) {
        var urls: [URL] = []
        if let preferredPath, isRequestURL(URL(fileURLWithPath: preferredPath)) {
            urls.append(URL(fileURLWithPath: preferredPath))
        }
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: entries.filter(isRequestURL))
        }

        var seen = Set<String>()
        for url in urls where seen.insert(url.path).inserted {
            guard let request = readRequest(at: url) else {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modified) > 10 {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            try? FileManager.default.removeItem(at: url)
            onRequest?(request)
        }
    }

    private func readRequest(at url: URL) -> CyderInstanceRequest? {
        guard isRequestURL(url),
              let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let payload = propertyList as? [String: Any],
              let rawFiles = payload["files"] as? [String],
              let rawArguments = payload["arguments"] as? [String],
              let showUI = payload["showUI"] as? Bool,
              let createdAt = payload["createdAt"] as? Double,
              Date().timeIntervalSince1970 - createdAt <= 10 else {
            return nil
        }
        let arguments = (payload["hasArguments"] as? Bool) == true ? rawArguments : nil
        let rawURLs = payload["urls"] as? [String] ?? []
        return CyderInstanceRequest(files: rawFiles, arguments: arguments, urls: rawURLs, showUI: showUI)
    }

    private func isRequestURL(_ url: URL) -> Bool {
        guard url.pathExtension == "plist",
              url.deletingLastPathComponent().standardizedFileURL == requestDirectory.standardizedFileURL else {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
            return true
        } catch {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }
}
