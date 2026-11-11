import Foundation
import Darwin

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let paths = CyderEnvironmentReadiness.Paths(resources: root.appendingPathComponent("resources"),
    engine: root.appendingPathComponent("engine"), bottle: root.appendingPathComponent("bottle"))
let fm = FileManager.default
func put(_ base: URL, _ name: String, _ text: String, mode: mode_t = 0o600) {
    let url = base.appendingPathComponent(name)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
    chmod(url.path, mode)
}
let version = "CX26.3.0-W11-Cyder013-rc-2"
let pin = String(repeating: "a", count: 64)
put(paths.resources, "engine-version.txt", version)
put(paths.resources, "engine-artifact-sha256.txt", pin)
check(CyderEnvironmentReadiness.read(paths) == .notPrepared, "fresh install is not prepared")
put(paths.engine, "bin/wine", "fixture executable; never run", mode: 0o700)
put(paths.engine, "version", "CX26-3-0-W11-Cyder013-rc-2")
put(paths.engine, ".cyder-engine-artifact-sha256", pin)
put(paths.engine, ".cyder-engine-signed", "signed\n")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=\(version)\n")
put(paths.bottle, ".cyder-golden-baseline-v2", "") // Existing baseline contract checks its presence.
put(paths.bottle, "system.reg", "WINE REGISTRY Version 2\n;; synthetic")
put(paths.bottle, "user.reg", "WINE REGISTRY Version 2\n;; synthetic")
put(paths.bottle, "drive_c/windows/system32/kernel32.dll", "synthetic")
check(CyderEnvironmentReadiness.read(paths) == .ready, "current launch metadata, slug compatibility and optional graphics absent")
try! fm.removeItem(at: paths.engine.appendingPathComponent("bin/wine"))
check(CyderEnvironmentReadiness.read(paths) == .needsUpdate, "existing initialized prefix with absent engine requires explicit update")
put(paths.engine, "bin/wine", "fixture executable; never run", mode: 0o700)
put(paths.engine, ".cyder-engine-artifact-sha256", String(repeating: "b", count: 64))
check(CyderEnvironmentReadiness.read(paths) == .needsUpdate, "old artifact")
put(paths.engine, ".cyder-engine-artifact-sha256", pin)
put(paths.engine, "version", "old-engine")
check(CyderEnvironmentReadiness.read(paths) == .needsUpdate, "old engine")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=2\nengine=old-engine\n")
check(CyderEnvironmentReadiness.read(paths) == .needsUpdate, "complete older environment without optional CrossOver template is manual update")
// An existing old engine with no initialized prefix is first-run setup.
try! fm.removeItem(at: paths.bottle.appendingPathComponent(".cyder-bootstrap-v1"))
check(CyderEnvironmentReadiness.read(paths) == .notPrepared, "old engine with missing prefix must initialize first")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=old-engine\n")
put(paths.bottle, "system.reg", "malformed")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "old engine cannot hide malformed prefix evidence")
put(paths.bottle, "system.reg", "WINE REGISTRY Version 2\n")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=\(version)\n")
put(paths.engine, "version", version)
let marker = paths.bottle.appendingPathComponent(".cyder-bootstrap-v1")
check(!CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: version), "current stamp does not bootstrap")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=old-engine")
check(CyderEnvironmentReadiness.read(paths) == .needsBootstrapUpdate, "old prefix record needs bootstrap only")
check(CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: version), "mismatched stamp routes to bootstrap")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1")
check(CyderEnvironmentReadiness.read(paths) == .needsBootstrapUpdate, "legacy prefix needs existing upgrade")
check(CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: version), "same-engine legacy stamp routes to bootstrap")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=\(version)\nengine=\(version)")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "ambiguous prefix record")
check(!CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: version), "ambiguous stamp does not request repair")
check(!CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: nil), "unknown engine cannot request repair")
put(paths.bottle, ".cyder-bootstrap-v1", "revision=1\nengine=\(version)")
put(paths.bottle, "system.reg", "truncated")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "damaged registry header")
put(paths.bottle, "system.reg", "WINE REGISTRY Version 2\n")
put(paths.engine, ".cyder-engine-signed", "")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "empty signature stamp")
put(paths.engine, ".cyder-engine-signed", "signed")
put(paths.resources, "engine-artifact-sha256.txt", "not-a-pin")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "invalid package metadata")
put(paths.resources, "engine-artifact-sha256.txt", pin)
put(paths.engine, "share/crossover/bottle_data/cxbottle.conf", "template")
check(CyderEnvironmentReadiness.read(paths) == .notPrepared, "missing required CrossOver config")
put(paths.bottle, "cxbottle.conf", "fixture configuration")
check(CyderEnvironmentReadiness.read(paths) == .ready, "CrossOver config present")
chmod(paths.bottle.path, 0)
check(CyderEnvironmentReadiness.read(paths) == .unknown, "access denied is not absence")
check(!CyderEnvironmentReadiness.bootstrapNeedsUpdate(marker, engineVersion: version), "permission failure cannot request repair")
chmod(paths.bottle.path, 0o700)
put(paths.engine, "version", String(repeating: "x", count: 16385))
check(CyderEnvironmentReadiness.read(paths) == .unknown, "metadata bounded")
try! fm.removeItem(at: paths.engine.appendingPathComponent("version"))
check(mkfifo(paths.engine.appendingPathComponent("version").path, 0o600) == 0, "create FIFO fixture")
check(CyderEnvironmentReadiness.read(paths) == .unknown, "nonregular metadata does not block")
try! fm.removeItem(at: paths.engine.appendingPathComponent("version"))
put(paths.engine, "version", version)

