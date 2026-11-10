import Foundation
import Darwin

// In-memory request registry: idempotent acceptance, dispatch fence, bounded
// retention (P0-1: it can never fill up permanently), accepted-settings capture.
typealias R = CyderRequestRegistry
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let delivery = DispatchQueue(label: "test.registry-delivery")
func wait<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    let done = DispatchSemaphore(value: 0)
    work { result = $0; done.signal() }
    precondition(done.wait(timeout: .now() + 10) == .success, "registry callback never arrived")
    return result!
}
func value(_ result: Result<R.Record, R.Failure>, line: Int = #line) -> R.Record {
    guard case .success(let record) = result else { fatalError("line \(line): \(result)") }
    return record
}
func failure(_ result: Result<R.Record, R.Failure>, line: Int = #line) -> R.Failure {
    guard case .failure(let failure) = result else { fatalError("line \(line): expected failure, got \(result)") }
    return failure
}
let settingsURL = root.appendingPathComponent("settings.json")
try Data("{\"schemaVersion\":14}".utf8).write(to: settingsURL)
let capture = { try CyderAcceptedSettings.capture(at: settingsURL) }
let registry = R(capacity: 8, delivery: delivery, captureSettings: capture)
let payload = CyderRequestPayload(files: ["/Games/a.exe"], arguments: ["--x"], urls: [], showUI: false)

// Acceptance is idempotent per ID; a different payload under the same ID is refused.
let id = R.makeID(namespace: registry.namespace)
let accepted = value(wait { registry.submit(id: id, payload: payload, completion: $0) })
precondition(accepted.phase == .queued && accepted.settingsSnapshot == Data("{\"schemaVersion\":14}".utf8))
precondition(value(wait { registry.submit(id: id, payload: payload, completion: $0) }) == accepted, "retry must be idempotent")
let other = CyderRequestPayload(files: ["/Games/b.exe"], arguments: nil, urls: [], showUI: false)
precondition(failure(wait { registry.submit(id: id, payload: other, completion: $0) }) == .conflictingPayload)
precondition(failure(wait { registry.submit(id: R.makeID(namespace: UUID()), payload: payload, completion: $0) }) == .invalid,
             "IDs from another primary process are not accepted")

// Dispatch is fenced exactly once and completion needs the same launch/epoch.
let dispatched = value(wait { registry.authorizeDispatch(id: id, completion: $0) })
precondition(dispatched.phase == .dispatching && dispatched.executorEpoch == registry.executorEpoch && dispatched.launchID != nil)
precondition(failure(wait { registry.authorizeDispatch(id: id, completion: $0) }) == .tooLate)
precondition(failure(wait { registry.complete(id: id, launchID: UUID().uuidString, epoch: registry.executorEpoch, outcome: "x", failed: false, completion: $0) }) == .wrongExecutor)
let done = value(wait { registry.complete(id: id, launchID: dispatched.launchID!, epoch: registry.executorEpoch, outcome: "ok", failed: false, completion: $0) })
precondition(done.phase == .completed && done.payload == nil && done.settingsSnapshot == nil)

// A queued request that cannot be dispatched is withdrawn, not parked.
let withdrawn = R.makeID(namespace: registry.namespace)
_ = value(wait { registry.submit(id: withdrawn, payload: other, completion: $0) })
precondition(value(wait { registry.fail(id: withdrawn, outcome: "scope-unavailable", completion: $0) }).phase == .failed)
precondition(failure(wait { registry.authorizeDispatch(id: withdrawn, completion: $0) }) == .tooLate)

// Batches split into deterministic children; a retried batch is the same batch.
let batch = CyderRequestPayload(files: ["/Games/1.exe", "/Games/2.exe"], arguments: nil, urls: ["cyder://x"], showUI: false)
let batchID = R.makeID(namespace: registry.namespace)
let parent = value(wait { registry.submit(id: batchID, payload: batch, completion: $0) })
precondition(parent.children?.count == 3 && parent.phase == .completed)
precondition(value(wait { registry.submit(id: batchID, payload: batch, completion: $0) }).children == parent.children)
for child in parent.children! { precondition(value(wait { registry.query(id: child, completion: $0) }).phase == .queued) }

