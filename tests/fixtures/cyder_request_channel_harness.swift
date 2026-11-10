import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let path = root.appendingPathComponent("request.sock").path
let server = CyderRequestChannel(path: path)
let delivery = DispatchQueue(label: "test.channel-results")
let registry = CyderRequestRegistry(delivery: delivery)
var dropNextReply = false // simulates a lost ACK after acceptance
let finished = DispatchSemaphore(value: 0)
let work = DispatchQueue(label: "test.channel-client")
func wait<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    let done = DispatchSemaphore(value: 0)
    work { result = $0; done.signal() }
    precondition(done.wait(timeout: .now() + 10) == .success)
    return result!
}
work.async {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let namespace = registry.namespace
    precondition(server.start { message, reply in
        func respond(_ status: String, _ record: CyderRequestRegistry.Record? = nil) {
            reply(.init(protocolVersion: 1, requestID: message.requestID, primaryEpoch: registry.executorEpoch,
                        namespace: namespace, status: status, record: record))
        }
        guard message.kind != "stall" else { return }
        if message.kind == "slow" {
            // A durable handler slower than one SO_RCVTIMEO slice (1 s).
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { respond("slow-done") }
            return
        }
        guard let id = message.requestID else { respond("hello"); return }
        if message.kind == "submit", let payload = message.payload {
            registry.submit(id: id, payload: payload) { result in
                if dropNextReply { dropNextReply = false; return }
                switch result {
                case .success(let record): respond("accepted", record)
                case .failure: respond("rejected")
                }
            }
        } else {
            registry.query(id: id) { result in
                switch result {
                case .success(let record): respond("existingStatus", record)
                case .failure: respond("rejected")
                }
            }
        }
    })
    let sender = UUID()
    let hello = CyderRequestMessage(protocolVersion: 1, kind: "hello", requestID: nil, payloadDigest: nil, senderEpoch: sender, payload: nil)
    precondition(CyderRequestChannel.exchange(path: path, message: hello)?.namespace == namespace)
    let id = CyderRequestRegistry.makeID(namespace: namespace)
    let payload = CyderRequestPayload(files: ["/trusted/test.exe"], arguments: ["a\nb", "日本語"], urls: [], showUI: false)
    let submit = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id, payloadDigest: payload.digest, senderEpoch: sender, payload: payload)
    dropNextReply = true
    precondition(CyderRequestChannel.exchange(path: path, message: submit, timeout: 0.1) == nil)
    let retry = CyderRequestChannel.exchange(path: path, message: submit)!
    precondition(retry.status == "accepted" && retry.record?.payload == payload, "actual socket retry corrupted payload")
    let query = CyderRequestMessage(protocolVersion: 1, kind: "query", requestID: id, payloadDigest: payload.digest, senderEpoch: sender, payload: nil)
    let status = CyderRequestChannel.exchange(path: path, message: query)!
    precondition(status.record == retry.record, "status query has side effects")
    let invalid = CyderRequestMessage(protocolVersion: 999, kind: "query", requestID: id, payloadDigest: nil, senderEpoch: sender, payload: nil)
    precondition(CyderRequestChannel.exchange(path: path, message: invalid) == nil, "invalid version accepted")
    let start = ProcessInfo.processInfo.systemUptime
    let stall = CyderRequestMessage(protocolVersion: 1, kind: "stall", requestID: nil, payloadDigest: nil, senderEpoch: sender, payload: nil)
    precondition(CyderRequestChannel.exchange(path: path, message: stall, timeout: 0.15) == nil)
    precondition(ProcessInfo.processInfo.systemUptime - start < 1, "stalled peer exceeded budget")
    // Problem 6: a reply that takes longer than 1 s (a slow handler) is
    // still delivered within the caller's budget instead of timing out early.
    let slow = CyderRequestMessage(protocolVersion: 1, kind: "slow", requestID: nil, payloadDigest: nil, senderEpoch: sender, payload: nil)
    precondition(CyderRequestChannel.exchange(path: path, message: slow, timeout: 4)?.status == "slow-done", "slow durable reply was dropped")
    precondition(CyderRequestChannel.frameDeadline < CyderRequestChannel.replyDeadline)
    let oversized = CyderRequestPayload(files: ["/" + String(repeating: "x", count: CyderRequestChannel.maxFrame)], arguments: nil, urls: [], showUI: false)
    let huge = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id, payloadDigest: nil, senderEpoch: sender, payload: oversized)
    precondition(CyderRequestChannel.exchange(path: path, message: huge) == nil, "oversized frame accepted")
    let _: Bool = wait { done in server.stop { done(true) } }
    let _: Bool = wait { done in registry.close { done(true) } }
    precondition(!FileManager.default.fileExists(atPath: path), "channel leaked socket")
    finished.signal()
}
precondition(finished.wait(timeout: .now() + 20) == .success)
print("PASS socket+registry: actual framing, lost ACK retry, side-effect-free query, version/capacity/deadline, FD cleanup")