func spin(_ condition: () -> Bool, _ label: String) {
    let end = Date().addingTimeInterval(3)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), label)
}
final class Reads {
    private let lock = NSLock()
    private var calls = 0
    private var completed = 0
    let results: [CyderEnvironmentReadiness]
    let gates: [DispatchSemaphore?]
    init(_ results: [CyderEnvironmentReadiness], _ gates: [DispatchSemaphore?]) { self.results = results; self.gates = gates }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var finished: Int { lock.lock(); defer { lock.unlock() }; return completed }
    func read() -> CyderEnvironmentReadiness {
        lock.lock(); let index = calls; calls += 1; lock.unlock()
        guard index < results.count else { fatalError("unexpected extra readiness read") }
        _ = gates[index]?.wait(timeout: .now() + 3)
        lock.lock(); completed += 1; lock.unlock()
        return results[index]
    }
}
// Typed library projection: ready disappears; absence/update/uncertainty offers
// one initializer; active work cannot repeat; failures retain a visible retry.
let readyUI = CyderEnvironmentReadinessObserver.State.current(.ready).initialization
check(!readyUI.showsButton && readyUI.message == nil && !readyUI.canInitialize, "ready has no initialization UI")
for state in [CyderEnvironmentReadiness.notPrepared, .needsUpdate, .needsBootstrapUpdate, .unknown] {
    let ui = CyderEnvironmentReadinessObserver.State.current(state).initialization
    check(ui.showsButton && ui.canInitialize && ui.message == nil, "unready offers only initialization")
}
let checkingUI = CyderEnvironmentReadinessObserver.State.checking.initialization
check(!checkingUI.canInitialize && checkingUI.message != nil, "checking cannot admit initialization")
let busyUI = CyderEnvironmentReadinessObserver.State.preparing("fixture progress").initialization
check(busyUI.showsButton && !busyUI.canInitialize && busyUI.message == "fixture progress", "initialization progress prevents duplicate work")
let errorUI = CyderEnvironmentReadinessObserver.State.failed("fixture failure").initialization
check(errorUI.showsButton && errorUI.canInitialize && errorUI.message == "fixture failure", "failure remains visible with retry")

let gate = DispatchSemaphore(value: 0)
let reads = Reads([.ready, .notPrepared, .ready, .ready, .ready], [gate, nil, gate, nil, nil])
let observer = CyderEnvironmentReadinessObserver(deadline: 0.04, read: reads.read)
observer.refresh()
spin({ reads.count == 1 }, "read begins off main thread")
observer.beginOperation()
observer.progress("preparing fixture")
gate.signal()
spin({ reads.finished == 1 }, "old read completes")
RunLoop.current.run(until: Date().addingTimeInterval(0.06))
check(observer.state == .preparing("preparing fixture"), "late read and timeout cannot replace progress")
observer.endOperation()
spin({ observer.state == .current(.notPrepared) }, "operation completion rereads state")
observer.refresh()
spin({ reads.count == 3 }, "new read starts")
observer.recordFailure("actual preparation failed")
gate.signal()
spin({ reads.finished == 3 }, "failure stale read completes")
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(observer.state == .failed("actual preparation failed"), "old ready cannot erase failure")
observer.refresh()
spin({ reads.finished == 4 }, "return to library still rereads")
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(observer.state == .failed("actual preparation failed"), "metadata alone cannot disprove a health-check failure")
observer.beginOperation(); observer.endOperation()
spin({ observer.state == .current(.ready) }, "explicit retry clears prior failure with fresh read")
observer.quiesce()

