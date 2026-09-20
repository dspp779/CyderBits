import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let path = root.appendingPathComponent("request.sock").path
let server = CyderRequestChannel(path: path)
let delivery = DispatchQueue(label: "test.channel-results")
let journal = CyderRequestJournal(directory: root.appendingPathComponent("journal"), delivery: delivery)
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
    let open = wait { journal.open(completion: $0) }
    guard case .success = open else { fatalError("journal open \(open)") }
    let namespace = wait { journal.namespace(completion: $0) }!
    precondition(server.start { message, reply in
        func respond(_ status: String, _ record: CyderRequestJournal.Record? = nil) {
            reply(.init(protocolVersion: 1, requestID: message.requestID, primaryEpoch: journal.executorEpoch,
                        namespace: namespace, status: status, record: record))
        }
        guard message.kind != "stall" else { return }
        guard let id = message.requestID else { respond("hello"); return }
        if message.kind == "submit", let payload = message.payload {
            journal.submit(id: id, payload: payload) { result in
                switch result {
                case .success(let record): respond("accepted", record)
                case .failure: respond("rejected")
                }
            }
        } else {
            journal.query(id: id) { result in
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
    let id = CyderRequestJournal.makeID(namespace: namespace)
    let payload = CyderRequestPayload(files: ["/trusted/test.exe"], arguments: ["a\nb", "日本語"], urls: [], showUI: false)
    let submit = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id, payloadDigest: payload.digest, senderEpoch: sender, payload: payload)
    journal.inject(.afterCommit)
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
    let oversized = CyderRequestPayload(files: ["/" + String(repeating: "x", count: CyderRequestChannel.maxFrame)], arguments: nil, urls: [], showUI: false)
    let huge = CyderRequestMessage(protocolVersion: 1, kind: "submit", requestID: id, payloadDigest: nil, senderEpoch: sender, payload: oversized)
    precondition(CyderRequestChannel.exchange(path: path, message: huge) == nil, "oversized frame accepted")
    let _: Bool = wait { done in server.stop { done(true) } }
    let _: Bool = wait { done in journal.close { done(true) } }
    precondition(!FileManager.default.fileExists(atPath: path), "channel leaked socket")
    finished.signal()
}
precondition(finished.wait(timeout: .now() + 20) == .success)
print("PASS socket+journal: actual framing, lost ACK retry, side-effect-free query, version/capacity/deadline, FD cleanup")
