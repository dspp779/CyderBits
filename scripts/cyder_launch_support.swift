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

    let passive: Bool
    init(passive: Bool = false) {
        self.passive = passive
        let width: CGFloat = 420
        let height: CGFloat = 150
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        if passive {
            window = NSPanel(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            (window as? NSPanel)?.hidesOnDeactivate = false
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        }
        window.title = "Cyder"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = passive ? .normal : .floating
        window.center()

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .regular
        progress.translatesAutoresizingMaskIntoConstraints = false
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { progress.startAnimation(nil) }
        progress.setAccessibilityLabel(passive ? "正在開啟 Windows 程式" : "準備進度")

        label = NSTextField(labelWithString: "正在準備…")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        detail = NSTextField(labelWithString: passive ? "可以切換到其他 App。程式視窗出現後，這裡會自動關閉。" : "請稍候，完成後會自動關閉。")
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
        if passive {
            // Finder launches leave Cyder inactive; orderFront(nil) then put
            // the panel behind the frontmost app and the launch looked stalled.
            // orderFrontRegardless shows it above other apps without taking focus.
            window.orderFrontRegardless()
        } else {
            activateCyderUI(dockVisible: false)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        window.displayIfNeeded()
    }

    func close() {
        progress.stopAnimation(nil)
        window.orderOut(nil)
    }
}

struct CyderOnscreenWindow {
    let pid: Int32
    let ownerName: String
    let windowID: UInt32
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

/// macOS 14 activation is cooperative: an app comes to the front only when the
/// active app yields to it. winemac.drv (CrossOver) posts
/// WineAppWillActivateNotification and every active Wine app in the same prefix
/// yields. Finder hands activation to Cyder, not to Wine, so Cyder must yield
/// the same way or a double-clicked program opens behind Finder without focus.
func cyderShouldYieldActivation(requestPrefix: String, requesterPID: Int32, ownPID: Int32,
                                isActive: Bool, bottlesRoot: String, sharedBottle: String) -> Bool {
    guard isActive, requesterPID > 0, requesterPID != ownPID, !requestPrefix.isEmpty else { return false }
    func canonical(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.hasSuffix("/") && standard.count > 1 ? String(standard.dropLast()) : standard
    }
    let prefix = canonical(requestPrefix), root = canonical(bottlesRoot)
    return prefix == canonical(sharedBottle) || (prefix.hasPrefix(root + "/") && !prefix.dropFirst(root.count + 1).contains("/"))
}

/// What Wine's loader logged when a program could not start (quiet launches run
/// with `err+module`). The process exit status keeps only the low byte of the
/// Windows status, so the log is the only place with the DLL name and full code.
struct CyderWineLoaderFailure: Equatable {
    var missingLibrary: String?
    var status: String?
}

func cyderWineLoaderFailure(inLog text: String) -> CyderWineLoaderFailure? {
    var failure = CyderWineLoaderFailure()
    for line in text.split(whereSeparator: \.isNewline) {
        guard line.contains("err:module:") else { continue }
        let row = String(line)
        if failure.missingLibrary == nil, let start = row.range(of: "err:module:import_dll Library "),
           let end = row.range(of: " ", range: start.upperBound..<row.endIndex) {
            failure.missingLibrary = String(row[start.upperBound..<end.lowerBound])
        }
        if failure.status == nil, row.contains("failed, status "), let range = row.range(of: "status ") {
            let code = row[range.upperBound...].prefix { $0.isHexDigit }
            if code.count == 8 { failure.status = "0x" + code.uppercased() }
        }
    }
    return failure.missingLibrary == nil && failure.status == nil ? nil : failure
}

func cyderWineLoaderFailure(logURL: URL) -> CyderWineLoaderFailure? {
    guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    return cyderWineLoaderFailure(inLog: String(decoding: data, as: UTF8.self))
}

/// Returns true when the request to bring `pid` forward was accepted.
@discardableResult
func yieldCyderActivation(toProcess pid: pid_t) -> Bool {
    guard #available(macOS 14.0, *), let application = NSRunningApplication(processIdentifier: pid) else { return false }
    NSApp.yieldActivation(to: application)
    return application.activate(from: NSRunningApplication.current, options: [])
}

/// Accept the activation Finder (or a browser for a URI) offers with a document
/// launch, so Cyder can pass it on to the program. When nothing was offered
/// (a background open), macOS declines the request and focus stays put.
func acceptCyderLaunchActivation() {
    if #available(macOS 14.0, *) { NSApp.activate() }
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
    // Callers supply an already-verified ownership set. Do not expand numeric
    // PIDs here after the caller has validated their process births.
    return cyderOnscreenWindows().filter { pids.contains($0.pid) }
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

private func cyderOnscreenWindows() -> [CyderOnscreenWindow] { readCyderOnscreenWindows() ?? [] }

func cyderVisibleSurfaces(ownedBy pids: Set<Int32>) -> [Int32: [UInt32]]? {
    guard let windows = readCyderOnscreenWindows() else { return nil }
    return Dictionary(grouping: windows.filter { pids.contains($0.pid) }, by: \.pid).mapValues { $0.map(\.windowID) }
}

private func readCyderOnscreenWindows() -> [CyderOnscreenWindow]? {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }
    var windows: [CyderOnscreenWindow] = []
    for window in info {
        let pid = Int32((window[kCGWindowOwnerPID as String] as? pid_t) ?? 0)
        guard pid > 0, let number = window[kCGWindowNumber as String] as? NSNumber,
              number.uint32Value != 0 else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0, (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { continue }
        let bounds = window[kCGWindowBounds as String] as? NSDictionary
        let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
        guard width >= 80, height >= 80 else { continue }
        let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
        windows.append(CyderOnscreenWindow(pid: pid, ownerName: ownerName, windowID: number.uint32Value))
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

/// Wine's crash dialog runs as `winedbg --auto <pid> <event>`. Wine starts it
/// detached (its parent is launchd, not the program) and shows it on a floating
/// window layer, so neither the process tree nor the program-window scan sees it.
func cyderIsWineCrashReporter(arguments: [String]) -> Bool {
    let words = arguments.flatMap { $0.split(separator: " ").map(String.init) }
    guard let first = words.first else { return false }
    let image = (first.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
    return (image == "winedbg" || image == "winedbg.exe") && words.contains("--auto")
}

func isWineCrashReporterProcess(_ pid: Int32) -> Bool { cyderIsWineCrashReporter(arguments: processArguments(pid)) }

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
        let count = children.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { continue }
        for child in children.prefix(min(children.count, Int(count))) where child > 0 {
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
    let isUnconfirmed: Bool
    let didStart: Bool

    init(
        status: Int32,
        terminationReason: Process.TerminationReason,
        logURL: URL,
        outputTail: String,
        machineResult: [String: String] = [:],
        isUnconfirmed: Bool = false,
        didStart: Bool = true
    ) {
        self.status = status
        self.terminationReason = terminationReason
        self.logURL = logURL
        self.outputTail = outputTail
        self.machineResult = machineResult
        self.isUnconfirmed = isUnconfirmed
        self.didStart = didStart
    }

    var succeeded: Bool {
        !isUnconfirmed && terminationReason == .exit && status == 0
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
        if (ext == "exe" || ext == "msi" || ext == "bat" || ext == "cmd"
            || ext == "lnk" || ext == "reg"),
           seen.insert(path).inserted {
            out.append(path)
        }
    }
    return out
}

func isMsiPath(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "msi"
}

func isScriptPath(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "bat" || ext == "cmd"
}

func isLnkPath(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "lnk"
}

func isRegPath(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "reg"
}

func wineLaunchTarget(for path: String) -> CyderWineLaunchTarget {
    if isMsiPath(path) { return .msi }
    if isScriptPath(path) { return .script }
    if isLnkPath(path) { return .link }
    if isRegPath(path) { return .reg }
    return .exe
}

enum CyderWineLaunchTarget {
    case exe
    case msi
    case script
    case link
    case reg
}
