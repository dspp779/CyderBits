import Cocoa
import Foundation
import Darwin
enum CyderPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    precondition(condition(), "completion not delivered")
}
// A new primary must revoke an unclaimed native executor before dispatch
// authority becomes visible, not in a later best-effort background pass.
let ownerDirectory = CyderPaths.support.appendingPathComponent("execution-owners")
try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let staleExecution = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: UUID(), scope: nil, phase: .prepared)
let staleExecutionURL = ownerDirectory.appendingPathComponent(staleExecution.id.uuidString + ".json")
try JSONEncoder().encode(staleExecution).write(to: staleExecutionURL)
chmod(staleExecutionURL.path, 0o600)
let primary = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var role: CyderInstanceCoordinator.Role?
var received: [CyderInstanceRequest] = []
primary.start(onRequest: { received.append($0) }) { role = $0 }
pump { role != nil }
precondition(role == .primary)
let recoveredExecution = try JSONDecoder().decode(CyderExecutionOwner.Ticket.self, from: Data(contentsOf: staleExecutionURL))
precondition(recoveredExecution.phase == .revoked, "primary admitted requests before revoking an unclaimed old executor")
let acceptedPreferences = Data(#"{"schemaVersion":13,"dpi":144}"#.utf8)
try acceptedPreferences.write(to: CyderPaths.support.appendingPathComponent("settings.json"))
let secondary = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var secondRole: CyderInstanceCoordinator.Role?
secondary.start(onRequest: { _ in fatalError("secondary dispatch") }) { secondRole = $0 }
pump { secondRole != nil }
precondition(secondRole == .secondary, "second primary elected")
var ack: Bool?
secondary.forward(files: ["/trusted/one.exe", "/trusted/two.exe"], arguments: [], urls: ["test://uri"], showUI: false) { ack = $0 }
pump { ack != nil && received.count == 3 }
precondition(ack == true)
precondition(received.allSatisfy { $0.record.settingsSnapshot == acceptedPreferences })
try Data(#"{"schemaVersion":13,"dpi":192}"#.utf8).write(to: CyderPaths.support.appendingPathComponent("settings.json"), options: .atomic)
var wireStatus: CyderRequestReply?
let queryID = received[0].record.id
DispatchQueue.global().async {
    let response = CyderRequestChannel.exchange(path: CyderPaths.support.appendingPathComponent(".requests-v1.sock").path,
        message: .init(protocolVersion: 1, kind: "query", requestID: queryID, payloadDigest: nil, senderEpoch: UUID(), payload: nil))
    DispatchQueue.main.async { wireStatus = response }
}
pump { wireStatus != nil }
precondition(wireStatus?.status == "existingStatus" && wireStatus?.record?.settingsSnapshot == nil,
             "private settings snapshot must not inflate the ACK/status transport")
precondition(Set(received.map { $0.record.id }).count == 3, "batch must have separate durable child IDs")
precondition(received[0].files == ["/trusted/one.exe"] && received[1].files == ["/trusted/two.exe"] && received[2].urls == ["test://uri"], "mixed batch order/content lost")
precondition(received.allSatisfy { $0.arguments == [] && $0.record.phase == .queued })
// A timed-out secondary must not unlink the live primary's request socket.
let secondaryGate = DispatchSemaphore(value: 0)
let lateSecondary = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test", startupDeadline: 0.05,
                                             beforeElection: { secondaryGate.wait() })
var lateSecondaryRole: CyderInstanceCoordinator.Role?
lateSecondary.start(onRequest: { _ in fatalError("late secondary dispatch") }) { lateSecondaryRole = $0 }
pump { lateSecondaryRole != nil }; precondition(lateSecondaryRole == .unavailable)
var secondaryCleaned = false; lateSecondary.stop { secondaryCleaned = true }
secondaryGate.signal(); pump { secondaryCleaned }
var afterCleanupACK: Bool?
secondary.forward(files: ["/trusted/after-secondary-cleanup.exe"], arguments: nil, showUI: false) { afterCleanupACK = $0 }
pump { afterCleanupACK != nil }; precondition(afterCleanupACK == true && received.count == 4,
                                               "secondary cleanup removed the active primary channel")
var dispatched: CyderRequestRegistry.Record?
var authorized = false
primary.authorize(received[0].record) { dispatched = $0; authorized = true }
pump { authorized }
precondition(dispatched?.phase == .dispatching)
precondition(dispatched?.settingsSnapshot == acceptedPreferences, "dispatch reread mutable settings")
// Quit races with a queued authorization: at most committed dispatch is uncertain;
// completion cannot release a new spawn after the main-thread freeze.
var late: CyderRequestRegistry.Record?
var lateDone = false
primary.authorize(received[1].record) { late = $0; lateDone = true }
var saved: Bool?
primary.quiesce { saved = $0 }
pump { saved != nil && lateDone }
precondition(saved == true && late == nil)
var stopped = false
primary.stop { stopped = true }
pump { stopped }
// Requests are not persisted: a re-elected primary replays nothing, and legacy
// rc.1 request files are removed. A game launched by the previous primary is
// still attributed through its executor ticket, which is the only surviving state.
let legacyJournal = CyderPaths.support.appendingPathComponent("request-journal")
let legacyOutbox = CyderPaths.support.appendingPathComponent("request-outbox")
for legacy in [legacyJournal, legacyOutbox] {
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(#"{"schema":1,"records":{}}"#.utf8).write(to: legacy.appendingPathComponent("requests-v1.json"))
}
let fixtureBoot = CyderExecutionOwner.Birth.current()!.boot
let correlatedTicket = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: dispatched!.executorEpoch!,
    scope: "injected-prefix-scope", prefix: CyderPaths.support.path, phase: .handedOff, owner: .init(boot: fixtureBoot, pid: 12345, started: 10),
    child: .init(boot: fixtureBoot, pid: 12346, started: 11), status: 0, signalled: false,
    correlation: .init(requestID: dispatched!.id, launchID: dispatched!.launchID!, digest: dispatched!.digest),
    handoff: .init(executable: "/injected/wine", pidFile: CyderPaths.support.appendingPathComponent("injected.pid").path),
    nativeSpawn: .init(phase: .spawned, bridge: .init(boot: fixtureBoot, pid: 12347, started: 12),
        process: .init(boot: fixtureBoot, pid: 12348, started: 13)), displayName: "楓之谷.exe")
let correlatedURL = ownerDirectory.appendingPathComponent(correlatedTicket.id.uuidString + ".json")
try JSONEncoder().encode(correlatedTicket).write(to: correlatedURL)
chmod(correlatedURL.path, 0o600)
let replacement = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
let rootObserver = CyderLaunchObserver(authority: .init(request: dispatched!.id, launch: dispatched!.launchID!,
    digest: dispatched!.digest, epoch: dispatched!.executorEpoch!))
var rootObservation: CyderLaunchObserver.Result?
Task.detached {
    let result = await rootObserver.wait(until: ProcessInfo.processInfo.systemUptime + 8,
        signal: WineActivationWaiter(prefix: CyderPaths.support.path))
    DispatchQueue.main.async { rootObservation = result }
}
var seen: [UUID: CyderExecutionOwner.Ticket] = [:]
replacement.onExecutionTickets = { tickets in
    for ticket in tickets {
        seen[ticket.id] = ticket
        guard let correlation = ticket.correlation, let spawn = ticket.nativeSpawn, let process = spawn.process else { continue }
        rootObserver.receive(.init(authority: .init(request: correlation.requestID, launch: correlation.launchID,
            digest: correlation.digest, epoch: ticket.issuer), ticket: ticket.id, phase: spawn.phase,
            pid: process.pid, boot: process.boot, started: process.started, status: spawn.status,
            signalled: spawn.signalled, prefixScope: ticket.scope))
    }
}
var nextRole: CyderInstanceCoordinator.Role?
var replayCount = 0
replacement.start(onRequest: { _ in replayCount += 1 }) { nextRole = $0 }
pump { nextRole != nil }
precondition(nextRole == .primary, "primary lock was not released")
pump { seen[correlatedTicket.id] != nil }
precondition(replayCount == 0, "reopening replayed an accepted request")
precondition(!FileManager.default.fileExists(atPath: legacyJournal.path) && !FileManager.default.fileExists(atPath: legacyOutbox.path),
             "legacy request files must be removed, never replayed")
precondition(seen[correlatedTicket.id]?.displayName == "楓之谷.exe", "running game lost its name across restart")
precondition(FileManager.default.fileExists(atPath: correlatedURL.path), "live root ticket was pruned")
// The native exit is written by the executor; the directory event alone (no
// manual refresh, no polling) delivers it, then the settled ticket is pruned.
var completedTicket = correlatedTicket
completedTicket.phase = .finished
completedTicket.nativeSpawn?.phase = .exited
completedTicket.nativeSpawn?.status = 53
completedTicket.nativeSpawn?.signalled = false
try JSONEncoder().encode(completedTicket).write(to: correlatedURL, options: .atomic)
chmod(correlatedURL.path, 0o600)
pump { rootObservation != nil }
precondition(rootObservation == .rootFailed(53), "native root result did not reach the formal launch observer")
precondition(seen[correlatedTicket.id]?.phase == .finished, "terminal ticket pruned before delivery")
pump { !FileManager.default.fileExists(atPath: correlatedURL.path) }
precondition(replayCount == 0)
var replacementSaved: Bool?
replacement.quiesce { replacementSaved = $0 }
pump { replacementSaved != nil }
var replacementStopped = false
replacement.stop { replacementStopped = true }
pump { replacementStopped }
let deliveriesAtStop = seen.count
try JSONEncoder().encode(correlatedTicket).write(to: correlatedURL, options: .atomic)
chmod(correlatedURL.path, 0o600)
var stoppedTick = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stoppedTick = true }
pump { stoppedTick }
precondition(seen.count == deliveriesAtStop && seen[correlatedTicket.id]?.phase == .finished, "ticket watch survived coordinator stop")
try FileManager.default.removeItem(at: correlatedURL)
print("PASS ticket-based recovery: no request persistence or replay, legacy files removed, running game keeps its name, event-delivered root result, settled ticket pruned after delivery, watch stops with coordinator")
print("PASS actual instance coordinator: single primary, mixed-batch ACK, queued children, quit/dispatch race, re-election, no replay")

