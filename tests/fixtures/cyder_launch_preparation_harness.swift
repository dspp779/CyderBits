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

let registry = CyderRequestRegistry()
func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T { var value: T?; body { value = $0 }; pump { value != nil }; return value! }
func ok<T>(_ result: Result<T, CyderRequestRegistry.Failure>) -> T { guard case .success(let value) = result else { fatalError("\(result)") }; return value }
let payload = CyderRequestPayload(files: ["/trusted/read-only.exe"], arguments: nil, urls: [], showUI: false)
// A request whose environment cannot be resolved is withdrawn, never parked
// for a later resume, and can no longer be dispatched.
let request = CyderRequestRegistry.makeID(namespace: registry.namespace)
_ = ok(wait { registry.submit(id: request, payload: payload, completion: $0) })
let withdrawn = ok(wait { registry.fail(id: request, outcome: "scope-unavailable", completion: $0) })
precondition(withdrawn.phase == .failed && withdrawn.payload == nil && withdrawn.launchID == nil)
precondition(wait { registry.authorizeDispatch(id: request, completion: $0) } == .failure(.tooLate))
// A late preparation result cannot withdraw a request that was dispatched.
let dispatchedRequest = CyderRequestRegistry.makeID(namespace: registry.namespace)
_ = ok(wait { registry.submit(id: dispatchedRequest, payload: payload, completion: $0) })
_ = ok(wait { registry.authorizeDispatch(id: dispatchedRequest, completion: $0) })
precondition(wait { registry.fail(id: dispatchedRequest, outcome: "late-read", completion: $0) } == .failure(.tooLate), "late preparation rewound a dispatched request")
let _: Bool = wait { done in registry.close { done(true) } }
print("PASS formal bounded preflight/registry: fixed deadline, ordered independent progress, retained stuck slots, queued cancel, no late replay, quit, withdrawal without parking, dispatch fence")
