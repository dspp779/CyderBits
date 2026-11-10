import Foundation

// Exercises cyder_scrolling.swift against real user.reg text. A recording Wine
// double stands in for reg.exe; it is only reached for a running prefix.
typealias S = CyderScrollingRegistry
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { failures += 1; FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)) }
}
func expectFailure(_ message: String, _ body: () throws -> Void) {
    do { try body(); check(false, "expected failure: \(message)") } catch {}
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let base = """
WINE REGISTRY Version 2
;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000

#arch=win64

[Software\\\\Wine\\\\AppDefaults\\\\cxwget.exe\\\\DllOverrides] 1793252819
#time=1dd6768ea0379e4
"wininet"="builtin"

[Software\\\\Wine\\\\Mac Driver] 1793287839
#time=1dd67ba73cc05b4
"RetinaMode"="n"
"UsePreciseScrolling"="Y"

"""
var calls: [[String]] = []
var runnerStatus: Int32 = 0
let runner: S.WineRunner = { arguments in calls.append(arguments); return (runnerStatus, "reg failed") }
func fresh(_ name: String, _ text: String = base) -> URL {
    let prefix = root.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: prefix)
    try! FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: prefix.appendingPathComponent("user.reg"))
    calls.removeAll(); runnerStatus = 0
    return prefix
}
func reg(_ prefix: URL) -> String { try! String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) }
func value(_ prefix: URL, _ name: String) -> String? { try! S.RegistryFile.read(prefix.appendingPathComponent("user.reg")).value(name) }
func apply(_ mode: S.Mode, _ prefix: URL, _ name: String = "MapleStory.exe", running: Bool = false) throws -> S.Outcome {
    try S.apply(mode: mode, prefix: prefix, name: name, prefixRunning: running, runner: runner, isServerRunning: { _ in false })
}

// Idle prefix: no Wine process ever; first apply backs up, then edits the file.
var prefix = fresh("idle")
var outcome = try apply(.traditional, prefix)
check(outcome == .init(value: "N", wineCalls: 0, fileWrites: 2), "first apply: backup + one file edit, \(outcome)")
check(value(prefix, "MapleStory.exe") == "N", "value written")
check(reg(prefix).contains("[Software\\\\Wine\\\\AppDefaults\\\\MapleStory.exe\\\\Mac Driver] "), "Wine section header format")
check(reg(prefix).contains("\"UsePreciseScrolling\"=\"Y\""), "prefix-wide default untouched")
check(reg(prefix).contains("\"wininet\"=\"builtin\""), "other keys untouched")
let afterFirst = reg(prefix)
// Steady state (every later launch): already matching, so zero work.
outcome = try apply(.traditional, prefix)
check(outcome == .init(value: "N", wineCalls: 0, fileWrites: 0), "matching value costs nothing, \(outcome)")
check(reg(prefix) == afterFirst, "matching value does not rewrite user.reg")
check(calls.isEmpty, "idle prefix never calls Wine")
// Switch and restore to the absent original.
outcome = try apply(.precise, prefix)
check(outcome.fileWrites == 1 && value(prefix, "MapleStory.exe") == "Y", "switch edits in place")
check(reg(prefix).components(separatedBy: "AppDefaults\\\\MapleStory.exe").count == 2, "no duplicate section")
outcome = try apply(.restore, prefix)
check(outcome.value == nil && value(prefix, "MapleStory.exe") == nil, "restore removes value")
check(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".cyder-maplestory-scrolling/original.json").path), "backup removed after restore")
let noop = try apply(.restore, prefix)
check(noop == .init(value: nil, wineCalls: 0, fileWrites: 0), "restore without baseline is a no-op")

// Existing original is preserved and restored; names are case-insensitive.
let withOriginal = base + "[Software\\\\Wine\\\\AppDefaults\\\\maplestory.EXE\\\\Mac Driver] 1\n#time=1\n\"RetinaMode\"=\"y\"\n\"UsePreciseScrolling\"=\"Y\"\n"
prefix = fresh("original", withOriginal)
_ = try apply(.traditional, prefix)
check(value(prefix, "MapleStory.exe") == "N", "existing section updated case-insensitively")
check(reg(prefix).contains("\"RetinaMode\"=\"y\""), "sibling value retained")
_ = try apply(.restore, prefix)
check(value(prefix, "MapleStory.exe") == "Y", "original restored")

// Other EXEs use a hashed state directory and do not leak into MapleStory.
prefix = fresh("shared")
_ = try apply(.traditional, prefix, "MapleStory.exe")
_ = try apply(.precise, prefix, "OtherGame.exe")
check(value(prefix, "MapleStory.exe") == "N" && value(prefix, "OtherGame.exe") == "Y", "per-EXE values")
let hashed = try FileManager.default.contentsOfDirectory(atPath: prefix.appendingPathComponent(".cyder-scrolling").path)
check(hashed.count == 1 && hashed[0].count == 64, "hashed state dir")

