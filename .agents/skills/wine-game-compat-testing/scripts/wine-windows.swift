import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
var selectedPID: Int?
if !args.isEmpty {
    guard args.count == 2, args[0] == "--pid", let value = Int(args[1]), value > 0, value <= Int(Int32.max) else {
        fputs("Usage: swift wine-windows.swift [--pid PID]\n", stderr); exit(2)
    }
    selectedPID = value
}
let apps = NSWorkspace.shared.runningApplications
var winePIDs = Set<Int>()
var appRows = [[String: Any]]()
for app in apps {
    let name = app.localizedName ?? ""
    let path = app.executableURL?.path ?? ""
    let pid = Int(app.processIdentifier)
    let matched = selectedPID.map { $0 == pid } ?? (name.lowercased().contains("wine") || path.lowercased().contains("/wine"))
    if matched {
        winePIDs.insert(pid)
        appRows.append(["pid": pid, "name": name, "executable": path, "bundle_id": app.bundleIdentifier ?? "", "activation_policy": app.activationPolicy.rawValue])
    }
}
var windowRows = [[String: Any]]()
for row in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
    guard let pid = row[kCGWindowOwnerPID as String] as? Int else { continue }
    let owner = row[kCGWindowOwnerName as String] as? String ?? ""
    let matched = selectedPID.map { $0 == pid } ?? (winePIDs.contains(pid) || owner.lowercased().contains("wine"))
    if matched {
        windowRows.append(["pid": pid, "window_id": row[kCGWindowNumber as String] ?? 0,
                           "owner": owner, "title": row[kCGWindowName as String] ?? "",
                           "layer": row[kCGWindowLayer as String] ?? -1,
                           "bounds": row[kCGWindowBounds as String] ?? [:]])
    }
}
let result: [String: Any] = ["accessibility": AXIsProcessTrusted(), "screen_capture": CGPreflightScreenCaptureAccess(),
                            "post_events": CGPreflightPostEventAccess(), "applications": appRows, "windows": windowRows]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
