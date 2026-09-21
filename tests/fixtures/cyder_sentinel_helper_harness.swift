import Foundation
import Darwin

enum CyderPaths { static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CYDER_SUPPORT"]!) }
if CommandLine.arguments.contains("--sentinel-connect") {
    exit(CyderSentinelConnect.run(arguments: CommandLine.arguments))
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    guard condition() else { fputs("FAIL helper deadline\n", stderr); exit(1) }
}
let server = CyderSentinelServer(bundleID: "test-helper")
precondition(server.becomePrimary() == .primary)
var launches: [CyderSentinelLaunch] = []
server.onLaunch = { launches.append($0) }
server.onLaunchUpdate = { launches.append($0) }
let root = CyderPaths.support
func helper(_ name: String, pid: Int32?, keepWriter: Bool) -> (Process, Int32, URL) {
    let directory = root.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fifo = directory.appendingPathComponent("wait"), file = directory.appendingPathComponent("watch.pid")
    precondition(mkfifo(fifo.path, 0o600) == 0)
    let writer = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    precondition(writer >= 0)
    if let pid { try! Data("\(pid)\n".utf8).write(to: file) }
    if !keepWriter { close(writer) } // deterministic dyld-after-writer-close race
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--sentinel-connect", "--prefix", root.path, "--exe", name, "--fifo", fifo.path, "--pid-file", file.path]
    var env = ProcessInfo.processInfo.environment; env["CYDER_BUNDLE_ID"] = "test-helper"; p.environment = env
    try! p.run()
    return (p, keepWriter ? writer : -1, file)
}
// A delayed helper must observe an already-closed FIFO, publish a live root,
// then exit after that exact child exits. The old blocking open never connects.
let rootProcess = Process(); rootProcess.executableURL = URL(fileURLWithPath: "/bin/sleep"); rootProcess.arguments = ["20"]
try rootProcess.run()
let late = helper("late-open", pid: rootProcess.processIdentifier, keepWriter: false)
pump { launches.contains { $0.pid == rootProcess.processIdentifier } }
precondition(late.0.isRunning)
rootProcess.terminate() // native fixture created above, never Wine
pump { !late.0.isRunning }
precondition(late.0.terminationStatus == 0)
// A live publisher with no PID cannot retain a helper indefinitely.
let missing = helper("missing-pid", pid: nil, keepWriter: true)
pump({ !missing.0.isRunning }, timeout: 5)
close(missing.1)
// Primary shutdown only drops observation; its helper must leave the native
// root running (the same rule used for Wine).
let survivor = Process(); survivor.executableURL = URL(fileURLWithPath: "/bin/sleep"); survivor.arguments = ["20"]
try survivor.run()
let attached = helper("primary-quit", pid: survivor.processIdentifier, keepWriter: false)
pump { launches.contains { $0.pid == survivor.processIdentifier } }
var stopped = false
server.stop { stopped = true }
pump { stopped && !attached.0.isRunning }
precondition(survivor.isRunning && attached.0.terminationStatus == 0)
survivor.terminate()
print("PASS actual sentinel helper: late FIFO open, root exit, missing PID deadline, primary disconnect, root survival")
