// Shared launch/process support for Cyder.app. Kept independent of Settings UI
// so the phased environment and Wine launch services can be tested separately.
import Cocoa
import Foundation

func activateCyderUI(dockVisible: Bool) {
    NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    NSApp.activate(ignoringOtherApps: true)
}

func runFrontmostAlert(
    _ alert: NSAlert,
    dockVisible: Bool,
    anchorWindow: NSWindow? = nil
) -> NSApplication.ModalResponse {
    activateCyderUI(dockVisible: dockVisible)
    alert.window.level = .modalPanel
    alert.window.collectionBehavior.insert(.canJoinAllSpaces)

    // NSAlert defaults to the last remembered window position.  That can be
    // outside the active display (in particular after a settings window has
    // just closed), which makes the completion dialog look like it opened at
    // the left edge.  Place it in the visible center of the settings display
    // whenever an anchor is available, falling back to the main display.
    let anchorPoint = anchorWindow.map {
        NSPoint(x: $0.frame.midX, y: $0.frame.midY)
    }
    let screen = anchorWindow?.screen
        ?? anchorPoint.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(point) }
        }
        ?? NSScreen.main
    if let screen {
        alert.window.displayIfNeeded()
        let alertFrame = alert.window.frame
        let visibleFrame = screen.visibleFrame
        alert.window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - alertFrame.width / 2,
            y: visibleFrame.midY - alertFrame.height / 2
        ))
    } else {
        alert.window.center()
    }
    alert.window.makeKeyAndOrderFront(nil)
    alert.window.orderFrontRegardless()
    return alert.runModal()
}

final class CyderSetupPanel {
    private let window: NSWindow
    private let progress: NSProgressIndicator
    private let label: NSTextField
    private let detail: NSTextField

    init() {
        let width: CGFloat = 420
        let height: CGFloat = 150
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cyder"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .regular
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)

        label = NSTextField(labelWithString: "正在準備…")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        detail = NSTextField(labelWithString: "請稍候，完成後會自動關閉。")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(label)
        content.addSubview(progress)
        content.addSubview(detail)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            progress.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 14),
        ])
    }

    func setMessage(_ text: String) {
        label.stringValue = text
        window.displayIfNeeded()
    }

    func show() {
        activateCyderUI(dockVisible: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    func close() {
        progress.stopAnimation(nil)
        window.orderOut(nil)
    }
}

final class WineActivationWaiter {
    let prefix: String
    let semaphore = DispatchSemaphore(value: 0)

    init(prefix: String) {
        self.prefix = (prefix as NSString).standardizingPath
    }
}

struct CyderProcessResult {
    let status: Int32
    let terminationReason: Process.TerminationReason
    let logURL: URL
    let outputTail: String
    let machineResult: [String: String]

    init(
        status: Int32,
        terminationReason: Process.TerminationReason,
        logURL: URL,
        outputTail: String,
        machineResult: [String: String] = [:]
    ) {
        self.status = status
        self.terminationReason = terminationReason
        self.logURL = logURL
        self.outputTail = outputTail
        self.machineResult = machineResult
    }

    var succeeded: Bool {
        terminationReason == .exit && status == 0
    }

    var terminationDescription: String {
        switch terminationReason {
        case .exit:
            return "exit"
        case .uncaughtSignal:
            return "uncaught-signal"
        @unknown default:
            return "unknown"
        }
    }
}

struct CyderLaunchContext {
    let launcher: String
    let engineSrc: String
    let engineVersionFile: String
    let environment: [String: String]

    init(resourcePath: String) {
        let entitlements = resourcePath + "/entitlements.plist"
        let libarchive = resourcePath + "/addons/libarchive"
        let contentsPath = (resourcePath as NSString).deletingLastPathComponent
        let appPath = (contentsPath as NSString).deletingLastPathComponent
        let engineSrc = resolveEngineSrc(resourcePath: resourcePath)

        launcher = resourcePath + "/ogom-scripts/cyder_launcher.sh"
        self.engineSrc = engineSrc
        engineVersionFile = resourcePath + "/engine-version.txt"

        var env = ProcessInfo.processInfo.environment
        env["CYDER_ENGINE_SRC"] = engineSrc
        env["CYDER_SCRIPTS"] = resourcePath + "/ogom-scripts"
        env["CYDER_LIBARCHIVE_SRC"] = libarchive
        env["CYDER_GUI"] = "1"
        env["OGOM"] = resourcePath
        env["WINE_INSTALL"] = engineSrc
        env["ENTITLEMENTS_PLIST"] = entitlements
        env["CYDER_ENTITLEMENTS"] = entitlements
        env["CYDER_APP"] = appPath
        env["CYDER_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? "local.cyder.app"
        environment = env
    }
}

func resolveEngineSrc(resourcePath: String) -> String {
    let archiveListFile = resourcePath + "/engine-archive.txt"
    if let archiveName = try? String(contentsOfFile: archiveListFile, encoding: .utf8) {
        let trimmedArchive = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArchive.isEmpty {
            let archivePath = resourcePath + "/" + trimmedArchive
            if FileManager.default.fileExists(atPath: archivePath) {
                return archivePath
            }
        }
    }
    let versionFile = resourcePath + "/engine-version.txt"
    if let ver = try? String(contentsOfFile: versionFile, encoding: .utf8) {
        let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let zst = resourcePath + "/engine-\(trimmed).tar.zst"
            if FileManager.default.fileExists(atPath: zst) {
                return zst
            }
            let xz = resourcePath + "/engine-wine-x86_64-\(trimmed).tar.xz"
            if FileManager.default.fileExists(atPath: xz) {
                return xz
            }
        }
    }
    return resourcePath + "/engine-payload"
}

func findExecutable(named name: String, environment: [String: String]) -> URL? {
    var directories = (environment["PATH"] ?? "")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)
    for fallback in ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !directories.contains(fallback) {
        directories.append(fallback)
    }
    for directory in directories {
        let candidate = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

func normalizeExePaths(_ paths: [String]) -> [String] {
    var out: [String] = []
    for raw in paths {
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.isEmpty { continue }
        if path.lowercased().hasSuffix(".exe") { out.append(path) }
    }
    return out
}

func resolvedWineLocale(environment: [String: String]) -> String {
    for key in ["LC_ALL", "LANG"] {
        if let value = environment[key], !value.isEmpty,
           value != "C", value != "POSIX", value != "C.UTF-8" {
            return value
        }
    }
    let identifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
    let lower = identifier.lowercased()
    if lower.hasPrefix("zh_hant_tw") || lower == "zh_tw" { return "zh_TW.UTF-8" }
    if lower.hasPrefix("zh_hant_hk") || lower == "zh_hk" { return "zh_HK.UTF-8" }
    if lower.hasPrefix("zh_hans") || lower == "zh_cn" { return "zh_CN.UTF-8" }
    if lower.hasPrefix("ja") { return "ja_JP.UTF-8" }
    if lower.hasPrefix("ko") { return "ko_KR.UTF-8" }
    return identifier.contains(".") ? identifier : "\(identifier).UTF-8"
}
