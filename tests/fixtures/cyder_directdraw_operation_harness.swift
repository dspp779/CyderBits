import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2 {
    alarm(8)
    switch CommandLine.arguments[2] {
    case "good": print("{\"mode\":\"source\"}")
    case "bad-status": print("{\"mode\":\"source\"}"); exit(2)
    case "bad-json": print("not JSON")
    case "hung", "ignores-term":
        if CommandLine.arguments[2] == "ignores-term" { signal(SIGTERM, SIG_IGN) }
        let fifo = CommandLine.arguments[3]
        try! Data().write(to: URL(fileURLWithPath: fifo + ".ready"))
        let fd = open(fifo, O_RDONLY)
        if fd >= 0 { close(fd) }
        print("{\"mode\":\"source\"}")
    case "mutation":
        usleep(300_000)
        try! Data("finished".utf8).write(to: root.appendingPathComponent("mutation-marker"))
        print("{\"mode\":\"on\"}")
    case "flood": FileHandle.standardError.write(Data(repeating: 65, count: 150_000))
    case "pipe-holder":
        FileHandle.standardOutput.write(Data("{\"mode\":\"source\"}".utf8))
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = [root.path, "holder"]
        holder.standardOutput = FileHandle.standardOutput; holder.standardError = FileHandle.standardError
        try! holder.run()
    case "holder": usleep(700_000)
    default: exit(3)
    }
    exit(0)
}
let sanitized = CyderDirectDrawOperations.helperEnvironment([
    "CYDER_DDRAW_PATH": "canonical", "cyder_ddraw_path": "foreign", "CyDeR_DdRaW_PaTh": "",
    "CNC_DDRAW_CONFIG_FILE": "canonical", "cnc_ddraw_config_file": "", "Cnc_Ddraw_Config_File": "foreign",
    "GAME_CONTROL": "preserved"
])
precondition(sanitized == ["GAME_CONTROL": "preserved"], "UI helper must remove all Windows case aliases, including empty values")
print("PASS helper environment: all DirectDraw aliases removed; unrelated value preserved")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func pump(_ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + 5
    while !condition() && ProcessInfo.processInfo.systemUptime < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    precondition(condition(), "DirectDraw callback did not arrive")
}
func process(_ kind: String, _ argument: String? = nil) -> Process {
    let value = Process()
    value.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    value.arguments = [root.path, kind] + (argument.map { [$0] } ?? [])
    return value
}
func idle(_ owner: CyderDirectDrawOperations) {
    var free = false
    pump { owner.inspect { free = !$0 }; return free }
}
func releaseFIFO(_ path: String) {
    let fd = open(path, O_WRONLY | O_NONBLOCK)
    precondition(fd >= 0, "fixture reader was not blocked in open")
    close(fd)
}
func makeFIFO(_ name: String) -> String {
    let path = root.appendingPathComponent(name).path
    precondition(mkfifo(path, 0o600) == 0)
    return path
}
let exe = root.appendingPathComponent("synthetic.exe")
var kind = "good", fixtureArgument: String?, made = 0
let owner = CyderDirectDrawOperations(statusDeadline: 0.18, mutationDeadline: 0.05,
    makeProcess: { _, _, _ in made += 1; return process(kind, fixtureArgument) })
func result(_ command: String = "status") -> Result<[String: Any], Error> {
    var output: Result<[String: Any], Error>?
    owner.run(command, executable: exe) { update in
        if case .completed(let value) = update { precondition(output == nil); output = value }
    }
    pump { output != nil }; idle(owner)
    return output!
}
func failed(_ result: Result<[String: Any], Error>) -> Bool { if case .failure = result { return true }; return false }
precondition((try! result().get()["mode"] as? String) == "source")
kind = "bad-status"; precondition(failed(result()))
kind = "bad-json"; precondition(failed(result()))
kind = "flood"; precondition(failed(result()))
let missing = CyderDirectDrawOperations(makeProcess: { _, _, _ in let p = Process(); p.executableURL = URL(fileURLWithPath: "/nonexistent/cyder-cnc"); return p })
var missingResult = false
missing.run("status", executable: exe) { if case .completed(let value) = $0 { precondition(failed(value)); missingResult = true } }
pump { missingResult }; idle(missing)
print("PASS actual JSON/exit status, invalid JSON, bounded flood and failed spawn")

