#!/usr/bin/env bash
# A program opened from Finder must come to the front, and a program that
# cannot start must say why.
#
# macOS 14 activation is cooperative. Finder yields activation to Cyder, not to
# Wine; winemac.drv asks active Wine apps in its prefix to yield
# (WineAppWillActivateNotification). Cyder ignored that request, so every
# double-clicked program opened behind Finder without keyboard focus and its
# launch was never confirmed ("presented without activation").
#
# Quiet launches ran with WINEDEBUG=-all, so a missing DLL showed only
# "status: 53" (the low byte of 0xC0000135).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/main.swift" <<'EOF'
import Foundation
import CoreGraphics
func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: \(message)"); exit(1) } }
let root = "/Users/u/Library/Application Support/Cyder/bottles"
let shared = root + "/shared"
func yields(_ prefix: String, pid: Int32 = 500, active: Bool = true) -> Bool {
    cyderShouldYieldActivation(requestPrefix: prefix, requesterPID: pid, ownPID: 42, isActive: active,
                               bottlesRoot: root, sharedBottle: shared)
}
check(yields(shared), "an active Cyder yields to a program in its shared bottle")
check(yields(shared + "/"), "a trailing slash is the same prefix")
check(yields(root + "/other"), "any Cyder bottle counts")
check(!yields(shared, active: false), "an inactive Cyder has nothing to yield (and must not take focus)")
check(!yields(shared, pid: 42), "Cyder never yields to itself")
check(!yields(shared, pid: 0), "a missing PID is ignored")
check(!yields(""), "a request without a prefix is ignored")
check(!yields("/Users/u/.wine"), "another Wine installation's prefix is not ours")
check(!yields(root + "/shared/drive_c"), "a path inside a bottle is not a bottle")
check(!yields(root), "the bottles folder itself is not a bottle")

let log = """
cyder-cxcompatdb:info: loaded CompatDB v1 rules=3
0024:err:module:import_dll Library cydermissing.dll (which is needed by L"Z:\\\\games\\\\missingdll.exe") not found
0024:err:module:loader_init Importing dlls for L"Z:\\\\games\\\\missingdll.exe" failed, status c0000135
"""
let failure = cyderWineLoaderFailure(inLog: log)
check(failure?.missingLibrary == "cydermissing.dll", "the missing DLL is named: \(String(describing: failure))")
check(failure?.status == "0xC0000135", "the full Windows status is kept: \(String(describing: failure))")
check(cyderWineLoaderFailure(inLog: "cyder-cxcompatdb:info: loaded\nwineserver: atexit pid=1\n") == nil,
      "a log without loader errors gives no loader failure")
