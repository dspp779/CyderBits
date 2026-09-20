import Foundation
import Darwin

typealias J = CyderRequestJournal
let delivery = DispatchQueue(label: "test.delivery")
func wait<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T?
    work { result = $0; semaphore.signal() }
    precondition(semaphore.wait(timeout: .now() + 10) == .success, "asynchronous reply missing")
    return result!
}
func value<T>(_ result: Result<T, J.Failure>) -> T {
    guard case .success(let value) = result else { fatalError("unexpected \(result)") }
    return value
}
func closeJournal(_ journal: J) {
    let _: Bool = wait { done in journal.close { done(true) } }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "crash-after-dispatch" {
    let child = J(directory: root, delivery: delivery)
    _ = value(wait { child.open(completion: $0) })
    let namespace = wait { child.namespace(completion: $0) }!
    let id = J.makeID(namespace: namespace)
    let payload = CyderRequestPayload(files: ["/trusted/crash.exe"], arguments: nil, urls: [], showUI: false)
    _ = value(wait { child.submit(id: id, payload: payload, completion: $0) })
    _ = value(wait { child.authorizeDispatch(id: id, completion: $0) })
    _exit(73) // no quiesce, deinit or completion cleanup
}
let crashRoot = root.appendingPathComponent("crash-child")
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = [crashRoot.path, "crash-after-dispatch"]
try child.run()
child.waitUntilExit() // harness only; product never uses this to wait for Wine
precondition(child.terminationStatus == 73)
let crashRecovery = J(directory: crashRoot, delivery: delivery)
let crashRecords = value(wait { crashRecovery.open(completion: $0) })
precondition(crashRecords.count == 1 && crashRecords[0].phase == .uncertain)
precondition(wait { crashRecovery.authorizeDispatch(id: crashRecords[0].id, completion: $0) } == .failure(.tooLate))
closeJournal(crashRecovery)

let payload = CyderRequestPayload(files: ["/trusted/test.exe"], arguments: nil, urls: [], showUI: false)
let emptyArguments = CyderRequestPayload(files: ["/trusted/test.exe"], arguments: [], urls: [], showUI: false)
precondition(payload.digest != emptyArguments.digest, "nil and empty argv are different immutable payloads")
var journal = J(directory: root, delivery: delivery)
_ = value(wait { journal.open(completion: $0) })
let namespace = wait { journal.namespace(completion: $0) }!
precondition(wait { journal.open(completion: $0) } == .failure(.unavailable), "repeated open must not unlock existing journal")
let duplicateOwner = J(directory: root, delivery: delivery)
let denied: Result<[J.Record], J.Failure> = wait { duplicateOwner.open(completion: $0) }
if case .success = denied { fatalError("two journal owners acquired the same lock") }
let id = J.makeID(namespace: namespace)
journal.inject(.afterCommit)
let unexpectedACK = DispatchSemaphore(value: 0)
journal.submit(id: id, payload: payload) { _ in unexpectedACK.signal() }
let committed = value(wait { journal.query(id: id, completion: $0) })
precondition(unexpectedACK.wait(timeout: .now()) == .timedOut, "lost ACK fault was not exercised")
let retransmitted = value(wait { journal.submit(id: id, payload: payload, completion: $0) })
precondition(committed == retransmitted, "same ID retry mutated or duplicated acceptance")
let mismatch = wait { journal.submit(id: id, payload: emptyArguments, completion: $0) }
precondition(mismatch == .failure(.conflictingPayload))
let dispatch = value(wait { journal.authorizeDispatch(id: id, completion: $0) })
precondition(dispatch.phase == .dispatching)
precondition(wait { journal.cancel(id: id, digest: payload.digest, completion: $0) } == .failure(.tooLate))
precondition(wait { journal.authorizeDispatch(id: id, completion: $0) } == .failure(.tooLate))
let before = J.makeID(namespace: namespace)
_ = value(wait { journal.cancel(id: before, digest: payload.digest, completion: $0) })
precondition(value(wait { journal.submit(id: before, payload: payload, completion: $0) }).phase == .cancelled)
precondition(wait { journal.authorizeDispatch(id: before, completion: $0) } == .failure(.tooLate))
let queued = J.makeID(namespace: namespace)
_ = value(wait { journal.submit(id: queued, payload: payload, completion: $0) })
// Simulate process death by closing the owner without quiescing. A real disk
// reopen must preserve the dispatch boundary; an old executor may still spawn.
closeJournal(journal)
journal = J(directory: root, delivery: delivery)
let recovered = value(wait { journal.open(completion: $0) })
precondition(recovered.first { $0.id == id }?.phase == .uncertain)
precondition(recovered.first { $0.id == queued }?.phase == .awaitingUserResume)
precondition(wait { journal.authorizeDispatch(id: id, completion: $0) } == .failure(.tooLate))
precondition(wait { journal.resume(id: id, completion: $0) } == .failure(.tooLate))
precondition(wait { journal.receipt(id: id, launchID: dispatch.launchID!, epoch: dispatch.executorEpoch!, supervisorPID: getpid(), completion: $0) } == .failure(.tooLate), "late executor cannot change recovered generation")
let resumed = value(wait { journal.resume(id: queued, completion: $0) })
precondition(resumed.phase == .queued)
let failedWrite = J.makeID(namespace: namespace)
journal.inject(.beforeWrite)
precondition(wait { journal.submit(id: failedWrite, payload: payload, completion: $0) } == .failure(.unavailable))
precondition(wait { journal.query(id: failedWrite, completion: $0) } == .failure(.missing), "failed transaction was acknowledged in memory")
precondition(wait { journal.quiesce(completion: $0) })
precondition(value(wait { journal.query(id: queued, completion: $0) }).phase == .awaitingUserResume)
precondition(wait { journal.authorizeDispatch(id: queued, completion: $0) } == .failure(.closing))
precondition(wait { journal.submit(id: failedWrite, payload: payload, completion: $0) } == .failure(.closing))
closeJournal(journal)
// Fresh ID namespaces reject retired IDs even if a different installation has
// no tombstone for them; corrupted history never becomes an empty queue.
let alternate = J(directory: root.appendingPathComponent("other"), delivery: delivery)
_ = value(wait { alternate.open(completion: $0) })
precondition(wait { alternate.submit(id: id, payload: payload, completion: $0) } == .failure(.invalid))
closeJournal(alternate)
try Data("corrupt".utf8).write(to: root.appendingPathComponent("requests-v1.json"))
let corrupt = J(directory: root, delivery: delivery)
precondition(wait { corrupt.open(completion: $0) } == .failure(.corrupt))
precondition(wait { corrupt.submit(id: failedWrite, payload: payload, completion: $0) } == .failure(.unavailable))
let missingRoot = root.appendingPathComponent("missing-history")
let missing = J(directory: missingRoot, delivery: delivery)
_ = value(wait { missing.open(completion: $0) })
closeJournal(missing)
try FileManager.default.removeItem(at: missingRoot.appendingPathComponent("requests-v1.json"))
let lost = J(directory: missingRoot, delivery: delivery)
precondition(wait { lost.open(completion: $0) } == .failure(.corrupt))
print("PASS journal: durable ACK loss/dedupe, ownership, nil argv, cancel/dispatch, crash recovery, late receipt, disk fault, quiesce, corrupt history")
