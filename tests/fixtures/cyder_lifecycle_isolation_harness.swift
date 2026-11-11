import Foundation

typealias L = CyderLifecycle
var failures: [String] = []
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
let a = L.EnvironmentID(uid: 501, device: 1, inode: 2, namespace: "test")
let b = L.EnvironmentID(uid: 501, device: 1, inode: 3, namespace: "test")
let process = L.ProcessID(boot: "boot", pid: 42, started: 1)
let window = L.Window(id: .init(process: process, source: "fixture", token: "1"), title: "Fixture", capability: .available, minimized: false, isProgramWindow: true)
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
let splash = L.Window(id: .init(process: process, source: "coregraphics", token: "23"), title: "Splash", capability: .unsupported)
check(attached.reduce(.windowObserved(attachedStamp, splash)) == [.windowPresented("committed")],
      "an attributed splash may clear an overlay but cannot complete launch or authorize focus")
let modal = L.Window(id: .init(process: process, source: "accessibility", token: "dialog"), title: "Program",
                     capability: .available, minimized: true, focused: false, isProgramWindow: true)
check(attached.reduce(.windowSnapshot(attachedStamp, process, source: "accessibility", windows: [modal], capability: .available)) == [.windowPresented("committed")],
      "minimized discovery cannot confirm a new launch")
var shown = modal; shown.minimized = false
check(attached.reduce(.windowSnapshot(attachedStamp, process, source: "accessibility", windows: [shown], capability: .available)) == [.windowConfirmed("committed", process)],
      "an interactive standard AX window confirms its exact launch even without a Wine activation notification")
check(attached.snapshot.programActivity.running == 1 && attached.snapshot.programActivity.presented == 0,
      "one process owning CG and AX windows counts once")
check(attached.reduce(.windowObserved(attachedStamp, window)) == [.windowConfirmed("committed", process)], "window activation is issued only by the accepting store")
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

var history = fresh()
let historyStamp = history.stamp(for: a)!
let historicRequest = L.Request(id: "history", digest: "history", environment: nil, phase: .uncertain, launch: "history-launch")
let historicLaunch = L.Launch(id: "history-launch", request: "history", environment: a, name: "History", deadline: 300)
history.reduce(.restoring(true)); check(history.snapshot.hasActiveWork, "metadata recovery temporarily retains the app")
history.reduce(.recordedRequest(historicRequest, version: 2))
check(history.reduce(.recoveredLaunch(historyStamp, request: "history", launch: historicLaunch, root: process)).isEmpty, "uncalibrated environment cannot restore a process")
reconcile(&history, existence: .alive)
check(history.reduce(.recoveredLaunch(historyStamp, request: "history", launch: historicLaunch, root: process)) == [.restoreObservation(historyStamp, "history")], "restoration emits observation only")
history.reduce(.restoring(false))
check(!history.snapshot.hasActiveWork && history.snapshot.requests["history"]?.phase == .uncertain, "restoration cannot resume the old observation or change its outcome")
check(history.reduce(.windowObserved(historyStamp, window)).isEmpty, "restored window does not send launch-success feedback")
check(history.reduce(.deadline(1000)).isEmpty, "historical observation has no restarted deadline")
history.reduce(.recordedRequest(.init(id: "history", digest: "history", environment: nil, phase: .queued), version: 1))
check(history.snapshot.requests["history"]?.phase == .uncertain, "stale journal version cannot revive dispatch")

var admitted = fresh()
admitted.reduce(.recordedRequest(.init(id: "next", digest: "next", environment: nil, phase: .queued), version: 1))
check(admitted.snapshot.hasActiveWork, "durably queued request enters common retention policy")
admitted.reduce(.recordedRequest(.init(id: "next", digest: "next", environment: nil, phase: .dispatching, launch: "next-launch"), version: 2))
let nextStamp = admitted.stamp(for: a)!
admitted.reduce(.executionAttached(nextStamp, .init(id: "next", digest: "next", environment: a, phase: .dispatching, launch: "next-launch"),
    .init(id: "next-launch", request: "next", environment: a, name: "Next", deadline: .infinity)))
