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
// An observation deadline does not prove the executor stopped. Preserve the
// payload and actual receipt layer, but never authorize another launch.
let timedOut = J.makeID(namespace: namespace)
_ = value(wait { journal.submit(id: timedOut, payload: payload, completion: $0) })
let timedDispatch = value(wait { journal.authorizeDispatch(id: timedOut, completion: $0) })
let nativeReceipt = value(wait { journal.receipt(id: timedOut, launchID: timedDispatch.launchID!, epoch: timedDispatch.executorEpoch!, supervisorPID: getpid(), layer: "native-launcher", boot: "test-boot", started: 1234, completion: $0) })
precondition(nativeReceipt.phase == .observing && nativeReceipt.receiptLayer == "native-launcher")
precondition(nativeReceipt.processBoot == "test-boot" && nativeReceipt.processStarted == 1234)
let unknown = value(wait { journal.complete(id: timedOut, launchID: timedDispatch.launchID!, epoch: timedDispatch.executorEpoch!, outcome: "observation-deadline", failed: false, uncertain: true, completion: $0) })
precondition(unknown.phase == .uncertain && unknown.payload == payload)
precondition(wait { journal.authorizeDispatch(id: timedOut, completion: $0) } == .failure(.tooLate))
precondition(wait { journal.resume(id: timedOut, completion: $0) } == .failure(.tooLate))
precondition(wait { journal.complete(id: timedOut, launchID: timedDispatch.launchID!, epoch: timedDispatch.executorEpoch!, outcome: "late-success", failed: false, completion: $0) } == .failure(.tooLate))
// Simulate process death by closing the owner without quiescing. A real disk
// reopen must preserve the dispatch boundary; an old executor may still spawn.
closeJournal(journal)
journal = J(directory: root, delivery: delivery)
let recovered = value(wait { journal.open(completion: $0) })
precondition(recovered.first { $0.id == id }?.phase == .uncertain)
precondition(recovered.first { $0.id == queued }?.phase == .awaitingUserResume)
precondition(recovered.first { $0.id == timedOut } == unknown, "uncertainty and native receipt must survive reopening")
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

