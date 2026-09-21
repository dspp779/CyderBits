import Cocoa
import Foundation
import Darwin
enum CyderPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
func check(_ value: @autoclosure () -> Bool, _ message: String = "assertion failed", line: UInt = #line) {
    guard value() else { fputs("FAIL outbox line \(line): \(message)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10, line: UInt = #line) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "callback deadline", line: line)
}
func result<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    var value: T?; body { value = $0 }; pump { value != nil }; return value!
}
func io<T>(_ body: @escaping () throws -> T) throws -> T {
    let outcome: Result<T, Error> = result { done in
        DispatchQueue.global().async { let value = Result { try body() }; DispatchQueue.main.async { done(value) } }
    }
    return try outcome.get()
}
func ok<T>(_ value: Result<T, CyderRequestJournal.Failure>) -> T {
    guard case .success(let success) = value else { fputs("FAIL journal \(value)\n", stderr); exit(1) }; return success
}
_ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
let root = CyderPaths.support
let journal = CyderRequestJournal(directory: root.appendingPathComponent("request-journal"))
_ = ok(result { journal.open(completion: $0) })
let namespace: UUID = result { done in journal.namespace { done($0!) } }
func message(_ name: String, namespace: UUID = namespace, id: String? = nil) -> CyderRequestMessage {
    let payload = CyderRequestPayload(files: ["/trusted/\(name).exe"], arguments: ["secret-never-display"], urls: [], showUI: false)
    return .init(protocolVersion: 1, kind: "submit", requestID: id ?? CyderRequestJournal.makeID(namespace: namespace),
                 payloadDigest: payload.digest, senderEpoch: UUID(), payload: payload)
}
func file(_ message: CyderRequestMessage) -> URL {
    root.appendingPathComponent("request-outbox/" + message.requestID!.replacingOccurrences(of: ":", with: "-") + ".json")
}
let acknowledged = message("lost-ack"), uncertain = message("already-dispatched"), conflict = message("conflict")
for item in [acknowledged, uncertain, conflict] {
    _ = ok(result { journal.submit(id: item.requestID!, payload: item.payload!, completion: $0) })
}
_ = ok(result { journal.authorizeDispatch(id: uncertain.requestID!, completion: $0) })
let missing = message("not-found"), oldNamespace = message("old-namespace", namespace: UUID())
let changed = message("changed-payload", id: conflict.requestID!)
for item in [acknowledged, uncertain, changed, missing, oldNamespace] { try io { try CyderRequestOutbox.save(item, support: root) } }
let outbox = root.appendingPathComponent("request-outbox")
let originalMissing = try Data(contentsOf: file(missing))
let legacy = outbox.appendingPathComponent("legacy.json")
try Data("{broken".utf8).write(to: legacy); chmod(legacy.path, 0o600)
let fifo = outbox.appendingPathComponent("blocked.json"); check(mkfifo(fifo.path, 0o600) == 0)
let linked = outbox.appendingPathComponent("linked.json"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file(missing))
let _: Bool = result { done in journal.close { done(true) } }
let controller = CyderRequestWindowController()
let coordinator = CyderInstanceCoordinator(support: root, bundleID: "outbox-test")
var records: [CyderRequestJournal.Record] = [], notices: [CyderOutboxNotice] = [], callbacks = 0, dispatched = 0
var dispatchRecords: [CyderRequestJournal.Record] = []
coordinator.onRecoveryChanged = { records = $0; controller.update(records, outbox: notices) }
coordinator.onOutboxChanged = { notices = $0; callbacks += 1; controller.update(records, outbox: notices) }
let role = result { done in coordinator.start(onRequest: { dispatched += 1; dispatchRecords.append($0.record) }, completion: done) }
check(role == .primary)
pump { callbacks == 1 }
check(dispatched == 0, "outbox restoration dispatched a request")
check(notices.count == 6, "missing/conflict/old namespace/corrupt/FIFO/symlink must remain visible")
check(!FileManager.default.fileExists(atPath: file(acknowledged).path))
check(!FileManager.default.fileExists(atPath: file(uncertain).path))
let afterMissing = try Data(contentsOf: file(missing)); check(afterMissing == originalMissing)
check(FileManager.default.fileExists(atPath: file(changed).path) && FileManager.default.fileExists(atPath: file(oldNamespace).path))
check(records.contains { $0.id == acknowledged.requestID && $0.phase == .awaitingUserResume })
check(records.contains { $0.id == uncertain.requestID && $0.phase == .uncertain })
var unsafeActions = 0
controller.onResume = { _, _ in unsafeActions += 1 }; controller.onCancel = { _, _ in unsafeActions += 1 }
for notice in notices {
    let row = controller.rows.first { $0.id == notice.id }!
    check(!row.canResume && !row.canCancel)
    controller.perform(.resume, id: row.id); controller.perform(.cancel, id: row.id)
}
check(unsafeActions == 0 && !String(describing: controller.rows).contains("secret-never-display"))
check(CyderRequestRow.summary(records, outbox: notices).contains("核對"))
coordinator.refreshRequests(); pump { callbacks == 2 }
check(notices.count == 6 && dispatched == 0)
if let path = ProcessInfo.processInfo.environment["CYDER_TEST_RENDER"] {
    controller.update([], outbox: notices.filter(\.canRecover))
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    controller.update(records, outbox: notices)
}
// Drive real table buttons, then revalidate the original bytes and journal.
controller.onResend = { coordinator.recoverOutbox(id: $0, cancel: false, completion: $1) }
controller.onWithdraw = { coordinator.recoverOutbox(id: $0, cancel: true, completion: $1) }
func click(_ id: String, tag: Int) -> NSButton {
    let row = controller.rows.firstIndex { $0.id == id }!
    let cell = controller.tableView(NSTableView(), viewFor: nil, row: row)!
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let button = buttons(cell).first { $0.tag == tag }!
    button.performClick(nil); return button
}
let staleResend = click("outbox:" + missing.requestID!, tag: 2)
pump { dispatched == 1 && !notices.contains { $0.id == "outbox:" + missing.requestID! } }
check(dispatchRecords[0].id == missing.requestID, "resend generated a new request ID")
staleResend.performClick(nil); check(dispatched == 1)
pump { !FileManager.default.fileExists(atPath: file(missing).path) }
// Wait for the explicit post-cleanup snapshot before admitting another action.
let withdrawn = message("withdrawn"), replaced = message("replaced"), raced = message("race")
for item in [withdrawn, replaced, raced] { try io { try CyderRequestOutbox.save(item, support: root) } }
coordinator.refreshRequests()
pump { notices.contains { $0.requestID == withdrawn.requestID } }
_ = click("outbox:" + withdrawn.requestID!, tag: 3)
pump { records.contains { $0.id == withdrawn.requestID && $0.phase == .cancelled } }
func exchange(_ message: CyderRequestMessage) throws -> CyderRequestReply {
    guard let reply = try io({ CyderRequestChannel.exchange(path: root.appendingPathComponent(".requests-v1.sock").path, message: message) }) else {
        check(false, "missing channel reply"); exit(1)
    }
    return reply
}
let lateSubmit = try exchange(withdrawn)
check(lateSubmit.status == "accepted" && lateSubmit.record?.phase == .cancelled && dispatched == 1,
      "withdrawal failed to fence a late same-ID submit")
pump { !FileManager.default.fileExists(atPath: file(withdrawn).path) }
// Changing the file behind a visible row cannot change the authorized payload.
coordinator.refreshRequests(); let expectedCallbacks = callbacks + 1; pump { callbacks >= expectedCallbacks }
let replacementBytes = try JSONEncoder().encode(message("different", id: replaced.requestID!))
try replacementBytes.write(to: file(replaced)); chmod(file(replaced).path, 0o600)
let afterReplacementRefresh = callbacks + 1
let replacementResult: Bool = result { coordinator.recoverOutbox(id: "outbox:" + replaced.requestID!, cancel: false, completion: $0) }
check(!replacementResult && dispatched == 1 && !records.contains { $0.id == replaced.requestID })
let preservedReplacement = try Data(contentsOf: file(replaced)); check(preservedReplacement == replacementBytes)
// A submit wins after the old row was shown; cancellation must become too late.
pump { callbacks >= afterReplacementRefresh }
check(notices.contains { $0.requestID == raced.requestID && $0.canRecover })
let racingSubmit = try exchange(raced)
pump { dispatchRecords.contains { $0.id == raced.requestID } }
let racingRecord = dispatchRecords.first { $0.id == raced.requestID }!
let authorized: CyderRequestJournal.Record? = result { coordinator.authorize(racingRecord, completion: $0) }
check(authorized?.phase == .dispatching)
check(notices.contains { $0.requestID == raced.requestID && $0.canRecover })
check(FileManager.default.fileExists(atPath: file(raced).path))
let cancelRaced: Bool = result { coordinator.recoverOutbox(id: "outbox:" + raced.requestID!, cancel: true, completion: $0) }
check(!cancelRaced && !records.contains { $0.id == raced.requestID && $0.phase == .cancelled })
check(dispatched == 2 && racingSubmit.record?.id == raced.requestID)
check(controller.rows.filter { $0.id.contains(oldNamespace.requestID!) }.allSatisfy { !$0.canResend && !$0.canWithdraw })
print("PASS explicit recovery: real AppKit buttons, same-ID resend once, durable withdrawal fences late submit, replaced bytes refused, dispatch wins cancellation race")
let _: Bool = result { done in coordinator.stop { done(true) } }
print("PASS retained outbox: same-ID durable reconciliation, ACK loss cleanup, no replay, conflict/old/corrupt/FIFO/symlink preservation, formal UI capability fence")

// A physically blocked scan has one owner even across repeated refreshes;
// quitting prevents a late result from updating the UI.
let slowRoot = root.appendingPathComponent("slow")
let gate = DispatchSemaphore(value: 0), lock = NSLock()
var reads = 0
let slow = CyderInstanceCoordinator(support: slowRoot, bundleID: "slow-outbox", outboxDeadline: 0.03, beforeOutboxRead: {
    lock.lock(); reads += 1; lock.unlock(); gate.wait()
})
var slowNotices: [CyderOutboxNotice] = [], slowCallbacks = 0
slow.onOutboxChanged = { slowNotices = $0; slowCallbacks += 1 }
let slowRole = result { done in slow.start(onRequest: { _ in check(false, "slow scan dispatched") }, completion: done) }
check(slowRole == .primary)
pump { slowCallbacks == 1 }
for _ in 0..<60 { slow.refreshRequests() }
var tick = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { tick = true }; pump { tick }
lock.lock(); let readCount = reads; lock.unlock()
check(readCount == 1 && slowNotices.first?.detail.contains("尚未確認") == true)
let _: Bool = result { done in slow.stop { done(true) } }
gate.signal(); tick = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tick = true }; pump { tick }
check(slowCallbacks == 1, "late outbox callback crossed quit")
print("PASS outbox scan: one physical reader, responsive deadline, repeated refresh bounded, quit fences late UI")