let statusOnly = cyderWineLoaderFailure(inLog: "0030:err:module:loader_init Importing dlls for L\"a.exe\" failed, status c0000142\n")
check(statusOnly == CyderWineLoaderFailure(missingLibrary: nil, status: "0xC0000142"), "status without a library")
check(cyderIsWineCrashReporter(arguments: ["winedbg --auto 32 52"]), "Wine's crash dialog as one rewritten argv string")
check(cyderIsWineCrashReporter(arguments: ["C:\\windows\\system32\\winedbg.exe", "--auto", "32", "52"]), "crash dialog as split arguments")
check(!cyderIsWineCrashReporter(arguments: ["winedbg"]), "an interactive winedbg is not a crash dialog")
check(!cyderIsWineCrashReporter(arguments: ["C:\\games\\SteamSetup.exe"]), "a program is not a crash dialog")
check(!cyderIsWineCrashReporter(arguments: []), "unreadable arguments are not a crash dialog")
// Wine window levels (winemac.drv minimumLevelForActive:). A fullscreen game
// that became the active app sits on 26; it must still count as a window.
let shield = 1000
func accepts(_ layer: Int, onscreen: Bool = true, alpha: Double = 1, w: Double = 1680, h: Double = 945) -> Bool {
    cyderAcceptsWineWindow(layer: layer, onscreen: onscreen, alpha: alpha, width: w, height: h, shieldingLevel: shield)
}
check(accepts(0), "a normal Wine window counts")
check(accepts(3), "a topmost (floating) Wine window counts")
check(accepts(26), "an active fullscreen Wine window (NSStatusWindowLevel + 1) counts")
check(accepts(27), "an active topmost fullscreen Wine window counts")
check(accepts(shield + 1) && accepts(shield + 2), "a window over captured displays counts")
check(!accepts(25) && !accepts(101) && !accepts(-20) && !accepts(shield), "other levels are not Wine program windows")
check(!accepts(0, onscreen: false), "an off-screen (hidden helper) window does not count")
check(!accepts(0, alpha: 0), "a transparent window does not count")
check(!accepts(26, w: 500, h: 40) && !accepts(0, w: 79, h: 300), "a window under 80 x 80 does not count")
check(cyderIsWineWindowLevel(Int(CGShieldingWindowLevel()) + 1), "the real shielding level is used by default")
// Duplicate launch requests (same program and arguments) are dropped while one
// is waiting, preparing, launching or started in the last 10 s.
let exe = "/Users/u/Library/Application Support/Cyder/bottles/shared/drive_c/Games/Game.exe"
let k = cyderLaunchKey(executable: exe, arguments: nil, isURI: false)
check(k == cyderLaunchKey(executable: exe.uppercased(), arguments: nil, isURI: false), "path case does not make a new request")
check(k == cyderLaunchKey(executable: exe.replacingOccurrences(of: "/Games/", with: "/Games/./"), arguments: nil, isURI: false), "an equivalent path is the same key")
check(k != cyderLaunchKey(executable: exe, arguments: ["-otp", "123"], isURI: false), "new arguments (a Beanfun login) are a new request")
check(cyderLaunchKey(executable: exe, arguments: ["a b"], isURI: false) != cyderLaunchKey(executable: exe, arguments: ["a", "b"], isURI: false), "argument boundaries are kept")
check(cyderLaunchKey(executable: "gamaniagames://x", arguments: nil, isURI: true) != cyderLaunchKey(executable: "gamaniagames://y", arguments: nil, isURI: true), "different URIs differ")
func dup(queued: [String] = [], preparing: [String] = [], launching: String? = nil, started: TimeInterval? = nil, now: TimeInterval = 100) -> Bool {
    cyderIsDuplicateLaunch(k, queued: queued, preparing: preparing, launching: launching,
                           recentStarts: started.map { [k: $0] } ?? [:], now: now)
}
check(!dup(), "a first request runs")
check(dup(queued: [k]), "a request already waiting in the queue is dropped")
check(dup(preparing: [k]), "a request being prepared is dropped")
check(dup(launching: k), "a request for the program now launching is dropped")
check(dup(started: 95), "a request 5 s after the same program started is dropped")
check(!dup(started: 85), "a request 15 s after the program started runs (a second copy on purpose)")
check(!dup(queued: ["other"], preparing: ["other"], launching: "other", started: nil), "other programs do not block it")
print("ok")
EOF
swiftc -module-cache-path "$TMP/mc" -o "$TMP/harness" "$ROOT/scripts/cyder_launch_support.swift" "$TMP/main.swift" 2>"$TMP/build.log" || {
  cat "$TMP/build.log" >&2; exit 1; }
assert_eq "$("$TMP/harness")" "ok" "activation and loader-failure decisions"

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
will_activate="$(awk '/@objc private func wineAppWillActivate/{p=1} p{print} p && /^    }$/{exit}' "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$will_activate" "cyderShouldYieldActivation(" "Wine's activation request is checked"
assert_contains "$will_activate" "yieldCyderActivation(toProcess: pid)" "Cyder yields to the requesting program"
assert_contains "$will_activate" "isWineCrashReporterProcess(pid)" "Wine's crash dialog is recognised"
assert_contains "$will_activate" "self.dismissLaunchProgress(for: owner)" "the starting panel closes for the crash dialog"
starting="$(awk '/private func presentExternalLaunchStarting/{p=1} p{print} p && /^    }$/{exit}' "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$starting" "acceptCyderLaunchActivation()" "a Finder/URI launch accepts the activation it was offered"
assert_contains "$app" "code: \"CYD-WIN-004\"" "a missing DLL has its own error"
# Wine yields activation before its window is on screen, so the launch is
# activated when the presented program is or becomes the frontmost app.
assert_contains "$app" "waiter.markPresented(process: pid)" "the presented window names its program"
did_activate="$(awk '/@objc private func wineWorkspaceDidActivate/{p=1} p{print} p && /^    }$/{exit}' "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$did_activate" "wineActivationWaiter?.noteFrontmost(pid)" "a program reaching the front activates its launch"
assert_contains "$(cat "$ROOT/scripts/cyder-common.sh")" 'local wine_debug="-all,err+module"' \
  "quiet launches keep Wine's loader errors"

echo "PASS: launches yield activation to the program, close progress for a crash dialog and name a missing DLL"

# Each launch completion moves the queue before it shows a dialog: an error
# dialog used to hold every later request until it was closed.
python3 - "$ROOT/scripts/cyder_app_main.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
for marker in ("case .failure(let failure):\n                    self.presentLaunchDialog { self.presentFailure(failure) }",
               "if case .failure(let failure) = outcome { self.presentLaunchDialog { self.presentFailure(failure) } }"):
    i = src.index(marker)
    block = src[src.rindex("DispatchQueue.main.async {", 0, i):i]
    assert "self.launchNextQueuedExecutableIfReady()" in block, f"queue must advance before: {marker}"
    tail = src[i:src.index("\n    }\n", i)]
    assert "launchNextQueuedExecutableIfReady" not in tail, f"queue advanced again after dialog: {marker}"
assert "cyderIsDuplicateLaunch(key" in src, "queued requests are de-duplicated"
# A dialog run inside a DispatchQueue.main block holds the main queue (request
# delivery and the environment lock) until it closes; launch dialogs go
# through a run-loop block instead.
assert "RunLoop.main.perform(inModes: [.common], block: present)" in src
for bad in ("case .failure(let failure):\n                    self.presentFailure(failure)",
            "= outcome { self.presentFailure(failure) }"):
    assert bad not in src, "launch failure shown inside a main-queue block: " + bad
print("queue order ok")
PY

# The mechanism itself: main-queue work runs under a dialog opened from a
# run-loop block, and does not under one opened inside a main-queue block.
cat >"$TMP/modal.swift" <<'SWIFT'
import Cocoa
let inline = CommandLine.arguments[1] == "inline"
signal(SIGALRM) { _ in print("blocked"); exit(0) }
alarm(5)
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
func show() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { DispatchQueue.main.async { print("ran"); exit(0) } }
    let alert = NSAlert(); alert.window.alphaValue = 0; _ = alert.runModal()
}
DispatchQueue.main.async { if inline { show() } else { RunLoop.main.perform(inModes: [.common]) { show() } } }
app.run()
SWIFT
swiftc -module-cache-path "$TMP/mc" -o "$TMP/modal" "$TMP/modal.swift" 2>>"$TMP/build.log"
assert_eq "$("$TMP/modal" perform)" ran "main-queue work runs under a dialog opened from a run-loop block"
assert_eq "$("$TMP/modal" inline)" blocked "a dialog inside a main-queue block holds the main queue (why presentLaunchDialog exists)"