// A bounded startup observation cannot grant authority when the physical
// election returns late. Stop completion tracks actual ownership release.
let delayedRoot = CyderPaths.support.appendingPathComponent("late")
let electionGate = DispatchSemaphore(value: 0)
let delayed = CyderInstanceCoordinator(support: delayedRoot, bundleID: "late", startupDeadline: 0.05,
                                       beforeElection: { electionGate.wait() })
var delayedRoles: [CyderInstanceCoordinator.Role] = []
delayed.start(onRequest: { _ in fatalError("late startup dispatched") }) { delayedRoles.append($0) }
pump { delayedRoles.count == 1 }
precondition(delayedRoles == [.unavailable])
var lateSubmit: Bool?
delayed.submit(.init(files: ["/trusted/late.exe"], arguments: nil, urls: [], showUI: false)) { lateSubmit = $0 }
precondition(lateSubmit == false)
var cleanupDone = false
delayed.stop { cleanupDone = true }
precondition(!cleanupDone, "observation deadline released physical startup ownership")
electionGate.signal()
pump { cleanupDone }
precondition(delayedRoles.count == 1, "late startup emitted a second role")
let afterLate = CyderInstanceCoordinator(support: delayedRoot, bundleID: "late")
var afterLateRole: CyderInstanceCoordinator.Role?
afterLate.start(onRequest: { _ in fatalError("startup timeout replayed") }) { afterLateRole = $0 }
pump { afterLateRole != nil }
precondition(afterLateRole == .primary, "late startup leaked its ownership")
var afterStopped = false; afterLate.stop { afterStopped = true }; pump { afterStopped }
print("PASS bounded startup: timeout refuses submit, late election cannot become primary, physical cleanup releases ownership, no replay")