// A stalled durable copy cannot hide the delivery deadline or send after it.
let deliveryRoot = root.appendingPathComponent("delivery")
let receiver = CyderInstanceCoordinator(support: deliveryRoot, bundleID: "delivery")
var delivered = 0
let receiverRole = result { done in receiver.start(onRequest: { _ in delivered += 1 }, completion: done) }
check(receiverRole == .primary)
let writeGate = DispatchSemaphore(value: 0), writeLock = NSLock()
var writes = 0
let sender = CyderInstanceCoordinator(support: deliveryRoot, bundleID: "delivery", forwardDeadline: 0.2, beforeForwardSave: {
    writeLock.lock(); writes += 1; writeLock.unlock(); writeGate.wait()
})
let senderRole = result { done in sender.start(onRequest: { _ in check(false) }, completion: done) }
check(senderRole == .secondary)
var deliveryReplies: [Bool] = []
sender.forward(files: ["/trusted/late-copy.exe"], arguments: nil, showUI: false) { deliveryReplies.append($0) }
pump { writeLock.lock(); defer { writeLock.unlock() }; return writes == 1 }
pump { deliveryReplies.count == 1 }
check(deliveryReplies == [false] && delivered == 0)
var rejected = 0
for _ in 0..<60 {
    sender.forward(files: ["/trusted/duplicate.exe"], arguments: nil, showUI: false) { if !$0 { rejected += 1 } }
}
check(rejected == 60)
writeGate.signal()
var copied = false
let copyPath = deliveryRoot.appendingPathComponent("request-outbox")
pump { copied = (try? FileManager.default.contentsOfDirectory(atPath: copyPath.path).contains { $0.hasSuffix(".json") }) == true; return copied }
tick = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tick = true }; pump { tick }
check(deliveryReplies == [false] && delivered == 0, "late persistence sent or replied twice")
let copyNotices = try io { try CyderRequestOutbox.reconcile(support: deliveryRoot, records: []) }
check(copyNotices.count == 1 && copyNotices[0].title == "late-copy.exe")
let _: Bool = result { done in sender.stop { done(true) } }
let _: Bool = result { done in receiver.stop { done(true) } }
print("PASS forwarding: deadline independent of blocked persistence, one physical writer, original copy retained, no late send or repeated completion")

