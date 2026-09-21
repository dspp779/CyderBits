import Foundation

typealias L = CyderLifecycle
var failures: [String] = []
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
let a = L.EnvironmentID(uid: 501, device: 1, inode: 2, namespace: "test")
let b = L.EnvironmentID(uid: 501, device: 1, inode: 3, namespace: "test")
let process = L.ProcessID(boot: "boot", pid: 42, started: 1)
let window = L.Window(id: .init(process: process, source: "fixture", token: "1"), title: "Fixture", capability: .available)
func environment(_ id: L.EnvironmentID, _ generation: UInt64 = 1) -> L.Environment {
    .init(id: id, prefix: "/isolated/\(id.inode)", engine: "/fixture/engine", generation: generation)
}
func fresh() -> L.State {
    var state = L.State()
    state.reduce(.manage(environment(a))); state.reduce(.manage(environment(b)))
    return state
}
func dispatch(_ state: inout L.State, _ name: String = "launch") {
    state.reduce(.accepted(.init(id: name, digest: name, environment: a, phase: .queued)))
    state.reduce(.dispatchCommitted(state.stamp(for: a)!, request: name, launch: .init(id: name, request: name, environment: a, name: name, deadline: 30)))
}
func observe(_ state: inout L.State, launch: String? = nil) {
    state.reduce(.processObserved(state.stamp(for: a)!, .init(id: process, name: "Fixture", environment: a,
        launch: launch, ownership: launch == nil ? nil : .rootReceipt, existence: .alive)))
    state.reduce(.windowObserved(state.stamp(for: a)!, window))
}
func reconcile(_ state: inout L.State, existence: L.Existence) {
    let token = UUID(), stamp = state.stamp(for: a)!
    state.reduce(.reconcileStarted(stamp, token))
    state.reduce(.reconciled(stamp, token, existence, .healthy))
}

var drained = fresh(); dispatch(&drained); observe(&drained, launch: "launch")
reconcile(&drained, existence: .exited)
check(drained.snapshot.environments[a]?.existence == .exited, "observing request cannot discard confirmed environment drain")
check(drained.snapshot.processes[process]?.existence == .exited && drained.snapshot.windows.isEmpty, "drain revokes process and window capabilities")
check(drained.snapshot.hasActiveWork, "environment drain alone does not invent a launch outcome")
drained.reduce(.observationFinished(drained.stamp(for: a)!, launch: "launch", outcome: .finishedWithoutWindow))
check(drained.snapshot.requests["launch"]?.phase == .completed, "matching root/drain outcome may finish after environment exit")
reconcile(&drained, existence: .alive)
check(drained.snapshot.environments[a]?.existence == .exited, "same generation cannot revive after authoritative drain")
// New pending work is separate from the already drained server generation.
var queued = fresh()
queued.reduce(.accepted(.init(id: "queued", digest: "queued", environment: a, phase: .queued)))
reconcile(&queued, existence: .exited)
check(queued.snapshot.environments[a]?.existence == .exited && queued.snapshot.keepStatusItem, "queued work retains UI without keeping an old server alive")

var crossed = fresh(); observe(&crossed)
crossed.reduce(.processExited(crossed.stamp(for: b)!, process))
check(crossed.snapshot.processes[process]?.existence == .alive && crossed.snapshot.windows[window.id] != nil, "other environment cannot exit this process")
var closed = fresh(); observe(&closed)
closed.reduce(.windowClosed(closed.stamp(for: b)!, window.id))
check(closed.snapshot.windows[window.id] != nil, "other environment cannot close this window")
var moved = fresh(); observe(&moved)
moved.reduce(.processObserved(moved.stamp(for: b)!, .init(id: process, name: "Wrong", environment: b, existence: .alive)))
check(moved.snapshot.processes[process]?.environment == a, "observation cannot move a known process into another environment")

var replaced = fresh(); dispatch(&replaced); observe(&replaced, launch: "launch")
let oldStamp = replaced.stamp(for: a)!
let replacementEffects = replaced.reduce(.manage(environment(a, 2)))
check(replacementEffects == [.observationCompleted("launch", .unconfirmed)], "generation replacement releases old observation exactly once")
check(replaced.snapshot.requests["launch"]?.phase == .uncertain, "uncertain result is not completed success")
check(replaced.snapshot.launches["launch"]?.processes.isEmpty == true, "new generation clears old launch process membership")
replaced.reduce(.processObserved(replaced.stamp(for: a)!, .init(id: .init(boot: "boot", pid: 43, started: 2), name: "New",
    environment: a, launch: "launch", ownership: .processTree, existence: .alive)))
