import Foundation
import Darwin
func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    guard condition() else { fputs("FAIL preflight deadline\n", stderr); exit(1) }
}
final class Counter {
    let lock = NSLock(); var count = 0
    func enter() { precondition(!Thread.isMainThread); lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let preparer = CyderLaunchPreparation<Int>()
var expired = false
preparer.resolve(deadline: 0, work: { fatalError("already expired read started") }) { outcome in
    guard case .unconfirmed = outcome else { fatalError() }; expired = true
}
pump { expired }
let stalled = DispatchSemaphore(value: 0), count = Counter()
var order: [Int] = []
preparer.resolve(deadline: 0.1, work: { count.enter(); stalled.wait(); return 0 }) { outcome in
    guard case .unconfirmed = outcome else { fatalError("stalled job must time out") }; order.append(0)
}
preparer.resolve(work: { count.enter(); return 1 }) { outcome in
    guard case .resolved(1) = outcome else { fatalError() }; order.append(1)
}
preparer.resolve(work: { count.enter(); return 2 }) { outcome in
    guard case .resolved(2) = outcome else { fatalError() }; order.append(2)
}
pump { order.count == 3 }
precondition(order == [0, 1, 2], "completion order changed or one bottle blocked others indefinitely")
stalled.signal()

let blocked = CyderLaunchPreparation<Int>(), gate = DispatchSemaphore(value: 0), starts = Counter()
var replies = 0
for i in 0..<2 {
    blocked.resolve(deadline: 0.1, work: { starts.enter(); gate.wait(); return i }) { outcome in
        guard case .unconfirmed = outcome else { fatalError() }; replies += 1
    }
}
pump { starts.value() == 2 }
var cancelled = false
let id = blocked.resolve(work: { fatalError("cancelled queued read started") }) { outcome in
    guard case .cancelled = outcome else { fatalError() }; cancelled = true
}
blocked.cancel(id)
for _ in 0..<20 {
    blocked.resolve(deadline: 0.15, work: { fatalError("timeout freed a physical slot") }) { outcome in
        guard case .unconfirmed = outcome else { fatalError() }; replies += 1
    }
}
pump { replies == 22 && cancelled }
precondition(starts.value() == 2)
gate.signal(); gate.signal()
var tick = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick = true }
pump { tick }
precondition(replies == 22 && order.count == 3, "late worker completion escaped its old observation")
blocked.quiesce()
var quit = false
blocked.resolve(work: { fatalError("quiesced read started") }) { outcome in
    guard case .cancelled = outcome else { fatalError() }; quit = true
}
pump { quit }

let journal = CyderRequestJournal(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T { var value: T?; body { value = $0 }; pump { value != nil }; return value! }
func ok<T>(_ result: Result<T, CyderRequestJournal.Failure>) -> T { guard case .success(let value) = result else { fatalError("\(result)") }; return value }
_ = ok(wait { journal.open(completion: $0) })
let ns: UUID = wait { done in journal.namespace { done($0!) } }
let request = CyderRequestJournal.makeID(namespace: ns)
let payload = CyderRequestPayload(files: ["/trusted/read-only.exe"], arguments: nil, urls: [], showUI: false)
_ = ok(wait { journal.submit(id: request, payload: payload, completion: $0) })
let paused = ok(wait { journal.deferDispatch(id: request, outcome: "scope-unavailable", completion: $0) })
precondition(paused.phase == .awaitingUserResume && paused.payload == payload && paused.launchID == nil)
precondition(wait { journal.authorizeDispatch(id: request, completion: $0) } == .failure(.tooLate))
let resumed = ok(wait { journal.resume(id: request, completion: $0) })
precondition(resumed.outcome == nil && resumed.phase == .queued)
_ = ok(wait { journal.authorizeDispatch(id: request, completion: $0) })
precondition(wait { journal.deferDispatch(id: request, outcome: "late-read", completion: $0) } == .failure(.tooLate), "late preparation rewound a dispatched request")
let _: Bool = wait { done in journal.close { done(true) } }
print("PASS formal bounded preflight/journal: fixed deadline, ordered independent progress, retained stuck slots, queued cancel, no late replay, quit, durable pause/resume, dispatch fence")
