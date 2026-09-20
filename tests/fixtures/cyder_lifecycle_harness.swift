import Foundation

typealias L = CyderLifecycle
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let a = L.EnvironmentID(uid: 501, device: 1, inode: 2, namespace: "test")
let b = L.EnvironmentID(uid: 501, device: 1, inode: 3, namespace: "test")
func environment(_ id: L.EnvironmentID, generation: UInt64 = 1) -> L.Environment {
    L.Environment(id: id, prefix: "/isolated/\(id.inode)", engine: "/trusted/engine", generation: generation)
}
func request(_ id: String, environment: L.EnvironmentID = a) -> L.Request {
    L.Request(id: id, digest: id, environment: environment, phase: .queued)
}
func launch(_ id: String, request: String, environment: L.EnvironmentID = a) -> L.Launch {
    L.Launch(id: id, request: request, environment: environment, name: id, deadline: 30)
}
var state = L.State()
state.reduce(.manage(environment(a)))
state.reduce(.manage(environment(b)))
let stamp = state.stamp(for: a)!
let other = state.stamp(for: b)!
let waiter = UUID()
state.reduce(.waiterStarted(stamp, waiter))
let effects = state.reduce(.waiterFinished(stamp, waiter, cancelled: false))
check(effects == [.reconcile(stamp)], "waiter completion must calibrate")
check(state.snapshot.environments[a]!.existence == .unconfirmed, "exit 0 does not prove exit")
check(state.reduce(.waiterFinished(stamp, waiter, cancelled: false)).isEmpty, "duplicate waiter must not churn")
state.reduce(.waiterStarted(stamp, UUID()))
state.reduce(.manage(environment(a, generation: 2)))
check(state.reduce(.waiterFinished(stamp, waiter, cancelled: true)).isEmpty, "stale waiter rejected")
let current = state.stamp(for: a)!
let cancelledWaiter = UUID()
state.reduce(.waiterStarted(current, cancelledWaiter))
state.reduce(.waiterFinished(current, cancelledWaiter, cancelled: true))
check(state.snapshot.environments[a]!.existence != .exited, "cancel is not exit")
state.reduce(.accepted(request("one")))
state.reduce(.accepted(request("two")))
state.reduce(.dispatchCommitted(request: "one", launch: launch("launch-one", request: "one")))
state.reduce(.dispatchCommitted(request: "two", launch: launch("launch-two", request: "two")))
check(state.snapshot.environments.count == 2, "two launches share one environment")
state.reduce(.cancellationCommitted(request: "one"))
check(state.snapshot.requests["one"]!.phase == .observing, "late cancellation must not claim cancelled")
state.reduce(.accepted(request("cancel-first")))
state.reduce(.cancellationCommitted(request: "cancel-first"))
state.reduce(.dispatchCommitted(request: "cancel-first", launch: launch("never", request: "cancel-first")))
check(state.snapshot.launches["never"] == nil, "cancel-first forbids dispatch")
let pid = L.ProcessID(boot: "boot", pid: 42, started: 1)
let independent = L.ProcessRecord(id: pid, name: "NGS.exe", environment: a, launch: "launch-one", ownership: nil, existence: .alive)
state.reduce(.processObserved(current, independent))
check(state.snapshot.processes[pid]!.launch == nil, "same prefix cannot prove ownership")
state.reduce(.processExited(current, pid))
state.reduce(.processObserved(current, independent))
check(state.snapshot.processes[pid]!.existence == .exited, "late scan cannot resurrect PID")
let reused = L.ProcessID(boot: "boot", pid: 42, started: 2)
state.reduce(.processObserved(current, L.ProcessRecord(id: reused, name: "next", environment: a, existence: .alive)))
check(state.snapshot.processes[reused]!.existence == .alive, "PID reuse is a distinct instance")
check(state.reduce(.deadline(29)).isEmpty, "deadline is monotonic and fixed")
check(state.reduce(.deadline(30)).count == 2, "both observation slots release")
check(state.reduce(.deadline(300)).isEmpty, "completion is once only")
let calibration = UUID()
state.reduce(.reconcileStarted(current, calibration))
state.reduce(.reconciled(current, calibration, .alive, .healthy))
check(state.snapshot.keepStatusItem, "windowless background environment retained")
state.reduce(.visibleUI(true))
let stopToken = UUID()
check(state.reduce(.stopRequested(current, stopToken)) == [.stop(current, stopToken)], "stop needs explicit intent")
check(state.reduce(.stopRequested(current, UUID())).isEmpty, "duplicate stop coalesces")
check(state.snapshot.environments[b]!.stop == .idle, "stop scoped to bottle")
state.reduce(.stopFinished(current, stopToken, success: true))
check(state.snapshot.visibleUI, "stop never hides UI")
state.reduce(.accepted(request("queued-at-quit")))
let quitEffects = state.reduce(.quit)
check(quitEffects == [.persistQuiescing, .cancelOwnedObservers], "quit must produce zero stop effects")
check(state.snapshot.requests["queued-at-quit"]!.phase == .awaitingUserResume, "accepted queued request preserved")
check(!state.snapshot.keepStatusItem, "explicit quit overrides unknown environments")
check(state.reduce(.quit).isEmpty, "quit transaction coalesces")
state.reduce(.accepted(request("late-commit")))
check(state.snapshot.requests["late-commit"]!.phase == .awaitingUserResume, "late acceptance never dispatches")
check(state.reduce(.stopRequested(other, UUID())).isEmpty, "quiescing freezes effects")
var history = L.State()
var old = request("old")
old.phase = .uncertain
history.reduce(.accepted(old))
check(history.snapshot.canAutoTerminate, "historical requests do not keep app alive")
// Fixed deterministic permutations of cancel, dispatch, and quit exercise the real reducer.
for sequence in [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]] {
    var s = L.State()
    s.reduce(.manage(environment(a)))
    s.reduce(.accepted(request("race")))
    for event in sequence {
        switch event {
        case 0: s.reduce(.cancellationCommitted(request: "race"))
        case 1: s.reduce(.dispatchCommitted(request: "race", launch: launch("race-launch", request: "race")))
        default:
            check(s.reduce(.quit).allSatisfy { if case .stop = $0 { return false }; return true }, "quit never kills")
        }
    }
    check(!(s.snapshot.requests["race"]!.phase == .cancelled && s.snapshot.launches["race-launch"] != nil), "no false cancelled launch")
}
print("PASS lifecycle reducer: V04/V08/V09/V10; PID reuse, stale scans, bounded observation, background retention")