# A launcher that exits non-zero while its successor (the real program) is
# alive is not a failure until the successor ends without a window.
mkdir -p "$TMP/handoff-src"
cat >"$TMP/handoff-src/main.swift" <<'SWIFT'
import Foundation
let mode = CommandLine.arguments[1]
let observer = CyderLaunchObserver(successorSettle: 0.3)
let waiter = WineActivationWaiter(prefix: "/tmp/p")
let start = ProcessInfo.processInfo.systemUptime
let lock = NSLock(); var rootStatusValue: Int32? = nil
func rootStatus() -> Int32? { lock.lock(); defer { lock.unlock() }; return rootStatusValue }
DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { lock.lock(); rootStatusValue = 3; lock.unlock() }
switch mode {
case "successor-window":   // successor alive, then its window appears
    observer.noteSuccessors(alive: true)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { waiter.markPresented() }
case "successor-ends":     // successor alive, exits without a window
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { observer.noteSuccessors(alive: true) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { observer.noteSuccessors(alive: false) }
case "late-successor":     // successor recorded shortly after the root exit
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { observer.noteSuccessors(alive: true) }
case "successor-forever":  // successor never shows a window
    observer.noteSuccessors(alive: true)
default: break             // no successor
}
let deadline = start + (mode == "successor-forever" ? 1.5 : 5)
Task {
    let result = await observer.wait(until: deadline, signal: waiter, read: { .init(rootStatus: rootStatus(), lifecycle: nil) })
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    print("\(result) \(elapsed >= 0.9 ? "late" : "early")")
    exit(0)
}
dispatchMain()
SWIFT
swiftc -module-cache-path "$TMP/mc" -o "$TMP/handoff" "$ROOT/scripts/cyder_execution_phase.swift" \
    "$ROOT/scripts/cyder_launch_observer.swift" "$TMP/handoff-src/main.swift" 2>>"$TMP/build.log" || {
    cat "$TMP/build.log"; exit 1; }
assert_eq "$("$TMP/handoff" none)" "rootFailed(3) early" "a root failure with no successor is still reported after the settle time"
assert_eq "$("$TMP/handoff" late-successor)" "unconfirmed late" "a successor recorded during the settle time holds the failure"
assert_eq "$("$TMP/handoff" successor-window)" "presented late" "a successor's window after the launcher failed is a started launch"
assert_eq "$("$TMP/handoff" successor-ends)" "rootFailed(3) late" "the failure is reported when the successor ends without a window"
assert_eq "$("$TMP/handoff" successor-forever)" "unconfirmed late" "a successor alive until the deadline ends unconfirmed, no dialog"
assert_contains "$app" "observer.noteSuccessors(alive: alive)" "the app tells the observer when the launch has a live successor"
assert_contains "$(cat "$ROOT/scripts/cyder_status_item.swift")" "onLiveSuccessorsChange?(successors)" "the status item reports launches with live successors"
