// Minimal Universal launcher experiment for Wine/macOS activation.
//
// Usage:
//   cyder-frontmost-test <wine> <wineprefix> <exe>
//
// This intentionally does not run the Cyder setup scripts. It only measures
// whether NSRunningApplication can find and activate the Wine process.
import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: cyder-frontmost-test <wine> <wineprefix> <exe>\n", stderr)
    exit(64)
}

let wine = CommandLine.arguments[1]
let prefix = CommandLine.arguments[2]
let exe = CommandLine.arguments[3]

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
process.arguments = ["-x86_64", wine, exe]
var environment = ProcessInfo.processInfo.environment
environment["WINEPREFIX"] = prefix
environment["PATH"] = "\((wine as NSString).deletingLastPathComponent):\(environment["PATH"] ?? "")"
process.environment = environment

do {
    try process.run()
} catch {
    fputs("failed to launch Wine: \(error)\n", stderr)
    exit(1)
}

let pid = process.processIdentifier
print("wine_pid=\(pid)")
fflush(stdout)

for _ in 0..<50 {
    if let app = NSRunningApplication(processIdentifier: pid) {
        let name = app.localizedName ?? "?"
        let activated = app.activate(options: [.activateAllWindows])
        print("target=\(name) active=\(app.isActive) activate=\(activated)")
        fflush(stdout)
        if app.isActive {
            break
        }
    }
    if !process.isRunning {
        break
    }
    usleep(100_000)
}

process.waitUntilExit()
print("exit=\(process.terminationStatus)")
fflush(stdout)