// Saved settings are accepted exactly once, outside the client's payload hash.
let settingsURL = root.appendingPathComponent("settings.json")
let snapshotA = Data(#"{"schemaVersion":13,"dpi":144,"perProfile":{}}"#.utf8)
let snapshotB = Data(#"{"schemaVersion":13,"dpi":192,"perProfile":{}}"#.utf8)
try snapshotA.write(to: settingsURL)
let capture = { try CyderAcceptedSettings.capture(at: settingsURL) }
let settingsRoot = root.appendingPathComponent("immutable-settings")
var snapshots = J(directory: settingsRoot, delivery: delivery, captureSettings: capture)
_ = value(wait { snapshots.open(completion: $0) })
let settingsNamespace = wait { snapshots.namespace(completion: $0) }!
let settingsID = J.makeID(namespace: settingsNamespace)
snapshots.inject(.afterCommit)
snapshots.submit(id: settingsID, payload: payload) { _ in fatalError("lost ACK must not arrive") }
let acceptedA = value(wait { snapshots.query(id: settingsID, completion: $0) })
precondition(acceptedA.settingsSnapshot == snapshotA)
try snapshotB.write(to: settingsURL, options: .atomic)
let retryA = value(wait { snapshots.submit(id: settingsID, payload: payload, completion: $0) })
precondition(retryA == acceptedA, "ACK loss retry must preserve accepted settings")
let batchID = J.makeID(namespace: settingsNamespace)
let batchPayload = CyderRequestPayload(files: ["/a.exe", "/b.exe"], arguments: nil, urls: [], showUI: true)
let batch = value(wait { snapshots.submit(id: batchID, payload: batchPayload, completion: $0) })
precondition(batch.settingsSnapshot == nil && batch.children?.count == 3)
for childID in batch.children! {
    let child = value(wait { snapshots.query(id: childID, completion: $0) })
    precondition(child.settingsSnapshot == (child.payload!.showUI ? nil : snapshotB))
}
_ = value(wait { snapshots.cancel(id: batchID, digest: batchPayload.digest, completion: $0) })
for childID in batch.children! {
    let child = value(wait { snapshots.query(id: childID, completion: $0) })
    precondition(child.payload == nil && child.settingsSnapshot == nil)
}
closeJournal(snapshots)
snapshots = J(directory: settingsRoot, delivery: delivery, captureSettings: capture)
_ = value(wait { snapshots.open(completion: $0) })
let resumedA = value(wait { snapshots.resume(id: settingsID, completion: $0) })
precondition(resumedA.settingsSnapshot == snapshotA, "explicit resume must retain a previously accepted snapshot")
let dispatchA = value(wait { snapshots.authorizeDispatch(id: settingsID, completion: $0) })
let uncertainA = value(wait { snapshots.complete(id: settingsID, launchID: dispatchA.launchID!, epoch: dispatchA.executorEpoch!, outcome: "deadline", failed: false, uncertain: true, completion: $0) })
precondition(uncertainA.settingsSnapshot == snapshotA)
let terminalID = J.makeID(namespace: settingsNamespace)
_ = value(wait { snapshots.submit(id: terminalID, payload: payload, completion: $0) })
let terminalDispatch = value(wait { snapshots.authorizeDispatch(id: terminalID, completion: $0) })
let terminal = value(wait { snapshots.complete(id: terminalID, launchID: terminalDispatch.launchID!, epoch: terminalDispatch.executorEpoch!, outcome: "done", failed: false, completion: $0) })
precondition(terminal.settingsSnapshot == nil && terminal.payload == nil)
try Data("corrupt".utf8).write(to: settingsURL, options: .atomic)
precondition(value(wait { snapshots.submit(id: settingsID, payload: payload, completion: $0) }) == uncertainA)
let rejectedID = J.makeID(namespace: settingsNamespace)
precondition(wait { snapshots.submit(id: rejectedID, payload: payload, completion: $0) } == .failure(.invalid))
precondition(wait { snapshots.query(id: rejectedID, completion: $0) } == .failure(.missing))
let ui = CyderRequestPayload(files: [], arguments: nil, urls: [], showUI: true)
precondition(value(wait { snapshots.submit(id: J.makeID(namespace: settingsNamespace), payload: ui, completion: $0) }).settingsSnapshot == nil,
             "UI-only requests must not read corrupt saved launch preferences")
closeJournal(snapshots)
// Legacy records cannot gain new settings during restore; only explicit resume.
let legacyRoot = root.appendingPathComponent("legacy-settings")
let legacy = J(directory: legacyRoot, delivery: delivery)
_ = value(wait { legacy.open(completion: $0) })
let legacyNamespace = wait { legacy.namespace(completion: $0) }!
let legacyID = J.makeID(namespace: legacyNamespace)
_ = value(wait { legacy.submit(id: legacyID, payload: payload, completion: $0) })
closeJournal(legacy)
try snapshotB.write(to: settingsURL, options: .atomic)
let migration = J(directory: legacyRoot, delivery: delivery, captureSettings: capture)
let legacyRecords = value(wait { migration.open(completion: $0) })
precondition(legacyRecords[0].settingsSnapshot == nil && legacyRecords[0].phase == .awaitingUserResume)
precondition(value(wait { migration.resume(id: legacyID, completion: $0) }).settingsSnapshot == snapshotB)
closeJournal(migration)
for schema in 1...14 {
    precondition(CyderAcceptedSettings.isValid(Data("{\"schemaVersion\":\(schema)}".utf8)))
}
for bad in ["[]", "{\"schemaVersion\":15}", "{\"schemaVersion\":true}", "{\"schemaVersion\":1.5}"] {
    precondition(!CyderAcceptedSettings.isValid(Data(bad.utf8)))
}
try FileManager.default.removeItem(at: settingsURL)
let absent = try capture()
precondition(absent == Data("{}".utf8))
precondition(mkfifo(settingsURL.path, 0o600) == 0)
do { _ = try capture(); fatalError("FIFO must not block or become defaults") } catch {}
try FileManager.default.removeItem(at: settingsURL)
try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: settingsRoot)
do { _ = try capture(); fatalError("symlink must not become defaults") } catch {}
print("PASS accepted settings: immutable ACK retry/batch/resume, uncertainty, terminal purge, legacy resume, invalid/missing/FIFO/symlink")

// Correlated native evidence must survive recovery without claiming Windows
// success. These identities are injected journal data, not live processes.
let receiptRoot = root.appendingPathComponent("native-receipts")
let receiptJournal = J(directory: receiptRoot, delivery: delivery)
_ = value(wait { receiptJournal.open(completion: $0) })
let receiptNamespace = wait { receiptJournal.namespace(completion: $0) }!
let receiptID = J.makeID(namespace: receiptNamespace)
_ = value(wait { receiptJournal.submit(id: receiptID, payload: payload, completion: $0) })
let receiptDispatch = value(wait { receiptJournal.authorizeDispatch(id: receiptID, completion: $0) })
let ticketID = UUID()
func nativeReceipt(ticket: UUID = ticketID, id: String = receiptID, launch: String = receiptDispatch.launchID!,
                   epoch: UUID = receiptDispatch.executorEpoch!, digest: String = payload.digest,
                   phase: String = "finished", child: Int32 = 22002) -> J.ExecutionReceipt {
    .init(ticketID: ticket, requestID: id, launchID: launch, epoch: epoch, digest: digest,
          phase: phase, ownerPID: 22001, ownerBoot: "injected-boot", ownerStarted: 10,
          childPID: child, childBoot: "injected-boot", childStarted: 11,
          status: phase == "finished" ? 0 : nil, signalled: phase == "finished" ? false : nil)
}
let wrongReceipts = [nativeReceipt(id: J.makeID(namespace: receiptNamespace)),
    nativeReceipt(launch: UUID().uuidString), nativeReceipt(epoch: UUID()), nativeReceipt(digest: emptyArguments.digest)]
precondition(value(wait { receiptJournal.reconcileExecutions(wrongReceipts, completion: $0) }).isEmpty)
precondition(value(wait { receiptJournal.query(id: receiptID, completion: $0) }).executionReceipt == nil)
receiptJournal.inject(.beforeWrite)
precondition(wait { receiptJournal.reconcileExecutions([nativeReceipt()], completion: $0) } == .failure(.unavailable))
precondition(value(wait { receiptJournal.query(id: receiptID, completion: $0) }).executionReceipt == nil)
receiptJournal.inject(.afterCommit)
let lostReceiptACK = DispatchSemaphore(value: 0)
receiptJournal.reconcileExecutions([nativeReceipt()]) { _ in lostReceiptACK.signal() }
let storedReceipt = value(wait { receiptJournal.query(id: receiptID, completion: $0) })
precondition(lostReceiptACK.wait(timeout: .now()) == .timedOut)
precondition(storedReceipt.executionReceipt == nativeReceipt() && storedReceipt.phase == .dispatching)
precondition(value(wait { receiptJournal.reconcileExecutions([nativeReceipt()], completion: $0) }) == [ticketID])
precondition(value(wait { receiptJournal.reconcileExecutions([nativeReceipt(phase: "active"), nativeReceipt(ticket: UUID()), nativeReceipt(child: 22003)], completion: $0) }).isEmpty)
precondition(value(wait { receiptJournal.query(id: receiptID, completion: $0) }).executionReceipt == nativeReceipt())
// Wine-layer progress is independently monotonic inside the native receipt.
let spawnID = J.makeID(namespace: receiptNamespace)
_ = value(wait { receiptJournal.submit(id: spawnID, payload: payload, completion: $0) })
let spawnDispatch = value(wait { receiptJournal.authorizeDispatch(id: spawnID, completion: $0) })
let spawnTicketID = UUID()
func wineReceipt(_ phase: String, process: Int32 = 24002, bridge: Int32 = 24001, scope: String? = "501:1:2") -> J.ExecutionReceipt {
    .init(ticketID: spawnTicketID, requestID: spawnID, launchID: spawnDispatch.launchID!,
          epoch: spawnDispatch.executorEpoch!, digest: payload.digest, phase: "handedOff",
          ownerPID: 23001, ownerBoot: "injected-boot", ownerStarted: 20,
          childPID: 23002, childBoot: "injected-boot", childStarted: 21, status: 0, signalled: false,
          nativeSpawn: .init(phase: phase, bridgePID: bridge, bridgeBoot: "injected-boot", bridgeStarted: 22,
              processPID: process, processBoot: "injected-boot", processStarted: 23,
              status: phase == "exited" ? 53 : nil, signalled: phase == "exited" ? false : nil), prefixScope: scope)
}
precondition(value(wait { receiptJournal.reconcileExecutions([wineReceipt("spawned")], completion: $0) }) == [spawnTicketID])
precondition(value(wait { receiptJournal.reconcileExecutions([wineReceipt("exited")], completion: $0) }) == [spawnTicketID])
precondition(value(wait { receiptJournal.reconcileExecutions([wineReceipt("spawned"), wineReceipt("exited", process: 24003), wineReceipt("exited", bridge: 24004), wineReceipt("exited", scope: nil), wineReceipt("exited", scope: "501:1:3")], completion: $0) }).isEmpty)
precondition(value(wait { receiptJournal.query(id: spawnID, completion: $0) }).executionReceipt == wineReceipt("exited"))
// Legacy terminal receipts can gain only the omitted native prefix proof.
var upgradedLegacy = nativeReceipt()
upgradedLegacy.prefixScope = "501:10:20"
precondition(value(wait { receiptJournal.reconcileExecutions([upgradedLegacy], completion: $0) }) == [ticketID])
precondition(value(wait { receiptJournal.query(id: receiptID, completion: $0) }).executionReceipt == upgradedLegacy)
print("PASS native Wine receipt: exact bridge/child birth retained, late spawn and replaced identities cannot regress a persisted root outcome")
closeJournal(receiptJournal)
let receiptRecovery = J(directory: receiptRoot, delivery: delivery)
let reopenedReceipts = value(wait { receiptRecovery.open(completion: $0) })
precondition(reopenedReceipts.count == 2 && reopenedReceipts.first { $0.id == receiptID }?.phase == .uncertain && reopenedReceipts.first { $0.id == receiptID }?.executionReceipt == upgradedLegacy)
precondition(wait { receiptRecovery.authorizeDispatch(id: receiptID, completion: $0) } == .failure(.tooLate))
precondition(wait { receiptRecovery.resume(id: receiptID, completion: $0) } == .failure(.tooLate))
closeJournal(receiptRecovery)
print("PASS native receipt journal: exact ID/digest/launch/epoch, durable ACK retry, stale/conflicting evidence refused, no Windows success or replay on recovery")
