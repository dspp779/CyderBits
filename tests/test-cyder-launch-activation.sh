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