// Receipt refresh owns one physical reader. Repeated invalidations coalesce
// into one additional scan; no second worker bypasses a blocked filesystem.
let scanRoot = CyderPaths.support.appendingPathComponent("receipt-scan")
let receiptScanGate = DispatchSemaphore(value: 0)
var receiptReadCount = 0, readsOnWorker = 0
let scanner = CyderInstanceCoordinator(support: scanRoot, bundleID: "receipt-scan", beforeExecutionRead: {
    readsOnWorker += 1
    let count = readsOnWorker
    DispatchQueue.main.async { receiptReadCount = count }
    if count == 1 { receiptScanGate.wait() }
})
var scannerRole: CyderInstanceCoordinator.Role?
scanner.start(onRequest: { _ in fatalError("receipt scan dispatched") }) { scannerRole = $0 }
pump { scannerRole != nil && receiptReadCount == 1 }
precondition(scannerRole == .primary)
for _ in 0..<60 { scanner.refreshExecutionReceipts() }
var scanTick = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scanTick = true }
pump { scanTick }
precondition(receiptReadCount == 1, "receipt refresh created more physical workers while blocked")
receiptScanGate.signal()
pump { receiptReadCount == 2 }
var scannerSaved: Bool?
scanner.quiesce { scannerSaved = $0 }
pump { scannerSaved != nil }
var scannerStopped = false
scanner.stop { scannerStopped = true }
pump { scannerStopped }
precondition(receiptReadCount == 2, "coalesced receipt refresh created unbounded rescans")
print("PASS native receipt reader: one actual worker during stall, responsive main loop, 60 invalidations coalesce to one follow-up, orderly quit")
