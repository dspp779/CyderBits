import Foundation

// Real kqueue events: a ticket rename in the directory and a watched process
// exit each trigger exactly one coalesced re-read; nothing fires while idle.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var events = 0
var failures = 0
func check(_ ok: Bool, _ message: String, line: Int = #line) {
    if !ok { failures += 1; FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)) }
}
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let watch = CyderExecutionWatch(directory: root, fallback: 0)
watch.onChange = { events += 1 }
watch.update(unresolved: true, pids: [])
check(watch.isWatchingDirectory && !watch.hasFallback, "directory watched, fallback disabled for test")
spin(0.3)
check(events == 0, "no event while idle (no polling)")

// Atomic ticket write: temp file + rename, exactly like CyderExecutionOwner.
try Data("{}".utf8).write(to: root.appendingPathComponent(".write-1"))
rename(root.appendingPathComponent(".write-1").path, root.appendingPathComponent("ticket.json").path)
spin(0.3)
check(events == 1, "ticket rename triggers one coalesced refresh (\(events))")

// Process exit of a recorded owner triggers a refresh without any file write.
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["0.4"]
try child.run()
watch.update(unresolved: true, pids: [child.processIdentifier])
check(watch.watchedProcesses == [child.processIdentifier], "owner pid watched")
spin(0.2); let beforeExit = events
spin(0.6)
check(events == beforeExit + 1, "process exit triggers refresh")
check(watch.watchedProcesses.isEmpty, "exited process source released")

// A PID that is already gone triggers immediately (kqueue cannot report it).
watch.update(unresolved: true, pids: [99999])
spin(0.2)
check(events == beforeExit + 2, "already-exited pid triggers refresh")

// Resolved tickets drop process watches; stop releases everything.
watch.update(unresolved: false, pids: [])
check(watch.watchedProcesses.isEmpty, "no watches once resolved")
watch.stop()
try Data("{}".utf8).write(to: root.appendingPathComponent("late.json"))
spin(0.2)
check(events == beforeExit + 2, "no events after stop")

// The production fallback is slow (60 s), never the 1 s poll it replaces.
let production = CyderExecutionWatch(directory: root)
production.update(unresolved: true, pids: [])
check(production.hasFallback, "fallback armed while unresolved")
production.update(unresolved: false, pids: [])
check(!production.hasFallback, "fallback disarmed when resolved")
production.stop()
check(!(try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)).contains("repeating: 1,"), "1 s receipt polling removed")

if failures > 0 { exit(1) }
print("PASS execution watch: rename and process-exit events, coalescing, no idle polling, slow fallback only")