// P0-1: thousands of launches never exhaust the registry. Terminal records are
// evicted oldest-first; active ones (the 3 queued children) are never evicted.
for index in 0..<2000 {
    let launch = R.makeID(namespace: registry.namespace)
    let file = CyderRequestPayload(files: ["/Games/\(index).exe"], arguments: nil, urls: [], showUI: false)
    _ = value(wait { registry.submit(id: launch, payload: file, completion: $0) })
    let fenced = value(wait { registry.authorizeDispatch(id: launch, completion: $0) })
    _ = value(wait { registry.complete(id: launch, launchID: fenced.launchID!, epoch: registry.executorEpoch, outcome: "ok", failed: index % 3 == 0, completion: $0) })
}
precondition(registry.count <= 8, "registry grew past its bound: \(registry.count)")
for child in parent.children! { precondition(value(wait { registry.query(id: child, completion: $0) }).phase == .queued, "active work evicted") }
// Only a table full of active work refuses, and only while it is active.
let small = R(capacity: 2, delivery: delivery)
let a = value(wait { small.submit(id: R.makeID(namespace: small.namespace), payload: payload, completion: $0) })
_ = value(wait { small.submit(id: R.makeID(namespace: small.namespace), payload: other, completion: $0) })
precondition(failure(wait { small.submit(id: R.makeID(namespace: small.namespace), payload: payload, completion: $0) }) == .full)
_ = value(wait { small.fail(id: a.id, outcome: "x", completion: $0) })
_ = value(wait { small.submit(id: R.makeID(namespace: small.namespace), payload: payload, completion: $0) })

// Closing refuses new work; nothing is written to disk at any point.
_ = wait { done in registry.close { done(true) } }
precondition(failure(wait { registry.submit(id: R.makeID(namespace: registry.namespace), payload: payload, completion: $0) }) == .closing)
let persisted = try FileManager.default.contentsOfDirectory(atPath: root.path)
precondition(persisted == ["settings.json"], "registry must not persist")

// Fingerprint: fixed byte layout (reproduced independently in Python); the
// rc.1 JSON fingerprint still matches for mixed-version peers.
let vector = CyderRequestPayload(files: ["/Games/Maple Story/MapleStory.exe"], arguments: ["a\nb", "日本語", "/x"],
                                 urls: [], showUI: false, settings: Data("{\"schemaVersion\":14}".utf8))
precondition(vector.digest == "8e99eb11b865937fb7575f3145369e7c050b80d42193ab12dee314bd51f927c1", "fingerprint layout changed")
precondition(vector.digest != vector.legacyDigest && vector.matches(vector.legacyDigest) && !vector.matches(nil))
precondition(CyderRequestPayload(files: ["/a.exe"], arguments: nil, urls: [], showUI: false).digest
             != CyderRequestPayload(files: ["/a.exe"], arguments: [], urls: [], showUI: false).digest)

// Accepted settings: structural validation only (schema meaning is CyderSettings').
for schema in [1, 14, 15, 99] { precondition(CyderAcceptedSettings.isValid(Data("{\"schemaVersion\":\(schema)}".utf8))) }
for bad in ["[]", "{\"schemaVersion\":0}", "{\"schemaVersion\":-1}", "{\"schemaVersion\":true}", "{\"schemaVersion\":1.5}"] {
    precondition(!CyderAcceptedSettings.isValid(Data(bad.utf8)))
}
// Saves are atomic renames; concurrent saves must never reject a capture.
do {
    var stop = false
    let lock = NSLock(), writerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var index = 0
        while true {
            lock.lock(); let finished = stop; lock.unlock()
            if finished { break }
            index += 1
            try? Data("{\"schemaVersion\":14,\"dpi\":\(96 + index % 50)}".utf8).write(to: settingsURL, options: .atomic)
        }
        writerDone.signal()
    }
    for _ in 0..<400 { _ = try capture() }
    lock.lock(); stop = true; lock.unlock()
    writerDone.wait()
}
try Data("{\"schemaVersion\":".utf8).write(to: settingsURL)
do { _ = try capture(); fatalError("partial JSON accepted") } catch let error as R.Failure { precondition(error == .invalid) }
try FileManager.default.removeItem(at: settingsURL)
let missing = try capture()
precondition(missing == Data("{}".utf8), "missing settings mean defaults")
precondition(mkfifo(settingsURL.path, 0o600) == 0)
do { _ = try capture(); fatalError("FIFO must not block or become defaults") } catch {}
try FileManager.default.removeItem(at: settingsURL)
try FileManager.default.createSymbolicLink(atPath: settingsURL.path, withDestinationPath: "/etc/hosts")
do { _ = try capture(); fatalError("symlinked settings must be refused") } catch {}
print("PASS request registry: idempotent acceptance, single dispatch fence, withdrawal, deterministic batches, bounded retention over 2000 launches, no persistence, fixed fingerprint, race-free settings capture")
