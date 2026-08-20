// Shared launch/process support for Cyder.app. Kept independent of Settings UI
// so the phased environment and Wine launch services can be tested separately.
import Cocoa
import Foundation

func activateCyderUI(dockVisible: Bool) {
    // Default is LSUIElement + accessory (no Dock). Promote to .regular while
    // the game library or Preferences is open so Cmd-Tab and the Dock work.
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

struct CyderOnscreenWindow {
    let pid: Int32
    let ownerName: String
}

/// True when the Wine process (or a child) already owns a normal onscreen window.
/// Some Win32 tools never post `WineAppWillActivateNotification` as a Dock app.
func wineProcessHasOnscreenWindow(pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    let owners = wineProcessTreeIDs(root: pid)
    return cyderOnscreenWindows().contains { owners.contains($0.pid) }
}

func wineRegularAppsLaunched(since start: Date) -> [NSRunningApplication] {
    let slop = start.addingTimeInterval(-2)
    return NSWorkspace.shared.runningApplications.filter { app in
        guard app.activationPolicy == .regular, isWineMacApplication(app) else { return false }
        if let launched = app.launchDate {
            return launched >= slop
        }
        if let started = processStartDate(app.processIdentifier) {
            return started >= slop
        }
        return false
    }
}

func isWineMacApplication(_ application: NSRunningApplication) -> Bool {
    isWineLoaderPath(application.executableURL?.path)
}

func wineHandoffOnscreenWindows(since start: Date) -> [CyderOnscreenWindow] {
    let slop = start.addingTimeInterval(-2)
    return cyderOnscreenWindows().filter { window in
        guard isWineLoaderPID(window.pid), kill(window.pid, 0) == 0 else { return false }
        guard let started = processStartDate(window.pid) else { return false }
        return started >= slop
    }
}

func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [CyderOnscreenWindow] {
    guard !pids.isEmpty else { return [] }
    var owners = pids
    for pid in pids where pid > 0 {
        owners.formUnion(wineProcessTreeIDs(root: pid))
    }
    return cyderOnscreenWindows().filter { owners.contains($0.pid) }
}

/// Onscreen Wine windows that belong to this bottle. Used after a launcher
/// such as GGMWebStart exits and the real game window is a different PID.
func wineOnscreenWindows(matchingPrefix prefix: String, extraPIDs: Set<Int32> = []) -> [CyderOnscreenWindow] {
    let standardized = (prefix as NSString).standardizingPath
    let selfPID = ProcessInfo.processInfo.processIdentifier
    var prefixCache: [Int32: String?] = [:]
    return cyderOnscreenWindows().filter { window in
        guard window.pid > 0, window.pid != selfPID else { return false }
        if extraPIDs.contains(window.pid) { return true }
        if let cached = prefixCache[window.pid] {
            return cached == standardized
        }
        let found = winePrefix(forProcess: window.pid)
        prefixCache[window.pid] = found
        return found == standardized
    }
}

func cyderUsefulWindowOwnerName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ignored: Set<String> = [
        "wine", "wine64", "wine64-preloader", "wine-preloader",
        "wineserver", "cyder", "cyderswift"
    ]
    if ignored.contains(trimmed.lowercased()) { return nil }
    return trimmed
}

func isWineLoaderPID(_ pid: Int32) -> Bool {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard result > 0 else { return false }
    return isWineLoaderPath(String(cString: buffer))
}

private func isWineLoaderPath(_ path: String?) -> Bool {
    guard let path, !path.isEmpty else { return false }
    let name = (path as NSString).lastPathComponent.lowercased()
    return path.contains("/lib/wine/") && name.hasPrefix("wine")
}

private func processStartDate(_ pid: Int32) -> Date? {
    var info = proc_bsdinfo()
    let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
    guard bytes >= Int32(MemoryLayout<proc_bsdinfo>.stride) else { return nil }
    return Date(
        timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    )
}

private func cyderOnscreenWindows() -> [CyderOnscreenWindow] {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }
    var windows: [CyderOnscreenWindow] = []
    for window in info {
        let pid = Int32((window[kCGWindowOwnerPID as String] as? pid_t) ?? 0)
        guard pid > 0 else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { continue }
        let bounds = window[kCGWindowBounds as String] as? NSDictionary
        let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
        guard width >= 80, height >= 80 else { continue }
        let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
        windows.append(CyderOnscreenWindow(pid: pid, ownerName: ownerName))
    }
    return windows
}