check(admitted.snapshot.launches["next-launch"] != nil, "published journal dispatch can attach its matching executor")
admitted.reduce(.observationFinished(nextStamp, launch: "next-launch", outcome: .failed))
admitted.reduce(.recordedRequest(.init(id: "next", digest: "next", environment: nil, phase: .observing, launch: "next-launch"), version: 3))
check(admitted.snapshot.requests["next"]?.phase == .failed, "late native receipt cannot regress the observer outcome")
admitted.reduce(.quit)
admitted.reduce(.recordedRequest(.init(id: "late-dispatch", digest: "late", environment: nil, phase: .dispatching, launch: "late"), version: 1))
check(admitted.snapshot.requests["late-dispatch"]?.phase == .uncertain, "post-quit dispatched receipt is not offered for resume")
check(!admitted.snapshot.restoring, "quit releases metadata recovery retention")

if !failures.isEmpty { failures.forEach { print("FAIL \($0)") }; exit(1) }
print("PASS lifecycle environment isolation, generation replacement, drain and uncertain outcomes")

// A launcher can remain alive as several games come and go, and a Windows
// double fork can discard the Unix parent before the app samples the child.
var clients = L.State()
var managed = environment(a)
managed.existence = .alive; managed.health = .healthy
clients.reduce(.manage(managed))
let groupStamp = clients.stamp(for: a)!
func committedClient(_ id: String, pid: Int32) -> L.ProcessID {
    clients.reduce(.accepted(.init(id: id, digest: id, environment: a, phase: .queued)))
    clients.reduce(.dispatchCommitted(groupStamp, request: id, launch: .init(id: id, request: id, environment: a, name: "BlueLauncher", deadline: 30)))
    let root = L.ProcessID(boot: "boot", pid: pid, started: 100)
    clients.reduce(.processObserved(groupStamp, .init(id: root, name: "BlueLauncher", environment: a, launch: id, ownership: .rootReceipt, existence: .alive)))
    clients.reduce(.independentProcess(groupStamp, root, name: "BlueLauncher.exe", existence: .alive, launchGroup: id))
    return root
}
let g1 = UUID().uuidString, g2 = UUID().uuidString
let parent1 = committedClient(g1, pid: 700), parent2 = committedClient(g2, pid: 701)
func compositor(_ process: L.ProcessID, _ number: String) -> L.Window {
    .init(id: .init(process: process, source: "coregraphics", token: number), title: "", capability: .unsupported)
}
clients.reduce(.windowObserved(groupStamp, compositor(parent1, "1")))
precondition(clients.snapshot.programActivity == .init(running: 0, presented: 0, launchers: 1))
let helpers = L.ProcessID(boot: "boot", pid: 705, started: 200)
clients.reduce(.independentProcess(groupStamp, helpers, name: "services.exe", existence: .alive, launchGroup: g1))
precondition(clients.snapshot.processes[helpers]?.launch == nil, "a broker inheriting the tag is not the game")
let first = L.ProcessID(boot: "boot", pid: 800, started: 201), second = L.ProcessID(boot: "boot", pid: 801, started: 203)
clients.reduce(.independentProcess(groupStamp, first, name: "bluecg.exe", existence: .alive))
clients.reduce(.windowObserved(groupStamp, compositor(first, "2"))) // window precedes root correlation
precondition(clients.reduce(.independentProcess(groupStamp, first, name: "bluecg.exe", existence: .alive, launchGroup: g1)) == [.windowPresented(g1)])
clients.reduce(.processExited(groupStamp, parent2)) // root exit isn't proof its successor ended
clients.reduce(.independentProcess(groupStamp, second, name: "bluecg.exe", existence: .alive, launchGroup: g2))
let hint = clients.reduce(.windowObserved(groupStamp, compositor(second, "3")))
precondition(hint == [.windowPresented(g2)], "presented target is running; only interactive evidence confirms readiness")
precondition(clients.snapshot.processes[first]?.ownership == .explicitHandoff && clients.snapshot.processes[second]?.launch == g2)
precondition(clients.snapshot.programActivity == .init(running: 2, presented: 0, launchers: 1))
clients.reduce(.windowSnapshot(groupStamp, first, source: "coregraphics", windows: [], capability: .unsupported))
precondition(clients.snapshot.programActivity.running == 2, "minimizing an identified live game does not end its session")
clients.reduce(.independentProcess(groupStamp, first, name: "bluecg.exe", existence: .exited))
precondition(clients.snapshot.programActivity.running == 1 && clients.snapshot.processes[parent1]?.existence == .alive)
clients.reduce(.independentProcess(groupStamp, second, name: "bluecg.exe", existence: .exited))
precondition(clients.snapshot.programActivity == .init(running: 0, presented: 0, launchers: 1))
let impostor = L.ProcessID(boot: "boot", pid: 800, started: 42)
clients.reduce(.independentProcess(groupStamp, impostor, name: "bluecg.exe", existence: .alive, launchGroup: g1))
precondition(clients.snapshot.processes[impostor]?.launch == nil, "a reused PID born before the root cannot be a successor")
precondition(clients.snapshot.requests.count == 2 && clients.snapshot.processes[helpers]?.existence == .alive)
print("PASS interactive versus splash; two launch groups in one prefix; root exit versus child handoff; multi-client updates 0→2→1→0, minimize, helper retention and PID reuse")