// Former Ruby backup format is still honoured.
prefix = fresh("legacy")
let legacyState = prefix.appendingPathComponent(".cyder-maplestory-scrolling")
try FileManager.default.createDirectory(at: legacyState, withIntermediateDirectories: true)
try Data(#"{"version":1,"original":"\"Y\""}"#.utf8).write(to: legacyState.appendingPathComponent("original.json"))
_ = try apply(.traditional, prefix)
_ = try apply(.restore, prefix)
check(value(prefix, "MapleStory.exe") == "Y", "legacy backup restored")

// Running prefix: exactly one reg.exe call, never a file edit.
prefix = fresh("running")
let before = reg(prefix)
outcome = try apply(.traditional, prefix, running: true)
check(outcome == .init(value: "N", wineCalls: 1, fileWrites: 1), "running prefix uses one reg call, \(outcome)")
check(calls == [["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\MapleStory.exe\\Mac Driver", "/v", "UsePreciseScrolling", "/t", "REG_SZ", "/d", "N", "/f"]], "reg add arguments \(calls)")
check(reg(prefix) == before, "running prefix file untouched")
calls.removeAll()
_ = try apply(.restore, prefix, running: true)
check(calls.first?.prefix(2) == ["reg", "delete"], "restore to absent deletes the value")
// Once an idle run has seen the flushed file, a running prefix with a matching
// value needs no Wine call at all.
prefix = fresh("running-steady")
_ = try apply(.traditional, prefix)
calls.removeAll()
outcome = try apply(.traditional, prefix, running: true)
check(outcome.wineCalls == 0 && calls.isEmpty, "running prefix with flushed matching value costs nothing")
// A server appearing during an idle edit falls back to reg.exe as well.
prefix = fresh("race")
var probes = 0
outcome = try S.apply(mode: .traditional, prefix: prefix, name: "Game.exe", prefixRunning: false, runner: runner,
                      isServerRunning: { _ in probes += 1; return probes > 2 })
check(outcome.wineCalls == 1, "server started during edit also sets live value")
// Non-ASCII names are left to reg.exe instead of rewriting escaped key names.
prefix = fresh("unicode")
outcome = try apply(.traditional, prefix, "新楓之谷.exe")
check(outcome.wineCalls == 1, "non-ASCII EXE uses reg.exe")

// Failures never change the registry and keep the baseline for retry.
prefix = fresh("failure")
runnerStatus = 1
expectFailure("reg failure") { _ = try apply(.traditional, prefix, running: true) }
check(FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".cyder-maplestory-scrolling/original.json").path), "baseline retained")
runnerStatus = 0
for bad in ["dword:00000001", "\"a\\\\b\"", "str(2):\"Y\""] {
    prefix = fresh("unsupported", base + "[Software\\\\Wine\\\\AppDefaults\\\\MapleStory.exe\\\\Mac Driver] 1\n\"UsePreciseScrolling\"=\(bad)\n")
    let original = reg(prefix)
    expectFailure("unsupported \(bad)") { _ = try apply(.traditional, prefix) }
    check(reg(prefix) == original, "unsupported value untouched")
}
prefix = fresh("duplicate", base + "[Software\\\\Wine\\\\AppDefaults\\\\MapleStory.exe\\\\Mac Driver] 1\n\"UsePreciseScrolling\"=\"Y\"\n\n[Software\\\\Wine\\\\AppDefaults\\\\MAPLESTORY.exe\\\\Mac Driver] 2\n\"UsePreciseScrolling\"=\"N\"\n")
expectFailure("duplicate sections") { _ = try apply(.traditional, prefix) }
prefix = fresh("corrupt")
try FileManager.default.createDirectory(at: prefix.appendingPathComponent(".cyder-maplestory-scrolling"), withIntermediateDirectories: true)
try Data("{\"version\":1,\"original\":\"\\\"]\\n[Evil\\\"\"}".utf8).write(to: prefix.appendingPathComponent(".cyder-maplestory-scrolling/original.json"))
expectFailure("corrupt backup") { _ = try apply(.restore, prefix) }
for name in ["../x.exe", "a\\b.exe", "game.bat", "[x].exe", "bad\".exe"] {
    expectFailure("invalid name \(name)") { _ = try apply(.traditional, fresh("names"), name) }
}
let empty = root.appendingPathComponent("uninitialized")
try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
expectFailure("uninitialized prefix") { _ = try apply(.traditional, empty) }

if failures > 0 { exit(1) }
print("PASS scrolling registry: zero-Wine idle/steady paths, single reg.exe for running prefixes, backup/restore, legacy baseline, failure isolation")
