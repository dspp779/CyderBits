import Foundation
import Darwin
func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    guard condition() else { fputs("FAIL gate deadline\n", stderr); exit(1) }
}
let gate = CyderOperationGate(), runner = CyderProcessRunner()
let one = CyderOperationGate.Scope.environment("one"), two = CyderOperationGate.Scope.environment("two")
var stopLease: CyderOperationGate.Lease?
gate.acquire(one) { stopLease = $0 }
pump { stopLease != nil }
var launchedOne = false, launchedTwo = false, releasedStop = false, timedOut = false
let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/bin/sleep"); stop.arguments = ["0.4"]
runner.run(process: stop, policy: .mutation, deadline: 0.03, onRelease: {
    releasedStop = true; gate.release(stopLease!)
}) { outcome in precondition(outcome == .unconfirmed); timedOut = true }
var oneLease: CyderOperationGate.Lease?, twoLease: CyderOperationGate.Lease?
gate.acquire(one) { oneLease = $0; launchedOne = true }
gate.acquire(two) { twoLease = $0; launchedTwo = true }
pump { timedOut && launchedTwo }
precondition(!launchedOne && !releasedStop, "observation timeout released a still-running mutation")
pump { launchedOne }
precondition(releasedStop, "same-bottle launch passed stop before executor exit")
gate.release(stopLease!) // stale release cannot release the newer oneLease

var globalLease: CyderOperationGate.Lease?, afterBarrier: CyderOperationGate.Lease?
gate.acquire(.allEnvironments) { globalLease = $0 }
gate.acquire(two) { afterBarrier = $0 }
gate.release(twoLease!)
var barrierTick = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { barrierTick = true }
pump { barrierTick }
precondition(globalLease == nil && afterBarrier == nil, "conflicting FIFO barrier was bypassed")
gate.release(oneLease!)
pump { globalLease != nil }
precondition(afterBarrier == nil)
gate.release(globalLease!)
pump { afterBarrier != nil }
gate.release(afterBarrier!)

// Drive the real durable journal at the same boundary as the app: cancellation
// remains legal while an environment lease is waiting, before authorization.
let journal = CyderRequestJournal(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
var opened = false; journal.open { result in guard case .success = result else { fatalError() }; opened = true }
pump { opened }
var ns: UUID?; journal.namespace { ns = $0 }; pump { ns != nil }
let id = CyderRequestJournal.makeID(namespace: ns!)
let payload = CyderRequestPayload(files: ["/trusted/test.exe"], arguments: nil, urls: [], showUI: false)
var accepted = false; journal.submit(id: id, payload: payload) { result in guard case .success = result else { fatalError() }; accepted = true }
pump { accepted }
var blocker: CyderOperationGate.Lease?; gate.acquire(one) { blocker = $0 }; pump { blocker != nil }
var authorizeResult: Result<CyderRequestJournal.Record, CyderRequestJournal.Failure>?
gate.acquire(one) { lease in
    precondition(lease != nil)
    journal.authorizeDispatch(id: id) { result in authorizeResult = result; gate.release(lease!) }
}
var cancelled = false
journal.cancel(id: id, digest: payload.digest) { result in
    guard case .success(let record) = result else { fatalError() }
    precondition(record.phase == .cancelled); cancelled = true
}
pump { cancelled }; precondition(authorizeResult == nil)
gate.release(blocker!)
pump { authorizeResult != nil }; precondition(authorizeResult == .failure(.tooLate))

var held: CyderOperationGate.Lease?; gate.acquire(one) { held = $0 }; pump { held != nil }
var cancelledAcquisition = false
let cancelID = gate.acquire(one) { lease in precondition(lease == nil); cancelledAcquisition = true }
gate.cancel(cancelID); pump { cancelledAcquisition }
var quitReply = false
gate.acquire(one) { lease in precondition(lease == nil); quitReply = true }
gate.quiesce(); pump { quitReply }
var lateReply = false
gate.acquire(two) { lease in precondition(lease == nil); lateReply = true }; pump { lateReply }
gate.release(held!)
var closed = false; journal.close { closed = true }; pump { closed }
print("PASS formal gate/runner/journal: stop timeout retains ownership, independent bottle, global barrier, stale release, cancellation before dispatch, quit freezes pending effects")
