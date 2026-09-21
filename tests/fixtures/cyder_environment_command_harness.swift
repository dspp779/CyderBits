import Foundation
import Darwin
if CommandLine.arguments.dropFirst().first == "--environment-state" {
    DispatchQueue.global().async { exit(CyderEnvironmentCommand.run(arguments: CommandLine.arguments)) }
    dispatchMain()
}
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL \(message)\n", stderr); exit(1) }
}
DispatchQueue.global().async {
    let first = CyderEnvironmentProbe.Identity(environment: .init(uid: getuid(), device: 1, inode: 2, namespace: "wine-user"),
        prefix: "/fixture/prefix", engine: "/fixture/wineserver")
    let replacement = CyderEnvironmentProbe.Identity(environment: .init(uid: getuid(), device: 1, inode: 3, namespace: "wine-user"),
        prefix: first.prefix, engine: first.engine)
    let arguments = ["test", "--environment-state", first.prefix, first.engine]
    var probes = 0, pauses = 0, output: [String] = []
    let identify: (URL, URL) -> CyderEnvironmentProbe.Identity? = { _, _ in first }
    let emit: (String) -> Void = { output.append($0) }
    let empty: (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result = { _ in probes += 1; return .empty }
    let pause = { pauses += 1 }
    let owner = CyderLifecycle.ProcessID(boot: "fixture", pid: 123, started: 1)
    check(CyderEnvironmentCommand.run(arguments: arguments, identify: identify, probe: empty, pause: pause, output: emit) == 10, "two empty proof")
    check(probes == 2 && pauses == 1 && output == ["cyder-environment-v1 empty"], "empty protocol")
    probes = 0; pauses = 0; output = []
    check(CyderEnvironmentCommand.run(arguments: arguments, identify: identify, probe: { _ in .alive(owner) }, pause: pause, output: emit) == 0, "alive status")
    check(pauses == 0 && output == ["cyder-environment-v1 alive"], "alive protocol")
    output = []
    check(CyderEnvironmentCommand.run(arguments: arguments, identify: identify, probe: { _ in .unknown("fixture") }, pause: pause, output: emit) == 75 && output.isEmpty, "unknown cannot report empty")
    probes = 0
    check(CyderEnvironmentCommand.run(arguments: arguments, identify: identify, probe: { _ in probes += 1; return probes == 1 ? .empty : .alive(owner) }, pause: pause, output: emit) == 75 && output.isEmpty, "new server between samples")
    var identifies = 0; probes = 0
    check(CyderEnvironmentCommand.run(arguments: arguments, identify: { _, _ in identifies += 1; return identifies == 1 ? first : replacement }, probe: empty, pause: pause, output: emit) == 75, "prefix replacement")
    check(probes == 1 && output.isEmpty, "replacement did not become empty proof")
    check(CyderEnvironmentCommand.run(arguments: ["test", "--environment-state", "relative", first.engine], identify: identify, probe: empty, pause: pause, output: emit) == 64, "malformed arguments")
    print("PASS formal environment command: paired empty proof/status, alive, unknown, server restart, prefix replacement and malformed input")
    exit(0)
}
dispatchMain()