check(replaced.snapshot.processes.values.allSatisfy { $0.launch == nil }, "new generation process cannot inherit old launch ownership")
check(replaced.reduce(.processExited(oldStamp, process)).isEmpty, "old generation exit ignored")
check(replaced.reduce(.deadline(30)).isEmpty, "replacement and deadline cannot complete twice")
var timed = fresh(); dispatch(&timed)
timed.reduce(.deadline(30))
check(timed.snapshot.requests["launch"]?.phase == .uncertain, "deadline result retains uncertainty")

var staleDispatch = fresh()
let dispatchStamp = staleDispatch.stamp(for: a)!
staleDispatch.reduce(.accepted(.init(id: "pending", digest: "pending", environment: a, phase: .queued)))
staleDispatch.reduce(.manage(environment(a, 2)))
staleDispatch.reduce(.dispatchCommitted(dispatchStamp, request: "pending", launch: .init(id: "pending", request: "pending", environment: a, name: "Pending", deadline: 30)))
check(staleDispatch.snapshot.launches.isEmpty, "late dispatch cannot target replacement generation")
var outcomes = fresh(); dispatch(&outcomes)
let outcomeStamp = outcomes.stamp(for: a)!
check(outcomes.reduce(.observationFinished(outcomes.stamp(for: b)!, launch: "launch", outcome: .confirmedStarted)).isEmpty, "other environment cannot finish launch")
check(outcomes.reduce(.observationFinished(.init(epoch: UUID(), environment: a, generation: 1), launch: "launch", outcome: .confirmedStarted)).isEmpty, "old app epoch cannot finish launch")
check(outcomes.reduce(.observationFinished(outcomeStamp, launch: "launch", outcome: .cancelled)).isEmpty, "after dispatch observation cancellation cannot claim not started")
check(outcomes.reduce(.observationFinished(outcomeStamp, launch: "launch", outcome: .confirmedStarted)) == [.observationCompleted("launch", .confirmedStarted)], "matching completion delivered once")
check(outcomes.reduce(.observationFinished(outcomeStamp, launch: "launch", outcome: .failed)).isEmpty, "duplicate completion cannot replace result")
var earlyExit = fresh()
earlyExit.reduce(.processExited(earlyExit.stamp(for: b)!, process))
observe(&earlyExit)
check(earlyExit.snapshot.processes[process]?.existence == .alive, "unmatched exit cannot poison another environment birth")
var scannedExit = fresh(); observe(&scannedExit)
scannedExit.reduce(.processObserved(scannedExit.stamp(for: a)!, .init(id: process, name: "Fixture", environment: a, existence: .exited)))
observe(&scannedExit)
check(scannedExit.snapshot.processes[process]?.existence == .exited && scannedExit.snapshot.windows.isEmpty, "exit snapshot also revokes windows and prevents resurrection")

var attached = fresh()
let attachedStamp = attached.stamp(for: a)!
let committed = L.Request(id: "committed", digest: "digest", environment: a, phase: .dispatching, launch: "committed")
let committedLaunch = L.Launch(id: "committed", request: "committed", environment: a, name: "Committed", deadline: .infinity)
check(attached.reduce(.executionAttached(attachedStamp, committed, committedLaunch)).isEmpty, "attaching an executor must not dispatch or emit effects")
check(attached.snapshot.requests["committed"]?.phase == .observing && attached.snapshot.launches.count == 1, "actual committed work enters model atomically")
attached.reduce(.processObserved(attachedStamp, .init(id: process, name: "Fixture", environment: a,
    launch: "committed", ownership: .rootReceipt, existence: .alive)))
