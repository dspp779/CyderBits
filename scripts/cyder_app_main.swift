// Cyder.app entry — receive Finder "open document" events and forward to cyder_launcher.sh.
import Cocoa
import Foundation

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false

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

        let launcher = resourcePath + "/ogom-scripts/cyder_launcher.sh"
        let engineSrc = resourcePath + "/engine-payload"
        let entitlements = resourcePath + "/entitlements.plist"
        let libarchive = resourcePath + "/addons/libarchive"
        let contentsPath = (resourcePath as NSString).deletingLastPathComponent
        let appPath = (contentsPath as NSString).deletingLastPathComponent

        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            fputs("Cyder: missing launcher at \(launcher)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["CYDER_ENGINE_SRC"] = engineSrc
        env["CYDER_SCRIPTS"] = resourcePath + "/ogom-scripts"
        env["CYDER_LIBARCHIVE_SRC"] = libarchive
        env["OGOM"] = resourcePath
        env["WINE_INSTALL"] = engineSrc
        env["ENTITLEMENTS_PLIST"] = entitlements
        env["CYDER_ENTITLEMENTS"] = entitlements
        env["CYDER_APP"] = appPath
        env["CYDER_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? "local.cyder.app"

        var args = [launcher, "--engine-src", engineSrc]
        args.append(contentsOf: normalizeExePaths(pendingFiles))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = args
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
            NSApp.terminate(nil)
            exit(process.terminationStatus)
        } catch {
            fputs("Cyder: failed to run launcher: \(error)\n", stderr)
            NSApp.terminate(nil)
            exit(1)
        }
    }
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
