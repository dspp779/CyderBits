import Foundation
import Darwin
if ["--execution-owner", "--execution-wine"].contains(CommandLine.arguments.dropFirst().first ?? "") { exit(CyderExecutionOwner.run(arguments: CommandLine.arguments)) }
func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard value() else { fputs("FAIL executor line \(line): \(message)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10, line: UInt = #line) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "callback timeout", line: line)
}
func io<T>(_ work: @escaping () throws -> T) throws -> T {
    var result: Result<T, Error>?
    DispatchQueue.global().async { let r = Result { try work() }; DispatchQueue.main.async { result = r } }
    pump { result != nil }; return try result!.get()
}
do {
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let ledger = root.appendingPathComponent("owners")
let issuer = UUID()
let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CYDER_EXECUTION_HELPER"] ?? CommandLine.arguments[0])
let script = root.appendingPathComponent("effect.sh")
try Data(#"""
#!/bin/bash
set -e
[[ "${!CYDER_EXECUTION_@}" == CYDER_EXECUTION_RUNTIME_MUTATION ]] || exit 91
[[ "$CYDER_EXECUTION_RUNTIME_MUTATION" == 0 || "$CYDER_EXECUTION_RUNTIME_MUTATION" == 1 ]] || exit 92
printf 'entered\n' > "$1.entered"
if [[ "$2" == wait ]]; then
  while [[ ! -f "$1.release" ]]; do sleep 0.02; done
fi
printf 'finished\n' > "$1.finished"
exit "$3"
"""#.utf8).write(to: script)
func reserve(_ scope: String?, correlation: CyderExecutionOwner.Correlation? = nil, requiresGlobalScope: Bool = false) throws -> UUID {
    let path = scope.map { root.appendingPathComponent("prefixes/" + $0).path }
    if let path { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    return try io { try CyderExecutionOwner.prepare(root: ledger, issuer: issuer, scope: path, correlation: correlation,
                                                   requiresGlobalScope: requiresGlobalScope) }
}
func start(_ id: UUID, name: String, wait: Bool = false, status: Int = 0) throws -> Process {
    let p = Process(); p.executableURL = helper
    var environment = ProcessInfo.processInfo.environment
    for key in ["CYDER_EXECUTION_OWNER_ROOT", "CYDER_EXECUTION_OWNER_TICKET", "CYDER_EXECUTION_OWNER_HELPER", "CYDER_EXECUTION_FINAL", "CYDER_EXECUTION_RUNTIME_MUTATION"] {
        environment[key] = "injected-stale-authority"
    }
    p.environment = environment
    p.arguments = ["--execution-owner", ledger.path, id.uuidString, "--", "/bin/bash", script.path,
                   root.appendingPathComponent(name).path, wait ? "wait" : "quick", String(status), "secret-executor-argv"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); return p
}
func exists(_ name: String, _ suffix: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name + "." + suffix).path) }
func receipt(_ id: UUID) throws -> CyderExecutionOwner.Ticket {
    try JSONDecoder().decode(CyderExecutionOwner.Ticket.self, from: Data(contentsOf: ledger.appendingPathComponent(id.uuidString + ".json")))
}
let revoked = try reserve("one")
try io { try CyderExecutionOwner.recover(root: ledger) }
let late = try start(revoked, name: "revoked"); pump { !late.isRunning }
check(late.terminationStatus == 75 && !exists("revoked", "entered"), "old prepared ticket spawned after recovery")
let revokedReceipt = try receipt(revoked)
check(revokedReceipt.phase == "revoked", "prepared ticket not durably revoked")
let nativeCorrelation = CyderExecutionOwner.Correlation(requestID: UUID().uuidString + ":" + UUID().uuidString,
    launchID: UUID().uuidString, digest: String(repeating: "b", count: 64))
let active = try reserve("one", correlation: nativeCorrelation)
let owner = try start(active, name: "active", wait: true, status: 23)
pump { exists("active", "entered") }
try io { try CyderExecutionOwner.recover(root: ledger) }
pump { (try? receipt(active).child) != nil }
let activeReceipt = try receipt(active)
check(activeReceipt.phase == "active" && activeReceipt.owner?.pid == owner.processIdentifier && activeReceipt.child != nil,
      "live owner not retained with actual process identities")
let alias = root.appendingPathComponent("prefix-alias")
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("prefixes/one"))
let aliasTicket = try io { try CyderExecutionOwner.prepare(root: ledger, issuer: issuer, scope: alias.path) }
let aliasAttempt = try start(aliasTicket, name: "alias"); pump { !aliasAttempt.isRunning }
check(aliasAttempt.terminationStatus == 75 && !exists("alias", "entered"), "prefix alias bypassed directory identity lock")
let duplicate = try start(active, name: "duplicate"); pump { !duplicate.isRunning }
check(duplicate.terminationStatus == 75 && !exists("duplicate", "entered"), "duplicate owner spawned")
var maintenanceRefused = false
do { try io { try CyderExecutionOwner.withScope(root: ledger, scope: nil) { try Data().write(to: root.appendingPathComponent("unsafe-maintenance")) } } }
catch { maintenanceRefused = true }
check(maintenanceRefused && !FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe-maintenance").path), "native filesystem mutation bypassed the live cross-process owner")
let sameTicket = try reserve("one"), otherTicket = try reserve("two"), allTicket = try reserve(nil)
let same = try start(sameTicket, name: "same"), other = try start(otherTicket, name: "other"), all = try start(allTicket, name: "all")
pump { !same.isRunning && !other.isRunning && !all.isRunning }
check(same.terminationStatus == 75 && all.terminationStatus == 75, "cross-process conflicting scope bypassed live owner")
check(other.terminationStatus == 0 && exists("other", "finished"), "independent environment was blocked")
try Data().write(to: root.appendingPathComponent("active.release")); pump { !owner.isRunning }
check(owner.terminationStatus == 23 && exists("active", "finished"), "native child result lost")
let finished = try receipt(active); check(finished.phase == "finished" && finished.status == 23, "actual result not persisted")
check(finished.correlation == nativeCorrelation && finished.issuer == issuer && finished.signalled == false,
      "actual helper lost original correlation or termination reason")
let again = try start(active, name: "again"); pump { !again.isRunning }
check(again.terminationStatus == 75 && !exists("again", "entered"), "completed ticket replayed")
let after = try start(sameTicket, name: "after"); pump { !after.isRunning }
check(after.terminationStatus == 0 && exists("after", "finished"), "scope not released after actual child exit")
try io { try CyderExecutionOwner.withScope(root: ledger, scope: nil) { try Data().write(to: root.appendingPathComponent("maintenance")) } }
check(FileManager.default.fileExists(atPath: root.appendingPathComponent("maintenance").path), "finished native owner still blocked filesystem mutation")
let bytes = try String(contentsOf: ledger.appendingPathComponent(active.uuidString + ".json"), encoding: .utf8)
check(!bytes.contains("secret-executor-argv") && !bytes.contains("effect.sh"), "ledger stored argv")
print("PASS executor: native helper, original ticket once, prepared revocation, cross-process prefix/global locks, independent environment, actual child status and birth receipt, argv privacy")

let changedPrefixTicket = try reserve("changed")
let changedPrefix = root.appendingPathComponent("prefixes/changed")
try FileManager.default.moveItem(at: changedPrefix, to: root.appendingPathComponent("prefixes/original-changed"))
try FileManager.default.createDirectory(at: changedPrefix, withIntermediateDirectories: true)
let changedPrefixOwner = try start(changedPrefixTicket, name: "wrong-prefix"); pump { !changedPrefixOwner.isRunning }
check(changedPrefixOwner.terminationStatus == 75 && !exists("wrong-prefix", "entered"), "replaced directory reused old execution authority")
print("PASS stable environment identity: symlink alias conflicts and replaced prefix refuses stale ticket")

let crashTicket = try reserve("crash")
let crashOwner = try start(crashTicket, name: "crash", wait: true)
pump { exists("crash", "entered") }
let beforeCrash = try receipt(crashTicket)
check(beforeCrash.owner == CyderExecutionOwner.Birth.current(crashOwner.processIdentifier), "test owner identity changed")
check(kill(crashOwner.processIdentifier, SIGKILL) == 0, "could not stop exact native fixture owner")
pump { !crashOwner.isRunning }
try io { try CyderExecutionOwner.recover(root: ledger) }
let crashReceipt = try receipt(crashTicket); check(crashReceipt.phase == "uncertain", "lost owner falsely completed")
let blockedTicket = try reserve("crash"), safeTicket = try reserve("other-after-crash")
let blocked = try start(blockedTicket, name: "blocked"), safe = try start(safeTicket, name: "safe")
pump { !blocked.isRunning && !safe.isRunning }
// Always release this known fixture child before final assertions.
try Data().write(to: root.appendingPathComponent("crash.release")); pump { exists("crash", "finished") }
check(blocked.terminationStatus == 75 && !exists("blocked", "entered"), "unresolved old descendants lost their scope barrier")
check(safe.terminationStatus == 0, "uncertain environment blocked unrelated work")
print("PASS executor crash: exact fixture owner killed, surviving native child retained, uncertain scope fences new effects, other environment progresses")

// Model an OS boot boundary in durable metadata; this is injected evidence,
// not a real host reboot. No old process can survive that boundary.
var priorBoot = try receipt(crashTicket)
priorBoot.owner = .init(boot: "injected-prior-boot", pid: beforeCrash.owner!.pid, started: beforeCrash.owner!.started)
try JSONEncoder().encode(priorBoot).write(to: ledger.appendingPathComponent(crashTicket.uuidString + ".json"))
try io { try CyderExecutionOwner.recover(root: ledger) }
let bootRecovered = try receipt(crashTicket)
check(bootRecovered.phase == "revoked", "old-boot executor permanently blocked recovery")
print("PASS injected boot boundary: old uncertain executor revoked without replay")

// Model a recovered runtime mutation whose outcome is unknown. Its concrete
// prefix still matters for Wine identity, but its uncertainty blocks all
// environments, including native filesystem maintenance.
let globalUnknownID = try reserve("global-unknown", requiresGlobalScope: true)
var globalUnknown = try receipt(globalUnknownID)
globalUnknown.phase = "uncertain"
globalUnknown.owner = CyderExecutionOwner.Birth.current()
let globalUnknownURL = ledger.appendingPathComponent(globalUnknownID.uuidString + ".json")
try JSONEncoder().encode(globalUnknown).write(to: globalUnknownURL)
let globallyBlocked = try start(try reserve("unrelated-global"), name: "unrelated-global")
pump { !globallyBlocked.isRunning }
check(globallyBlocked.terminationStatus == 75 && !exists("unrelated-global", "entered"), "global uncertainty narrowed to its launch prefix")
var globalMaintenanceRefused = false
do {
    try io {
        try CyderExecutionOwner.withScope(root: ledger, scope: root.appendingPathComponent("prefixes/unrelated-global").path) {
            try Data().write(to: root.appendingPathComponent("unsafe-global-maintenance"))
        }
    }
} catch { globalMaintenanceRefused = true }
check(globalMaintenanceRefused, "filesystem maintenance bypassed global uncertainty")
globalUnknown.owner = .init(boot: "injected-prior-boot", pid: globalUnknown.owner!.pid, started: globalUnknown.owner!.started)
try JSONEncoder().encode(globalUnknown).write(to: globalUnknownURL)
try io { try CyderExecutionOwner.recover(root: ledger) }
let globalRecovered = try receipt(globalUnknownID)
check(globalRecovered.phase == "revoked", "prior-boot global uncertainty remained")
print("PASS injected runtime uncertainty: actual prefix retained, native launches and maintenance in every scope refuse until valid recovery")

// Retention data below is explicitly injected. Physical executor and crash
// behavior above still uses real native children; never prune active/uncertain.
let retention = root.appendingPathComponent("retention")
try FileManager.default.createDirectory(at: retention, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let correlation = CyderExecutionOwner.Correlation(requestID: UUID().uuidString + ":" + UUID().uuidString,
    launchID: UUID().uuidString, digest: String(repeating: "a", count: 64))
let retained = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: issuer, scope: nil, phase: "finished", status: 0, correlation: correlation)
let unresolved = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: issuer, scope: nil, phase: "uncertain")
func inject(_ ticket: CyderExecutionOwner.Ticket) throws {
    let url = retention.appendingPathComponent(ticket.id.uuidString + ".json")
    try JSONEncoder().encode(ticket).write(to: url); chmod(url.path, 0o600)
}
try inject(retained); try inject(unresolved)
var oldFinished: [UUID] = []
for _ in 0..<510 {
    let terminal = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: issuer, scope: nil, phase: "finished", status: 0)
    try inject(terminal); oldFinished.append(terminal.id)
}
let admitted = try io { try CyderExecutionOwner.prepare(root: retention, issuer: issuer, scope: nil) }
let compacted = try io { try CyderExecutionOwner.snapshot(root: retention) }
check(compacted.count == 35 && compacted.contains(retained) && compacted.contains(unresolved)
      && compacted.contains { $0.id == admitted && $0.phase == "prepared" }, "capacity recovery deleted unresolved/correlated authority or retained all terminal history")
let removedID = oldFinished.first { id in !compacted.contains { $0.id == id } }!
let latePruned = Process(); latePruned.executableURL = helper
latePruned.arguments = ["--execution-owner", retention.path, removedID.uuidString, "--", "/bin/bash", script.path, root.appendingPathComponent("pruned-late").path, "quick", "0"]
try latePruned.run(); pump { !latePruned.isRunning }
check(latePruned.terminationStatus == 75 && !exists("pruned-late", "entered"), "pruned old ticket was recreated/replayed")
var staleConfirmation = retained; staleConfirmation.phase = "active"
try io { try CyderExecutionOwner.prune(root: retention, confirmed: [staleConfirmation, unresolved]) }
let beforeAcknowledgement = try io { try CyderExecutionOwner.snapshot(root: retention) }
check(beforeAcknowledgement.contains(retained) && beforeAcknowledgement.contains(unresolved), "stale ACK or uncertain evidence deleted ticket")
try io { try CyderExecutionOwner.prune(root: retention, confirmed: [retained]) }
let afterAcknowledgement = try io { try CyderExecutionOwner.snapshot(root: retention) }
check(!afterAcknowledgement.contains(retained) && afterAcknowledgement.contains(unresolved), "exact durable confirmation did not release only its terminal ticket")
print("PASS retention: 512-ticket capacity reclaims only disposable terminal history, correlated evidence waits for exact durable ACK, unresolved/live authority retained and pruned tickets cannot replay")

let invalidSpawnRoot = root.appendingPathComponent("invalid-spawn")
try FileManager.default.createDirectory(at: invalidSpawnRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let invalidSpawn = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: issuer, scope: "injected-scope",
    prefix: root.path, phase: "handedOff", handoff: .init(executable: "/injected/wine", pidFile: root.appendingPathComponent("pid").path),
    nativeSpawn: .init(phase: "unknown-future-state", bridge: .init(boot: "injected-boot", pid: 123, started: 456)))
let invalidSpawnURL = invalidSpawnRoot.appendingPathComponent(invalidSpawn.id.uuidString + ".json")
let invalidSpawnBytes = try JSONEncoder().encode(invalidSpawn)
try invalidSpawnBytes.write(to: invalidSpawnURL); chmod(invalidSpawnURL.path, 0o600)
var rejectedInvalidSpawn = false
do { _ = try io { try CyderExecutionOwner.snapshot(root: invalidSpawnRoot) } } catch { rejectedInvalidSpawn = true }
let preservedInvalidSpawn = try Data(contentsOf: invalidSpawnURL)
check(rejectedInvalidSpawn && preservedInvalidSpawn == invalidSpawnBytes, "unknown native spawn state was treated as a confirmed handoff")
print("PASS handoff schema: unknown native spawn proof is rejected and original bytes remain intact")

let corrupt = ledger.appendingPathComponent(UUID().uuidString + ".json")
let corruptBytes = Data("broken receipt".utf8)
try corruptBytes.write(to: corrupt); chmod(corrupt.path, 0o600)
var refused = false
do { try io { try CyderExecutionOwner.recover(root: ledger) } } catch { refused = true }
let preserved = try Data(contentsOf: corrupt)
check(refused && preserved == corruptBytes, "corrupt receipt overwritten or ignored")
print("PASS executor recovery corruption: fail closed, original bytes preserved")

} catch { fputs("FAIL executor I/O: \(error)\n", stderr); exit(1) }