let repairs = Reads([.ready, .ready, .notPrepared], [nil, nil, nil])
let repairing = CyderEnvironmentReadinessObserver(read: repairs.read)
repairing.recordFailure("previous preparation failure")
repairing.beginOperation(clearFailure: false); repairing.endOperation()
spin({ repairs.finished == 1 }, "unsuccessful repair or unrelated operation rereads")
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(repairing.state == .failed("previous preparation failure"), "unsuccessful repair cannot erase failure")
repairing.beginOperation(clearFailure: false)
repairing.repairSucceeded(); repairing.endOperation()
spin({ repairing.state == .current(.ready) }, "confirmed rebuild clears stale failure after fresh read")
repairing.recordFailure("another preparation failure")
repairing.beginOperation(clearFailure: false)
repairing.repairSucceeded(); repairing.endOperation()
spin({ repairing.state == .current(.notPrepared) }, "repair result never substitutes for current disk readiness")
repairing.quiesce()

let slowGate = DispatchSemaphore(value: 0)
let slow = Reads([.ready, .needsUpdate], [slowGate, nil])
let bounded = CyderEnvironmentReadinessObserver(deadline: 0.03, read: slow.read)
bounded.refresh()
spin({ slow.count == 1 }, "blocked IO starts")
for _ in 0..<12 { bounded.refresh() }
spin({ bounded.state == .current(.unknown) }, "deadline reports unknown without blocking UI")
check(slow.count == 1, "reopens do not grow physical workers")
slowGate.signal()
spin({ bounded.state == .current(.needsUpdate) }, "coalesced fresh read replaces stale result")
check(slow.count == 2, "only one pending refresh")
bounded.quiesce()

let diskObserver = CyderEnvironmentReadinessObserver { CyderEnvironmentReadiness.read(paths) }
diskObserver.refresh()
spin({ diskObserver.state == .current(.ready) }, "fresh launch reads real fixture state")
try! fm.removeItem(at: paths.bottle.appendingPathComponent(".cyder-bootstrap-v1"))
diskObserver.refresh()
spin({ diskObserver.state == .current(.notPrepared) }, "return observes external removal rather than saved ready bool")
diskObserver.quiesce()
print("PASS: \(assertions) readiness assertions; metadata, stale results, failure, timeout, bounded IO, and fresh reopen")

// Actual session admission: proven first-run only, one automatic attempt,
// duplicate rejection, manual retry, and stale completion isolation.
let admission = CyderEnvironmentPreparationAdmission()
check(admission.begin(automatic: true, readiness: .current(.notPrepared), eligibleForAutomatic: false) == nil, "hidden/secondary/document entry does not auto prepare")
for state in [CyderEnvironmentReadiness.ready, .needsUpdate, .needsBootstrapUpdate, .unknown] {
    check(admission.begin(automatic: true, readiness: .current(state), eligibleForAutomatic: true) == nil, "existing or uncertain environment never auto updates")
}
check(!admission.automaticAttempted, "ineligible reads do not consume one automatic attempt")
let first = admission.begin(automatic: true, readiness: .current(.notPrepared), eligibleForAutomatic: true)!
check(admission.automaticAttempted, "first-run starts automatic preparation")
check(admission.begin(automatic: false, readiness: .current(.notPrepared), eligibleForAutomatic: true) == nil, "manual duplicate cannot overlap")
check(!admission.finish(UUID()), "late unrelated completion cannot finish active operation")
check(admission.finish(first), "actual first-run completion releases admission")
check(admission.begin(automatic: true, readiness: .current(.notPrepared), eligibleForAutomatic: true) == nil, "failed first-run refresh cannot loop")
let retry = admission.begin(automatic: false, readiness: .failed("retry fixture"), eligibleForAutomatic: true)!
check(!admission.finish(first), "previous operation completion cannot end manual retry")
check(admission.finish(retry), "manual retry can complete")
let update = admission.begin(automatic: false, readiness: .current(.needsUpdate), eligibleForAutomatic: true)!
check(admission.finish(update), "explicit update uses same single-operation admission")