check(attached.reduce(.windowObserved(attachedStamp, window)) == [.windowConfirmed("committed")], "window activation is issued only by the accepting store")
check(attached.reduce(.windowObserved(attached.stamp(for: b)!, window)).isEmpty, "wrong-scope window cannot signal an observation")
attached.reduce(.executionAttached(attachedStamp, committed, committedLaunch))
check(attached.snapshot.launches.count == 1, "duplicate attachment cannot create another launch")
attached.reduce(.observationStarted(attachedStamp, launch: "committed", deadline: 20))
attached.reduce(.observationStarted(attachedStamp, launch: "committed", deadline: 200))
check(attached.snapshot.launches["committed"]?.deadline == 20, "observer publishes its deadline once without resetting on later callbacks")
check(attached.reduce(.deadline(20)) == [.observationCompleted("committed", .unconfirmed)], "attached launch has the same bounded observation policy")
var historical = fresh()
let uncertain = L.Request(id: "committed", digest: "digest", environment: a, phase: .uncertain, launch: "committed")
historical.reduce(.executionAttached(historical.stamp(for: a)!, uncertain, committedLaunch))
check(historical.snapshot.requests.isEmpty && historical.snapshot.launches.isEmpty, "historical uncertain record cannot manufacture a live executor")

let delivered = DispatchSemaphore(value: 0), batchEpoch = UUID()
var batchSnapshot: L.Snapshot?, batchEffects: [L.Effect] = []
let batchStore = CyderLifecycleStore(epoch: batchEpoch, delivery: DispatchQueue(label: "fixture.delivery")) {
    batchSnapshot = $0; batchEffects = $1; delivered.signal()
}
let batchStamp = L.Stamp(epoch: batchEpoch, environment: a, generation: 1)
let processes: [L.Event] = (1...1024).map {
    .processObserved(batchStamp, .init(id: .init(boot: "fixture", pid: Int32($0), started: UInt64($0)),
        name: "Fixture", environment: a, existence: .alive))
}
batchStore.send([.manage(environment(a))] + processes + [.quit])
check(delivered.wait(timeout: .now() + 5) == .success, "large evidence batch delivered")
check(batchSnapshot?.processes.count == 1024 && batchSnapshot?.phase == .quiescing, "batch preserves all events before delivery")
check(batchEffects == [.persistQuiescing, .cancelOwnedObservers], "batch retains quit effects without stop")
check(delivered.wait(timeout: .now()) == .timedOut, "one physical batch yields one snapshot")

// Window snapshots are atomic across source/process identity validation.
var actionState = fresh(); observe(&actionState)
let actionStamp = actionState.stamp(for: a)!, operation = UUID()
let invalidWindow = L.Window(id: .init(process: process, source: "wrong-source", token: "other"), title: "Same", capability: .available)
let beforeInvalid = actionState.snapshot.revision
_ = actionState.reduce(.windowSnapshot(actionStamp, process, source: "fixture", windows: [invalidWindow], capability: .permissionRequired))
check(actionState.snapshot.revision == beforeInvalid && actionState.snapshot.processes[process]?.windowCapability == nil,
      "invalid snapshot cannot partly mutate capability")
_ = actionState.reduce(.windowSnapshot(actionStamp, process, source: "fixture", windows: [window, window], capability: .available))
check(actionState.snapshot.revision == beforeInvalid, "duplicate window identities reject the entire snapshot")
check(actionState.reduce(.activateWindow(window.id, operation)) == [.activateWindow(actionStamp, window.id, operation)], "exact valid target emits one effect")
check(actionState.reduce(.activateWindow(window.id, UUID())).isEmpty, "same pending target coalesces")
actionState.reduce(.windowClosed(actionStamp, window.id))
actionState.reduce(.windowActionFinished(operation, .shown))
check(actionState.snapshot.windowAction?.result == .windowGone, "late success cannot override closed-window revocation")
actionState.reduce(.dismissWindowFeedback(UUID()))
check(actionState.snapshot.windowAction != nil, "unrelated presentation cannot dismiss feedback")
actionState.reduce(.dismissWindowFeedback(operation))
check(actionState.snapshot.windowAction == nil, "exact presented failure can be dismissed")
observe(&actionState)
let nextOperation = UUID()
actionState.reduce(.activateWindow(window.id, nextOperation))
actionState.reduce(.manage(environment(a, 2)))
actionState.reduce(.windowActionFinished(nextOperation, .shown))
check(actionState.snapshot.windowAction?.result == .windowGone, "higher generation revokes pending target before late completion")
actionState.reduce(.quit)
check(actionState.snapshot.windowAction == nil, "explicit quit clears pending window feedback without stopping an environment")

if !failures.isEmpty { failures.forEach { print("FAIL \($0)") }; exit(1) }
print("PASS lifecycle environment isolation, generation replacement, drain and uncertain outcomes")
