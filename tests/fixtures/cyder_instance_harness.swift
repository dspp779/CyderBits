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
let staleExecution = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: UUID(), scope: nil, phase: "prepared")
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
precondition(recoveredExecution.phase == "revoked", "primary admitted requests before revoking an unclaimed old executor")
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
var dispatched: CyderRequestJournal.Record?
var authorized = false
primary.authorize(received[0].record) { dispatched = $0; authorized = true }
pump { authorized }
precondition(dispatched?.phase == .dispatching)
precondition(dispatched?.settingsSnapshot == acceptedPreferences, "dispatch reread mutable settings")
// Quit races with a queued authorization: at most committed dispatch is uncertain;
// completion cannot release a new spawn after the main-thread freeze.
var late: CyderRequestJournal.Record?
var lateDone = false
primary.authorize(received[1].record) { late = $0; lateDone = true }
var saved: Bool?
primary.quiesce { saved = $0 }
pump { saved != nil && lateDone }
precondition(saved == true && late == nil)
var stopped = false
primary.stop { stopped = true }
pump { stopped }
// A completed native executor receipt arriving while no primary exists must
// join its original request on re-election, then be safely pruned only after
// the journal has saved it. This is explicitly injected native-layer evidence.
let correlatedTicket = CyderExecutionOwner.Ticket(schema: 1, id: UUID(), issuer: dispatched!.executorEpoch!,
    scope: "injected-prefix-scope", prefix: CyderPaths.support.path, phase: "finished", owner: .init(boot: "injected-native-boot", pid: 12345, started: 10),
    child: .init(boot: "injected-native-boot", pid: 12346, started: 11), status: 0, signalled: false,
    correlation: .init(requestID: dispatched!.id, launchID: dispatched!.launchID!, digest: dispatched!.digest),
    handoff: .init(executable: "/injected/wine", pidFile: CyderPaths.support.appendingPathComponent("injected.pid").path),
    nativeSpawn: .init(phase: "exited", bridge: .init(boot: "injected-native-boot", pid: 12347, started: 12),
        process: .init(boot: "injected-native-boot", pid: 12348, started: 13), status: 53, signalled: false))
let correlatedURL = ownerDirectory.appendingPathComponent(correlatedTicket.id.uuidString + ".json")
try JSONEncoder().encode(correlatedTicket).write(to: correlatedURL)
chmod(correlatedURL.path, 0o600)
let replacement = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var nextRole: CyderInstanceCoordinator.Role?
var replayCount = 0
replacement.start(onRequest: { _ in replayCount += 1 }) { nextRole = $0 }
pump { nextRole != nil }
precondition(nextRole == .primary, "primary lock was not released")
precondition(replayCount == 0, "reopening replayed an accepted request")
precondition(replacement.recovered.filter { $0.phase == .awaitingUserResume }.count >= 1)
precondition(replacement.recovered.contains { $0.id == dispatched!.id && $0.phase == .uncertain })
pump { replacement.recovered.first { $0.id == dispatched!.id }?.executionReceipt?.ticketID == correlatedTicket.id }
pump { !FileManager.default.fileExists(atPath: correlatedURL.path) }
precondition(replacement.recovered.first { $0.id == dispatched!.id }?.executionReceipt?.nativeSpawn?.status == 53,
             "executor pruning lost the distinct native Wine root result")
precondition(replacement.recovered.first { $0.id == dispatched!.id }?.phase == .uncertain,
             "native exit was incorrectly promoted to a confirmed Windows launch")
precondition(replayCount == 0)
var replacementSaved: Bool?
replacement.quiesce { replacementSaved = $0 }
pump { replacementSaved != nil }
var replacementStopped = false
replacement.stop { replacementStopped = true }
pump { replacementStopped }
print("PASS actual instance coordinator: single primary, durable mixed-batch ACK, queued children, quit/dispatch race, re-election, no replay")

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

let corruptPath = delayedRoot.appendingPathComponent("request-journal/requests-v1.json")
let corruptBytes = Data("corrupt durable request history".utf8)
try corruptBytes.write(to: corruptPath)
let corruptOwner = CyderInstanceCoordinator(support: delayedRoot, bundleID: "late")
var corruptRole: CyderInstanceCoordinator.Role?
corruptOwner.start(onRequest: { _ in fatalError("corrupt journal dispatched") }) { corruptRole = $0 }
pump { corruptRole != nil }
precondition(corruptRole == .unavailable)
var corruptStopped = false; corruptOwner.stop { corruptStopped = true }; pump { corruptStopped }
let remainingBytes = try Data(contentsOf: corruptPath)
precondition(remainingBytes == corruptBytes, "unavailable startup overwrote corrupt journal")
print("PASS startup corruption: read-only outcome, no dispatch, original history preserved")

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
