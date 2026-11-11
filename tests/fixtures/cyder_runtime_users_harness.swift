import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL \(message)\n", stderr); exit(1) }
}
typealias U = CyderRuntimeUsers
let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--sleep" { sleep(30); exit(0) }
let base = URL(fileURLWithPath: arguments[1])

DispatchQueue.global().async {
    // Injected process table: one prefix-readable client, one Wine child whose
    // arguments were overwritten (attributed through the wineserver socket),
    // one unattributable client, a wineserver, a foreign engine, and a non-Wine process.
    let engine = base.appendingPathComponent("engine")
    let root = engine.resolvingSymlinksInPath().path
    let images: [Int32: String] = [
        10: root + "/bin/wine", 11: root + "/lib/wine/x86_64-unix/wine", 12: root + "/bin/wine64-preloader",
        13: root + "/bin/wineserver", 14: "/elsewhere/bin/wine", 15: "/usr/bin/true"]
    let args: [Int32: CyderProcessTable.Arguments] = [
        10: .init(prefix: "/bottles/A", name: "game.exe"), 11: .init(prefix: nil, name: "services.exe"),
        13: .init(prefix: "/bottles/A", name: nil)]
    let sockets: [Int32: CyderProcessTable.UnixSockets] = [
        11: .init(own: [7], peers: [100]), 12: .init(own: [8], peers: [999]), 13: .init(own: [100, 101], peers: [7])]
    var probe = U.Probe()
    probe.pids = { [15, 14, 13, 12, 11, 10] }
    probe.image = { images[$0] }
    probe.arguments = { args[$0] }
    probe.sockets = { sockets[$0] }
    let users = U.scan(engineRoot: engine, probe: probe)
    check(users == [.init(pid: 10, prefix: "/bottles/A", name: "game.exe"),
                    .init(pid: 11, prefix: "/bottles/A", name: "services.exe"),
                    .init(pid: 12, prefix: nil, name: "Windows 程序")], "scan classification: \(String(describing: users))")
    print("PASS scan: clients counted, wineserver and other engines ignored, children attributed through the server socket")

    probe.pids = { nil }
    check(U.scan(engineRoot: engine, probe: probe) == nil, "unreadable process table must not read as idle")
    print("PASS scan: an unreadable process table is reported, never treated as idle")

    // Marker lines survive spaces, '=', '%', non-ASCII and surrounding output.
    let odd = U.User(pid: 42, prefix: "/Users/a b/瓶子=1%/", name: "遊 戲=.exe")
    let output = "noise\n" + U.line(component: "moltenvk", odd) + "\n"
        + U.line(component: "moltenvk", .init(pid: 43, prefix: nil, name: "x.exe")) + "\nmore noise\n"
    check(U.report(in: output) == .init(component: "moltenvk", users: [odd, .init(pid: 43, prefix: nil, name: "x.exe")]),
          "report round trip: \(String(describing: U.report(in: output)))")
    check(U.report(in: "CYDER-RUNTIME-IN-USE component=gptk pid=0 name=x\nCYDER-RUNTIME-IN-USE component=gptk prefix=relative pid=5") ==
          .init(component: "gptk", users: [.init(pid: 5, prefix: nil, name: "Windows 程序")]), "malformed marker fields")
    check(U.report(in: "plain failure") == nil, "no marker")
    print("PASS report: marker lines round-trip and malformed fields are rejected")

    // Real process table: a client image of the engine (reached through a
    // symlinked engine path) is found until it exits.
    let real = base.appendingPathComponent("real-engine")
    let link = base.appendingPathComponent("engine-link")
    let fake = real.appendingPathComponent("bin/wine")
    do {
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A copy of this test binary: copied Apple platform binaries may be
        // refused by launch constraints outside their system location.
        try FileManager.default.copyItem(atPath: Bundle.main.executablePath!, toPath: fake.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    } catch { check(false, "fixture: \(error)") }
    check(U.scan(engineRoot: link) == [], "idle engine reported users")
    check(U.run(arguments: ["CyderSwift", "--runtime-users", link.path, "moltenvk"]) == 0, "idle engine exit status")
    let process = Process()
    process.executableURL = fake
    process.arguments = ["--sleep"]
    try! process.run()
    let pid = process.processIdentifier
    var seen: [U.User]? = nil
    for _ in 0..<100 { seen = U.scan(engineRoot: link); if seen?.isEmpty == false { break }; usleep(20_000) }
    check(seen?.map(\.pid) == [pid], "running client not found: \(String(describing: seen))")
    check(U.run(arguments: ["CyderSwift", "--runtime-users", link.path, "moltenvk"]) == 75, "busy engine exit status")
    check(U.run(arguments: ["CyderSwift", "--runtime-users", link.path, "other"]) == 64, "unknown component accepted")
    // CyderSwift calls run() from main(); it must not trap there.
    check(DispatchQueue.main.sync { U.run(arguments: ["CyderSwift", "--runtime-users", link.path, "engine"]) } == 75,
          "main-thread run with the engine component")
    process.terminate(); process.waitUntilExit()
    check(U.scan(engineRoot: link) == [], "exited client still reported")
    print("PASS real process table: a running engine client blocks the switch and its exit clears it")
    exit(0)
}
dispatchMain()
