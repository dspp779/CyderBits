import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let engine = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let identity = CyderEnvironmentProbe.identify(prefix: root, engine: engine)!
let directory = CyderEnvironmentProbe.serverDirectory(identity)
func listener(_ directory: URL) -> Int32 {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(directory.appendingPathComponent("socket").path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { output in bytes.withUnsafeBytes { output.copyBytes(from: $0) } }
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    precondition(bound == 0 && listen(sock, 16) == 0)
    return sock
}
if CommandLine.arguments.contains("--holder") {
    let lock = open(directory.appendingPathComponent("lock").path, O_WRONLY | O_CREAT, 0o600)
    precondition(lock >= 0)
    var region = flock(l_start: 0, l_len: 1, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    precondition(fcntl(lock, F_SETLK, &region) == 0)
    if !CommandLine.arguments.contains("--lock-only") { _ = listener(directory) }
    try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
    alarm(12) // self-expire if a harness assertion aborts the parent
    while true { pause() }
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: directory) }
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { done.signal() }
    precondition(CyderEnvironmentProbe.inspect(identity) == .empty, "unused owned namespace is empty")
    let child = Process(); child.executableURL = engine; child.arguments = [root.path, "--holder"]
    try! child.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
    let observed = CyderEnvironmentProbe.inspect(identity)
    guard case .alive(let owner) = observed else { fatalError("actual POSIX lock holder not recognized: \(observed), path=\(String(describing: CyderEnvironmentProbe.processPath(child.processIdentifier))), identity=\(String(describing: CyderEnvironmentProbe.processIdentity(child.processIdentifier)))") }
    precondition(owner.pid == child.processIdentifier && owner.started > 0)
    precondition(CyderEnvironmentProbe.inspect(identity, image: { _ in "/wrong/engine" }) == .unknown("lock-owner-unverified"))
    var lookups = 0
    let reused = CyderEnvironmentProbe.inspect(identity, process: { pid in
        lookups += 1
        return .init(boot: owner.boot, pid: pid, started: owner.started + UInt64(lookups))
    })
    precondition(reused == .unknown("lock-owner-unverified"), "PID reuse must not be accepted")
    child.terminate(); child.waitUntilExit()
    precondition(CyderEnvironmentProbe.inspect(identity) == .empty, "released lock is not permanent unknown")
    // A wait helper can briefly own the server's lock after shutdown. Its
    // executable image alone is not sufficient evidence of a live environment.
    try! FileManager.default.removeItem(at: root.appendingPathComponent("ready"))
    let waiting = Process(); waiting.executableURL = engine; waiting.arguments = [root.path, "--holder", "--lock-only"]
    try! waiting.run()
    let waitDeadline = ProcessInfo.processInfo.systemUptime + 5
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), ProcessInfo.processInfo.systemUptime < waitDeadline { usleep(10000) }
    precondition(CyderEnvironmentProbe.inspect(identity) == .unknown("lock-without-live-socket"))
    waiting.terminate(); waiting.waitUntilExit()
    // A listener remains authoritative evidence against declaring empty even
    // when this Wine variant does not hold a POSIX lock.
    try! FileManager.default.removeItem(at: directory.appendingPathComponent("socket"))
    let sock = listener(directory)
    precondition(CyderEnvironmentProbe.inspect(identity) == .unknown("socket-may-be-live"))
    close(sock)
    precondition(CyderEnvironmentProbe.inspect(identity) == .empty, "stale refused socket must calibrate empty")
    // Nonblocking open must reject a FIFO before it occupies a probe slot.
    let lockURL = directory.appendingPathComponent("lock")
    try! FileManager.default.removeItem(at: lockURL)
    precondition(mkfifo(lockURL.path, 0o600) == 0)
    precondition(CyderEnvironmentProbe.inspect(identity) == .unknown("lock-invalid"))
    try! FileManager.default.removeItem(at: lockURL)
    let changed = CyderEnvironmentProbe.Identity(environment: .init(uid: getuid(), device: identity.environment.device, inode: identity.environment.inode + 1, namespace: "wine-user"), prefix: identity.prefix, engine: identity.engine)
    precondition(CyderEnvironmentProbe.inspect(changed) == .unknown("prefix-identity-changed"))
    let missing = CyderEnvironmentProbe.Identity(environment: identity.environment, prefix: identity.prefix, engine: "/nonexistent/wineserver")
    precondition(CyderEnvironmentProbe.inspect(missing) == .unknown("engine-unavailable"))
    print("PASS environment calibration: native POSIX lock, process birth/image, PID reuse, socket-only server, stale socket, empty, replaced prefix, missing engine")
}
precondition(done.wait(timeout: .now() + 15) == .success)