for command in ["status"] {
    kind = "hung"; fixtureArgument = makeFIFO("hang-" + command)
    let started = ProcessInfo.processInfo.systemUptime
    precondition(failed(result(command)))
    precondition(ProcessInfo.processInfo.systemUptime - started < 2)
}
print("PASS hung open: status reports unknown and releases only after actual termination")

kind = "ignores-term"; let ignoredFIFO = makeFIFO("ignored-term"); fixtureArgument = ignoredFIFO
var expired = 0
let ignoredID = owner.run("status", executable: exe) { update in
    guard case .completed(let value) = update else { fatalError("read became mutation") }
    precondition(failed(value)); expired += 1
}
pump { expired == 1 }
let beforeReopen = made
var rejected = 0
for _ in 0..<20 {
    owner.run("status", executable: exe) {
        if case .completed(let value) = $0 { precondition(failed(value)); rejected += 1 }
    }
}
pump { rejected == 20 }
precondition(made == beforeReopen, "reopen multiplied a nonterminating reader")
owner.cancelRead(ignoredID)
releaseFIFO(ignoredFIFO); idle(owner)
precondition(expired == 1, "late successful exit replaced timeout with success")
kind = "good"; fixtureArgument = nil
precondition(!failed(result()))
print("PASS ignored TERM: 20 reopens create no extra process; late exit cannot report success; later retry works")

kind = "ignores-term"; let closeFIFO = makeFIFO("close"); fixtureArgument = closeFIFO
var closedCallbacks = 0
let closingID = owner.run("status", executable: exe) { _ in closedCallbacks += 1 }
pump { FileManager.default.fileExists(atPath: closeFIFO + ".ready") }
owner.cancelRead(closingID)
let beforeClosedReopen = made
var closedReopen = false
owner.run("status", executable: exe) {
    if case .completed(let value) = $0 { precondition(failed(value)); closedReopen = true }
}
pump { closedReopen }
precondition(made == beforeClosedReopen)
releaseFIFO(closeFIFO); idle(owner)
precondition(closedCallbacks == 0, "closed window received a late status result")
print("PASS close during status: no late callback or extra process on reopen")

kind = "mutation"; fixtureArgument = nil
var waiting = 0, mutationDone = false
let mutationID = owner.run("enable", executable: exe) { update in
    switch update {
    case .stillRunning: waiting += 1
    case .completed(let result): precondition(!failed(result)); mutationDone = true
    }
}
pump { waiting == 1 }
owner.cancelRead(mutationID)
precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mutation-marker").path))
let beforeMutationReopen = made
var mutationBusy = false
owner.run("status", executable: exe) { if case .completed(let value) = $0 { precondition(failed(value)); mutationBusy = true } }
pump { mutationBusy }; precondition(made == beforeMutationReopen)
pump { mutationDone }; idle(owner)
precondition(waiting == 1 && (try! String(contentsOf: root.appendingPathComponent("mutation-marker"), encoding: .utf8)) == "finished")
print("PASS mutation: deadline/cancel/reopen preserve actual operation, output and eventual confirmed result")

kind = "pipe-holder"
let pipeStart = ProcessInfo.processInfo.systemUptime
precondition(!failed(result()))
precondition(ProcessInfo.processInfo.systemUptime - pipeStart < 0.5, "waited for descendant-held stdout EOF")
print("PASS exited helper with descendant-held stdout does not block read completion")

let gate = DispatchSemaphore(value: 0)
var stalledMade = 0
let stalled = CyderDirectDrawOperations(statusDeadline: 0.05, beforeSpawn: {
    precondition(gate.wait(timeout: .now() + 5) == .success)
}, makeProcess: { _, _, _ in stalledMade += 1; return process("good") })
var stalledResult = 0
let stalledID = stalled.run("status", executable: exe) { if case .completed(let value) = $0 { precondition(failed(value)); stalledResult += 1 } }
pump { stalledResult == 1 }
stalled.cancelRead(stalledID)
var stallBusy = false
stalled.run("status", executable: exe) { if case .completed(let value) = $0 { precondition(failed(value)); stallBusy = true } }
pump { stallBusy }; precondition(stalledMade == 1)
gate.signal(); idle(stalled)
precondition(stalledResult == 1)
print("PASS stalled spawn retains physical owner and suppresses late success after cancel")
