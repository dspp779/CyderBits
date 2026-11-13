import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Send one key press (or one timed hold) to a verified Wine game window.
// Same target checks as guarded-click.swift: PID, window ID, exact title,
// layer 0, frontmost, top layer-0 window, unchanged bounds. Preview by default.

func refuse(_ message: String) -> Never {
    fputs("REFUSED: \(message)\n", stderr); exit(2)
}

// macOS virtual key codes (ANSI layout). Command is left out on purpose:
// Cmd+key reaches macOS shortcuts (quit, hide, switch app), not the game.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "`": 50,
    "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
    "shift": 56, "option": 58, "alt": 58, "control": 59, "ctrl": 59,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "insert": 114, "home": 115, "pageup": 116, "delete": 117, "end": 119, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
]
let modifierFlags: [CGKeyCode: CGEventFlags] = [56: .maskShift, 58: .maskAlternate, 59: .maskControl]
let maxHoldMS = 10_000
let usage = "usage: swift guarded-key.swift PID WINDOW_ID 'EXACT_TITLE' KEY [--hold MS] [--send] | --list-keys"

var args = Array(CommandLine.arguments.dropFirst())
if args == ["--list-keys"] {
    for name in keyCodes.keys.sorted() { print(name) }
    exit(0)
}
var execute = false
var holdMS = 80
if let i = args.firstIndex(of: "--send") { execute = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--hold") {
    guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 0, value <= maxHoldMS else {
        refuse("--hold needs whole milliseconds from 0 to \(maxHoldMS)")
    }
    holdMS = value
    args.removeSubrange(i...(i + 1))
}
guard args.count == 4, let pid = Int32(args[0]), pid > 0,
      let windowID = Int(args[1]), windowID > 0 else { refuse(usage) }
let expectedTitle = args[2]
let keyName = args[3].lowercased()
guard let keyCode = keyCodes[keyName] else {
    refuse("unknown key '\(args[3])'; see --list-keys (Command is never sent)")
}

func rows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func boundsFor(_ row: [String: Any]) -> CGRect? {
    guard row[kCGWindowOwnerPID as String] as? Int == Int(pid),
          row[kCGWindowNumber as String] as? Int == windowID,
          row[kCGWindowLayer as String] as? Int == 0,
          (row[kCGWindowName as String] as? String ?? "") == expectedTitle,
          let raw = row[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
    return bounds
}
guard CGPreflightScreenCaptureAccess() else { refuse("screen recording permission missing; cannot verify window title") }
guard let initial = rows().first(where: { $0[kCGWindowNumber as String] as? Int == windowID }) else { refuse("target window absent") }
guard let initialBounds = boundsFor(initial) else { refuse("PID, window ID, exact title or layer mismatch; observe again") }
guard execute else {
    print("PREVIEW ONLY: pid=\(pid) window=\(windowID) key=\(keyName) code=\(keyCode) hold_ms=\(holdMS) bounds=\(initialBounds); no activation or input sent")
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
func targetStillValid() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let top = rows().first(where: { $0[kCGWindowLayer as String] as? Int == 0 }),
          let bounds = boundsFor(top) else { return false }
    return bounds == initialBounds
}
guard targetStillValid() else { refuse("target not frontmost, not the top window, or moved; capture again") }

guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { refuse("event creation failed") }
if let flag = modifierFlags[keyCode] {
    // A lone modifier reaches apps as a flags-changed event, not key down/up.
    down.type = .flagsChanged; down.flags = flag
    up.type = .flagsChanged; up.flags = []
} else {
    down.flags = []; up.flags = []
}

// From key down on, every exit path must release the key.
var released = false
func release() {
    if !released { up.post(tap: .cghidEventTap); released = true }
}
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let handler = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    handler.setEventHandler { release(); fputs("INTERRUPTED: key released\n", stderr); exit(130) }
    handler.resume()
    return handler
}

down.post(tap: .cghidEventTap)
let deadline = Date(timeIntervalSinceNow: Double(holdMS) / 1000)
while Date() < deadline {
    RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.05)))
    if !targetStillValid() {
        release()
        refuse("target lost focus or moved during hold; key released early")
    }
}
release()
print("SENT ONE KEY: pid=\(pid) window=\(windowID) key=\(keyName) hold_ms=\(holdMS); verify with a fresh screenshot")