for (offset, image) in ["rundll32.exe", "winedbg.exe", "werfault.exe", "wineconsole.exe"].enumerated() {
    let service = L.ProcessID(boot: "boot", pid: Int32(920 + offset), started: 219)
    clients.reduce(.processObserved(groupStamp, .init(id: service, name: "BlueLauncher", environment: a,
        launch: g1, ownership: .processTree, existence: .alive)))
    clients.reduce(.independentProcess(groupStamp, service, name: image, existence: .alive, launchGroup: g1))
    precondition(clients.reduce(.windowObserved(groupStamp, compositor(service, "32"))).isEmpty)
    let utilityWindow = L.Window(id: .init(process: service, source: "accessibility", token: "utility"),
        title: "Setup", capability: .available, minimized: false, focused: true, isProgramWindow: true)
    precondition(clients.reduce(.windowSnapshot(groupStamp, service, source: "accessibility", windows: [utilityWindow], capability: .available)).isEmpty)
    precondition(clients.snapshot.programActivity.running == 0, "a helper appearing as an interactive dialog may not count as a game")
}
let orphan = L.ProcessID(boot: "boot", pid: 901, started: 302)
clients.reduce(.independentProcess(groupStamp, orphan, name: "bluecg.exe", existence: .alive))
clients.reduce(.windowObserved(groupStamp, compositor(orphan, "91")))
precondition(clients.snapshot.programActivity.running == 1)
clients.reduce(.independentProcess(groupStamp, orphan, name: "bluecg.exe", existence: .unconfirmed))
precondition(clients.snapshot.programActivity.checking && !clients.snapshot.programActivity.summary.contains("執行中 0"),
             "unknown liveness must remain visibly distinct from a confirmed exit")
clients.reduce(.independentProcess(groupStamp, orphan, name: "bluecg.exe", existence: .exited))
precondition(!clients.snapshot.programActivity.checking)
print("PASS helper CG surface or AX dialog cannot dismiss progress, activate or increment a game count; unreadable client birth shows pending until reobserved")

clients.reduce(.observationFinished(groupStamp, launch: g2, outcome: .confirmedStarted))
let laterClient = L.ProcessID(boot: "boot", pid: 907, started: 312)
clients.reduce(.independentProcess(groupStamp, laterClient, name: "bluecg.exe", existence: .alive, launchGroup: g2))
precondition(clients.snapshot.processes[laterClient]?.launch == nil,
             "an obsolete broker label from a completed and drained launch cannot claim a new client")
clients.reduce(.windowObserved(groupStamp, compositor(laterClient, "99")))
precondition(clients.snapshot.programActivity.running == 1, "the independently verified client still counts")
print("PASS stale broker group cannot claim a later game for a completed launch after all its programs exited")