func winePrefix(forProcess pid: Int32) -> String? {
    let env = processEnvironment(pid)
    let raw = env["WINEPREFIX"] ?? env["CX_BOTTLE"]
    guard let raw, !raw.isEmpty else { return nil }
    return (raw as NSString).standardizingPath
}

func cyderWineArgvName(pid: Int32) -> String? {
    let args = processArguments(pid)
    for arg in args.reversed() {
        let leaf = URL(fileURLWithPath: arg).deletingPathExtension().lastPathComponent
        if let useful = cyderUsefulWindowOwnerName(leaf), useful.lowercased() != "wine" {
            return useful
        }
    }
    return nil
}

private func processArguments(_ pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var bufsize = 0
    guard sysctl(&mib, 3, nil, &bufsize, nil, 0) == 0, bufsize > MemoryLayout<Int32>.size else {
        return []
    }
    var buffer = [CChar](repeating: 0, count: bufsize)
    guard sysctl(&mib, 3, &buffer, &bufsize, nil, 0) == 0 else { return [] }
    return buffer.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return [] }
        let argc = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        var offset = MemoryLayout<Int32>.size
        func nextString() -> String? {
            let start = offset
            while offset < bufsize && base[offset] != 0 { offset += 1 }
            if offset <= start { return nil }
            let count = offset - start
            if offset < bufsize { offset += 1 }
            let bytes = UnsafeBufferPointer(start: base + start, count: count)
            return String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }
        _ = nextString()
        while offset < bufsize && base[offset] == 0 { offset += 1 }
        var args: [String] = []
        if argc > 0 {
            for _ in 0..<argc {
                guard offset < bufsize else { break }
                if let value = nextString() { args.append(value) }
            }
        }
        return args
    }
}

private func processEnvironment(_ pid: Int32) -> [String: String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var bufsize = 0
    guard sysctl(&mib, 3, nil, &bufsize, nil, 0) == 0, bufsize > MemoryLayout<Int32>.size else {
        return [:]
    }
    var buffer = [CChar](repeating: 0, count: bufsize)
    guard sysctl(&mib, 3, &buffer, &bufsize, nil, 0) == 0 else { return [:] }
    return parseProcArgsEnvironment(buffer, length: bufsize)
}

private func parseProcArgsEnvironment(_ buffer: [CChar], length: Int) -> [String: String] {
    guard length > MemoryLayout<Int32>.size else { return [:] }
    return buffer.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return [:] }
        let argc = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        var offset = MemoryLayout<Int32>.size
        func skipCString() {
            while offset < length && base[offset] != 0 { offset += 1 }
            if offset < length { offset += 1 }
        }
        skipCString()
        while offset < length && base[offset] == 0 { offset += 1 }
        if argc > 0 {
            for _ in 0..<argc {
                guard offset < length else { break }
                skipCString()
            }
        }
        while offset < length && base[offset] == 0 { offset += 1 }
        var env: [String: String] = [:]
        while offset < length {
            let start = offset
            skipCString()
            if offset <= start + 1 { break }
            let count = (offset - 1) - start
            let bytes = UnsafeBufferPointer(start: base + start, count: count)
            guard let line = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8),
                  let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }
}

func wineProcessTreeIDs(root: Int32) -> Set<Int32> {
    var seen: Set<Int32> = []
    var pending: [Int32] = [root]
    while let pid = pending.popLast() {
        if !seen.insert(pid).inserted { continue }
        var children = [pid_t](repeating: 0, count: 256)
        let bytes = children.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard bytes > 0 else { continue }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        for child in children.prefix(max(0, count)) where child > 0 {
            pending.append(child)
        }
    }
    return seen
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

func normalizeExePaths(_ paths: [String]) -> [String] {
    var out: [String] = []
    var seen: Set<String> = []
    for raw in paths {
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.isEmpty { continue }
        path = (path as NSString).standardizingPath
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "exe" || ext == "msi", seen.insert(path).inserted {
            out.append(path)
        }
    }
    return out
}

func isMsiPath(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "msi"
}

enum CyderWineLaunchTarget {
    case exe
    case msi
}