// Expiring a recovery read ends observation; it cannot later submit or cancel.
let actionRoot = root.appendingPathComponent("action-deadline")
let actionJournal = CyderRequestJournal(directory: actionRoot.appendingPathComponent("request-journal"))
_ = ok(result { actionJournal.open(completion: $0) })
let actionNamespace: UUID = result { done in actionJournal.namespace { done($0!) } }
let _: Bool = result { done in actionJournal.close { done(true) } }
let actionMessage = message("late-action", namespace: actionNamespace)
try io { try CyderRequestOutbox.save(actionMessage, support: actionRoot) }
let actionGate = DispatchSemaphore(value: 0), actionLock = NSLock()
var actionReads = 0
let actionOwner = CyderInstanceCoordinator(support: actionRoot, bundleID: "action-deadline", outboxDeadline: 0.03, beforeOutboxRead: {
    actionLock.lock(); actionReads += 1; let count = actionReads; actionLock.unlock()
    if count == 2 { actionGate.wait() }
})
var actionNotices: [CyderOutboxNotice] = [], actionDispatch = 0
actionOwner.onOutboxChanged = { actionNotices = $0 }
let actionRole = result { done in actionOwner.start(onRequest: { _ in actionDispatch += 1 }, completion: done) }
check(actionRole == .primary); pump { actionNotices.count == 1 }
var actionReplies: [Bool] = []
let actionID = actionNotices[0].id
actionOwner.recoverOutbox(id: actionID, cancel: false) { actionReplies.append($0) }
pump { actionReplies.count == 1 }
check(actionReplies == [false])
for _ in 0..<60 { actionOwner.recoverOutbox(id: actionID, cancel: false) { check(!$0) } }
actionLock.lock(); let actionReadCount = actionReads; actionLock.unlock(); check(actionReadCount == 2)
let _: Bool = result { done in actionOwner.stop { done(true) } }
actionGate.signal(); tick = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tick = true }; pump { tick }
check(actionDispatch == 0 && actionReplies == [false])
let auditJournal = CyderRequestJournal(directory: actionRoot.appendingPathComponent("request-journal"))
let actionRecords = ok(result { auditJournal.open(completion: $0) }); check(actionRecords.isEmpty)
let _: Bool = result { done in auditJournal.close { done(true) } }
let retainedAction = try io { try CyderRequestOutbox.retainedRequest(id: actionMessage.requestID!, digest: actionMessage.payloadDigest!, support: actionRoot) }
check(retainedAction.requestID == actionMessage.requestID)
print("PASS recovery deadline: one physical read, no late submit after deadline/quit, original copy and empty journal preserved")

let fullRoot = root.appendingPathComponent("full")
let fullDirectory = fullRoot.appendingPathComponent("request-outbox")
try FileManager.default.createDirectory(at: fullDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
for index in 0..<512 { let f = fullDirectory.appendingPathComponent("\(index).json"); try Data("broken".utf8).write(to: f); chmod(f.path, 0o600) }
var refused = false
do { try io { try CyderRequestOutbox.save(message("overflow"), support: fullRoot) } } catch { refused = true }
check(refused)
let extra = fullDirectory.appendingPathComponent("extra.json"); try Data("broken".utf8).write(to: extra)
refused = false
do { _ = try io { try CyderRequestOutbox.reconcile(support: fullRoot, records: []) } } catch { refused = true }
check(refused, "scan did not enforce capacity")
print("PASS outbox capacity: bounded writer and scan, no silent discard")
try Data("passed".utf8).write(to: root.appendingPathComponent("outbox-completed"))
