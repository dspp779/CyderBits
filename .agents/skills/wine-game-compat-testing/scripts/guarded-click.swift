import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func refuse(_ message: String) -> Never {
    fputs("REFUSED: \(message)\n", stderr); exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 5 || (args.count == 6 && args[5] == "--click"),
      let pid = Int32(args[0]), pid > 0,
      let windowID = Int(args[1]), windowID > 0,
      let x = Double(args[3]), let y = Double(args[4]), x.isFinite, y.isFinite, x >= 0, y >= 0 else {
    refuse("usage: swift guarded-click.swift PID WINDOW_ID 'EXACT_TITLE' X_POINTS Y_POINTS [--click]")
}
let expectedTitle = args[2]
let relative = CGPoint(x: x, y: y)
let execute = args.count == 6
func rows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func boundsFor(_ row: [String: Any]) -> CGRect {
    guard row[kCGWindowOwnerPID as String] as? Int == Int(pid),
          row[kCGWindowNumber as String] as? Int == windowID,
          row[kCGWindowLayer as String] as? Int == 0,
          (row[kCGWindowName as String] as? String ?? "") == expectedTitle,
          let raw = row[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
          relative.x < bounds.width, relative.y < bounds.height else {
        refuse("PID, window ID, exact title, layer or coordinate mismatch; observe again")
    }
    return bounds
}
guard CGPreflightScreenCaptureAccess() else { refuse("screen recording permission missing; cannot verify window title") }
guard let initial = rows().first(where: { $0[kCGWindowNumber as String] as? Int == windowID }) else { refuse("target window absent") }
let initialBounds = boundsFor(initial)
guard execute else {
    print("PREVIEW ONLY: pid=\(pid) window=\(windowID) relative=\(relative) bounds=\(initialBounds); no activation or input sent")
    exit(0)
}
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { refuse("Accessibility or PostEvent permission missing") }
guard let app = NSRunningApplication(processIdentifier: pid) else { refuse("target process absent") }
app.activate(options: [])
let axApp = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
var axWindows: CFTypeRef?
if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows) == .success,
   let windows = axWindows as? [AXUIElement] {
    for window in windows {
        var number: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &number) == .success,
           let n = number as? NSNumber, n.intValue == windowID {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }
}
for _ in 0..<20 {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}
func verifiedPoint() -> CGPoint {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let top = rows().first(where: { $0[kCGWindowLayer as String] as? Int == 0 }) else { refuse("target not frontmost") }
    let bounds = boundsFor(top)
    guard bounds == initialBounds else { refuse("window moved or resized; capture again") }
    return CGPoint(x: bounds.minX + relative.x, y: bounds.minY + relative.y)
}
let point = verifiedPoint()
guard let source = CGEventSource(stateID: .hidSystemState),
      let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
      let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { refuse("event creation failed") }
down.setIntegerValueField(.mouseEventClickState, value: 1)
up.setIntegerValueField(.mouseEventClickState, value: 1)
move.post(tap: .cghidEventTap)
usleep(100000)
_ = verifiedPoint()
down.post(tap: .cghidEventTap)
usleep(150000)
up.post(tap: .cghidEventTap)
print("SENT ONE CLICK: pid=\(pid) window=\(windowID) relative=\(relative); verify with a fresh screenshot")
