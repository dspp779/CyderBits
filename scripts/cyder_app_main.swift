// Cyder.app entry — phased setup UI, then launch Windows EXE via cyder_launcher.sh.
import Cocoa
import Foundation
import UniformTypeIdentifiers

final class CyderSetupPanel {
    private let window: NSWindow
    private let spinner: NSProgressIndicator
    private let label: NSTextField

    init() {
        let width: CGFloat = 360
        let height: CGFloat = 120
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

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        label = NSTextField(labelWithString: "正在準備…")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(spinner)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
        ])
    }

    func setMessage(_ text: String) {
        label.stringValue = text
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        spinner.stopAnimation(nil)
        window.orderOut(nil)
    }
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false
    private var setupPanel: CyderSetupPanel?

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        pendingFiles.append(contentsOf: filenames)
        scheduleRun()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunch = true
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasPrefix("-psn_") {
                continue
            }
            if arg == "--args" {
                continue
            }
            pendingFiles.append(arg)
        }
        scheduleRun()
    }

    private func scheduleRun() {
        DispatchQueue.main.async { [weak self] in
            self?.runLauncherIfReady()
        }
    }

    private func runLauncherIfReady() {
        guard didFinishLaunch, !didRunLauncher else {
            return
        }
        didRunLauncher = true

        guard let resourcePath = Bundle.main.resourcePath else {
            fputs("Cyder: missing Resources path\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let context = CyderLaunchContext(resourcePath: resourcePath)
        guard FileManager.default.isExecutableFile(atPath: context.launcher) else {
            fputs("Cyder: missing launcher at \(context.launcher)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let status = self.runPhasedLaunch(context: context)
            DispatchQueue.main.async {
                self.hideSetup()
                NSApp.terminate(nil)
                exit(status)
            }
        }
    }

    private func runPhasedLaunch(context: CyderLaunchContext) -> Int32 {
        showSetup("正在檢查系統需求…")
        let rosettaCode = runLauncher(context: context, args: [
            context.launcher, "--ensure-rosetta-only",
        ])
        if rosettaCode != 0 {
            hideSetup()
            return rosettaCode
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
        let engineWine = support
            .appendingPathComponent("Engines/wine-x86_64/bin/wine")
        let bootstrapMarker = support
            .appendingPathComponent("SharedPrefix/.cyder-bootstrap-v1")

        let needsEngine = !FileManager.default.isExecutableFile(atPath: engineWine.path)
            || engineNeedsInstall(context: context, engineWine: engineWine)
        let needsBootstrap = !FileManager.default.fileExists(atPath: bootstrapMarker.path)

        if needsEngine || needsBootstrap {
            showSetup("建立遊戲引擎中…")
        }

        if needsEngine {
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--ensure-engine-only",
            ])
            if code != 0 {
                showAlert(
                    "Cyder 無法安裝遊戲引擎",
                    "請查看 ~/Library/Application Support/Cyder/Logs/engine-install.log"
                )
                return code
            }
        }

        var exePaths = normalizeExePaths(pendingFiles)
        if exePaths.isEmpty {
            hideSetup()
            guard let chosen = chooseExeOnMainThread() else {
                return 1
            }
            exePaths = [chosen]
        }

        if needsBootstrap {
            showSetup("準備 Windows 環境中…")
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only",
            ])
            if code != 0 {
                showAlert(
                    "Cyder 初始化失敗",
                    "請查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log"
                )
                return code
            }
        }

        if needsEngine || needsBootstrap {
            showSetup("正在啟動遊戲…")
        }
        var args = [context.launcher, "--engine-src", context.engineSrc, "--launch-exe", exePaths[0]]
        return runLauncher(context: context, args: args)
    }

    private func engineNeedsInstall(context: CyderLaunchContext, engineWine: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: context.engineVersionFile) else {
            return false
        }
        guard let bundled = try? String(contentsOfFile: context.engineVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundled.isEmpty
        else {
            return false
        }
        let installedFile = engineWine
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".cyder-engine-version")
        guard let installed = try? String(contentsOfFile: installedFile.path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !installed.isEmpty
        else {
            return true
        }
        return installed != bundled
    }

    private func onMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func showSetup(_ message: String) {
        onMainThread {
            if setupPanel == nil {
                setupPanel = CyderSetupPanel()
                setupPanel?.show()
            }
            setupPanel?.setMessage(message)
        }
    }

    private func hideSetup() {
        onMainThread {
            setupPanel?.close()
            setupPanel = nil
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        onMainThread {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func chooseExeOnMainThread() -> String? {
        var result: String?
        onMainThread {
            let panel = NSOpenPanel()
            panel.title = "Cyder"
            panel.message = "選擇 Windows 遊戲執行檔 (.exe)"
            panel.prompt = "開啟"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if #available(macOS 11.0, *) {
                var types: [UTType] = [.executable, .data]
                if let exeType = UTType(filenameExtension: "exe") {
                    types.insert(exeType, at: 0)
                }
                panel.allowedContentTypes = types
            }
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            result = url.path
        }
        return result
    }

    private func runLauncher(context: CyderLaunchContext, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = args
        process.environment = context.environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("Cyder: failed to run launcher: \(error)\n", stderr)
            return 1
        }
    }
}

private struct CyderLaunchContext {
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

private func resolveEngineSrc(resourcePath: String) -> String {
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

private func normalizeExePaths(_ paths: [String]) -> [String] {
    var out: [String] = []
    for raw in paths {
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.isEmpty {
            continue
        }
        if path.lowercased().hasSuffix(".exe") {
            out.append(path)
        }
    }
    return out
}

let app = NSApplication.shared
let delegate = CyderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