var released = 0
let ownership = CyderEnvironmentPreparationOwnership { released += 1 }
ownership.executorStarted(); ownership.executorReleased()
check(released == 0, "completed first step retains whole-operation lease")
ownership.executorStarted(); ownership.finish()
check(released == 0, "unconfirmed final executor still owns lease after task returns")
ownership.executorReleased()
check(released == 1, "real executor release finishes operation exactly once")
ownership.finish()
check(released == 1, "repeated finish cannot release lease twice")
print("PASS: \(assertions) including first-run/update/retry/session admission and real executor lease ownership")

// Wire production observer + admission to a fake ensure operation against this
// owned fixture. Its first failure must settle, stay visible and require retry.
let startupAdmission = CyderEnvironmentPreparationAdmission()
let startup = CyderEnvironmentReadinessObserver { CyderEnvironmentReadiness.read(paths) }
var fakeEnsures = 0
func fakePrepare(automatic: Bool) {
    guard let id = startupAdmission.begin(automatic: automatic, readiness: startup.state, eligibleForAutomatic: true) else { return }
    fakeEnsures += 1
    startup.beginOperation()
    DispatchQueue.main.async {
        // Pretend all ensure commands returned zero. Only the second attempt
        // actually leaves a ready prefix; disk evidence decides completion.
        if fakeEnsures > 1 { put(paths.bottle, ".cyder-bootstrap-v1", "revision=2\nengine=\(version)\n") }
        if CyderEnvironmentReadiness.read(paths) != .ready { startup.recordFailure("fixture initialization failed") }
        check(startupAdmission.finish(id), "fixture ensure operation completes once")
        startup.endOperation()
    }
}
startup.onUpdate = { state in
    if state == .current(.notPrepared) { fakePrepare(automatic: true) }
}
startup.refresh()
spin({ startup.state == .failed("fixture initialization failed") && startupAdmission.operation == nil }, "first normal app entry runs fake ensure and retains failure")
startup.refresh()
RunLoop.current.run(until: Date().addingTimeInterval(0.06))
check(fakeEnsures == 1, "failed refresh never auto repeats ensure")
fakePrepare(automatic: false)
spin({ startup.state == .current(.ready) }, "explicit retry completes setup and refreshes actual fixture readiness")
check(fakeEnsures == 2, "one first-run plus one explicit retry")
startup.quiesce()
print("PASS: \(assertions) total including observer-to-ensure first-run failure and manual retry fixture")

func entry(primary: Bool = true, readOnly: Bool = false, visible: Bool = true,
           normal: Bool = true, recovered: Bool = true, pending: Bool = false,
           busy: Bool = false) -> CyderEnvironmentPreparationAdmission.Entry {
    .init(primary: primary, readOnly: readOnly, visible: visible, normalAppEntry: normal,
          recoveryCompleted: recovered, pendingLaunches: pending, operationBusy: busy)
}
check(entry().permitsAutomatic, "normal primary visible entry can initialize")
for blocked in [entry(primary: false), entry(readOnly: true), entry(visible: false),
                entry(normal: false), entry(recovered: false), entry(pending: true), entry(busy: true)] {
    check(!blocked.permitsAutomatic, "secondary/readonly/hidden/document/recovery/pending/busy cannot initialize")
}
// A prior document event is intentionally absent from Entry: later explicit
// resident/library intent is eligible once its actual pending work has ended.
let residentAdmission = CyderEnvironmentPreparationAdmission()
check(residentAdmission.begin(automatic: true, readiness: .current(.notPrepared), eligibleForAutomatic: entry(normal: false, pending: true).permitsAutomatic) == nil, "initial document event cannot initialize invisibly")
let resident = residentAdmission.begin(automatic: true, readiness: .current(.notPrepared), eligibleForAutomatic: entry(normal: true, pending: false).permitsAutomatic)
check(resident != nil, "explicit library reopen after failed document can initialize")
if let resident { residentAdmission.finish(resident) }
print("PASS: \(assertions) total readiness, first-run, update, retry, real-executor and resident/document-entry assertions")
