import Cocoa
import Foundation
import Darwin
enum CyderPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
func check(_ value: @autoclosure () -> Bool, _ message: String = "assertion failed", line: UInt = #line) {
    guard value() else { fputs("FAIL outbox line \(line): \(message)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "callback deadline")
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
coordinator.onRecoveryChanged = { records = $0; controller.update(records, outbox: notices) }
coordinator.onOutboxChanged = { notices = $0; callbacks += 1; controller.update(records, outbox: notices) }
let role = result { done in coordinator.start(onRequest: { _ in dispatched += 1 }, completion: done) }
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
