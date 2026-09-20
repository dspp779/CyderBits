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
let primary = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var role: CyderInstanceCoordinator.Role?
var received: [CyderInstanceRequest] = []
primary.start(onRequest: { received.append($0) }) { role = $0 }
pump { role != nil }
precondition(role == .primary)
let secondary = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "test")
var secondRole: CyderInstanceCoordinator.Role?
secondary.start(onRequest: { _ in fatalError("secondary dispatch") }) { secondRole = $0 }
pump { secondRole != nil }
precondition(secondRole == .secondary, "second primary elected")
var ack: Bool?
secondary.forward(files: ["/trusted/one.exe", "/trusted/two.exe"], arguments: [], urls: ["test://uri"], showUI: false) { ack = $0 }
pump { ack != nil && received.count == 3 }
precondition(ack == true)
precondition(Set(received.map { $0.record.id }).count == 3, "batch must have separate durable child IDs")
precondition(received[0].files == ["/trusted/one.exe"] && received[1].files == ["/trusted/two.exe"] && received[2].urls == ["test://uri"], "mixed batch order/content lost")
precondition(received.allSatisfy { $0.arguments == [] && $0.record.phase == .queued })
var dispatched: CyderRequestJournal.Record?
var authorized = false
primary.authorize(received[0].record) { dispatched = $0; authorized = true }
pump { authorized }
precondition(dispatched?.phase == .dispatching)
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
