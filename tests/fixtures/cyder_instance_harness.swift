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
let replacement = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var nextRole: CyderInstanceCoordinator.Role?
var replayCount = 0
replacement.start(onRequest: { _ in replayCount += 1 }) { nextRole = $0 }
pump { nextRole != nil }
precondition(nextRole == .primary, "primary lock was not released")
precondition(replayCount == 0, "reopening replayed an accepted request")
precondition(replacement.recovered.filter { $0.phase == .awaitingUserResume }.count >= 1)
precondition(replacement.recovered.contains { $0.id == dispatched!.id && $0.phase == .uncertain })
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
