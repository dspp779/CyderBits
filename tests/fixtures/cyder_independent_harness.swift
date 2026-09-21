import Cocoa
import Darwin

typealias L = CyderLifecycle
typealias Inventory = CyderProcessInventory
typealias Discovery = CyderIndependentProcesses
final class CyderDiagnostics { static let shared = CyderDiagnostics(); func info(_ message: String) {} }
struct TestWindow { let pid: Int32; let ownerName: String; let windowID: UInt32 }
func cyderUsefulWindowOwnerName(_ name: String) -> String? { name }
func cyderWineArgvName(pid: Int32) -> String? { nil }
func wineOnscreenWindows(ownedBy pids: Set<Int32>) -> [TestWindow] { [] }
func pump(_ message: String, timeout: Double = 8, _ condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), message)
}
func settle(_ interval: Double = 0.1) {
    var done = false; DispatchQueue.main.asyncAfter(deadline: .now() + interval) { done = true }
    pump("settle", timeout: interval + 2) { done }
}
func background<T>(_ body: @escaping () -> T) -> T {
    var result: T?
    DispatchQueue.global().async { let value = body(); DispatchQueue.main.async { result = value } }
    pump("native read") { result != nil }; return result!
}
func procargs(_ args: [String], _ env: [String]) -> [UInt8] {
    var argc = Int32(args.count)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/fixture/wine".utf8) + [0, 0, 0]
    for arg in args + env { bytes += Array(arg.utf8) + [0] }
    return bytes + [0]
}
let valid = procargs(["wine", "", "C:\\path\\Helper.exe", "SECRET_DO_NOT_DISPLAY"], ["SECRET=DO_NOT_RETAIN", "WINEPREFIX=/fixture/prefix"])
precondition(Inventory.parse(valid) == .init(prefix: "/fixture/prefix", name: "Helper.exe"))
precondition(Inventory.parse(procargs(["wine"], ["CX_BOTTLE=name"])) == nil)
precondition(Inventory.parse(procargs(["wine"], ["WINEPREFIX=relative"])) == nil)
precondition(Inventory.parse(procargs(["wine"], ["WINEPREFIX=/one", "WINEPREFIX=/two"])) == nil)
precondition(Inventory.parse(Array(valid.dropLast(2))) == nil)
precondition(Inventory.parse([255,255,255,127,0]) == nil)
precondition(Inventory.parse(procargs([], ["WINEPREFIX=/one"])) == nil)
print("PASS bounded native metadata parser: empty argument, Windows basename only, malformed/truncated/count bounds, duplicate prefix, no CX_BOTTLE guessing")

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let prefix = directory.appendingPathComponent("prefix").path
let identity = background { CyderEnvironmentProbe.identify(prefix: URL(fileURLWithPath: prefix), engine: directory.appendingPathComponent("engine/bin/wineserver"))! }
let engine = identity.engine
let executable = directory.appendingPathComponent("engine/lib/wine/x86_64-unix/wine")
let root = Process(); let pipe = Pipe(); root.executableURL = executable
root.arguments = ["C:\\fixture\\Headless.exe", "SECRET_DO_NOT_DISPLAY"]
root.environment = ["WINEPREFIX": prefix]; root.standardOutput = pipe
try root.run(); root.waitUntilExit()
let pid = Int32(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!
let presence = background { CyderProcessEvidence.inspect(pid) }
guard case .live(let node) = presence else { fatalError("own orphan must be live") }
let birth = node.id
precondition(node.parent != root.processIdentifier, "fixture has not lost Unix ancestry")
let scope = background { Inventory.prefixID(prefix)! }
let environment = L.Environment(id: scope, prefix: identity.prefix, engine: engine, generation: 1, existence: .alive, health: .healthy)
precondition(background { Inventory.pids().contains(pid) })
let reading = background { Inventory.read(pid, environments: [environment]) }
precondition(reading.match?.process == birth && reading.match?.environment == scope && reading.match?.name == "Headless.exe")
let otherPrefix = directory.appendingPathComponent("other-prefix").path
let otherID = background { Inventory.prefixID(otherPrefix)! }
let other = L.Environment(id: otherID, prefix: otherPrefix, engine: engine, generation: 1, existence: .alive, health: .healthy)
precondition(background { Inventory.read(pid, environments: [other]).match == nil })
precondition(background { !Inventory.trusted(executable.path, engine: directory.appendingPathComponent("impostor/bin/wineserver").path) })
print("PASS actual same-UID inventory, reparented headless native birth, exact engine/prefix identity and name; other managed prefix and engine rejected (fixture is not Wine)")
let noWindows = CyderWindowAccess.Driver(scan: { _ in .windows([]) }, equal: { $0 === $1 }, activate: { _,_,_ in fatalError("discovery must not activate") })
let native = CyderStatusItemController(windowDriver: noWindows)
native.setUIVisible(true); native.receiveLifecycleEvent(.manage(environment))
pump("formal system discovery reaches store") { native.lifecycleSnapshot.processes[birth]?.existence == .alive }
precondition(native.lifecycleSnapshot.processes[birth]?.launch == nil && native.lifecycleSnapshot.launches.isEmpty)
let menu = NSMenu(); native.menuNeedsUpdate(menu)
precondition(menu.items.contains { $0.title == "其他執行中的 Windows 程序" })
precondition(menu.items.contains { $0.title.contains("Headless.exe") && !$0.isEnabled })
precondition(!menu.items.contains { $0.title.contains("SECRET") || $0.title.contains("正在啟動") })
native.quiesce(); settle()
precondition(background { CyderProcessEvidence.live(birth) }, "quiesce killed independent process")
// A second observer recovers the same orphan without any journal or launch.
let reopened = CyderStatusItemController(windowDriver: noWindows)
reopened.setUIVisible(true); reopened.receiveLifecycleEvent(.manage(environment))
pump("reopen discovers without replay") { reopened.lifecycleSnapshot.processes[birth]?.existence == .alive }
precondition(background { CyderProcessEvidence.live(birth) && kill(pid, SIGTERM) == 0 })
pump("own orphan exit observed", timeout: 8) { reopened.lifecycleSnapshot.processes[birth]?.existence == .exited }
precondition(reopened.lifecycleSnapshot.environments[scope]?.existence == .alive, "client exit ended shared environment")
reopened.quiesce()
print("PASS native discovery → formal store → real AppKit menu, quit preserves orphan, reopen re-observes, verified own helper exit leaves environment intact")

// Independent evidence may not overwrite known ownership; exact historical
// receipts can upgrade a previously independent root regardless of arrival order.
var state = L.State(); state.reduce(.manage(environment))
let stamp = state.stamp(for: scope)!
let synthetic = L.ProcessID(boot: "fixture", pid: 42001, started: 1)
state.reduce(.independentProcess(stamp, synthetic, name: "Unknown.exe", existence: .alive))
state.reduce(.journalRequest(.init(id: "history", digest: "digest", environment: scope, phase: .uncertain, launch: "history"), version: 1))
let effects = state.reduce(.recoveredLaunch(stamp, request: "history", launch: .init(id: "history", request: "history", environment: scope, name: "Historical", deadline: 0), root: synthetic))
precondition(effects == [.restoreObservation(stamp, "history")] && state.snapshot.processes[synthetic]?.launch == "history")
for existence in [L.Existence.alive, .unconfirmed, .exited] {
    state.reduce(.independentProcess(stamp, synthetic, name: "Other", existence: existence))
}
precondition(state.snapshot.processes[synthetic]?.launch == "history" && state.snapshot.processes[synthetic]?.existence == .alive)
let unowned = L.ProcessID(boot: "fixture", pid: 42002, started: 1)
state.reduce(.independentProcess(stamp, unowned, name: "Independent", existence: .alive))
let window = L.Window(id: .init(process: unowned, source: "accessibility", token: "own-window"), title: "Same", capability: .available)
precondition(state.reduce(.windowObserved(stamp, window)).isEmpty, "independent window manufactured launch success")
let action = UUID()
precondition(state.reduce(.activateWindow(window.id, action)) == [.activateWindow(stamp, window.id, action)])
state.reduce(.independentProcess(stamp, unowned, name: "Independent", existence: .unconfirmed))
precondition(state.snapshot.windows[window.id] == nil && state.snapshot.windowAction?.result != nil)
state.reduce(.windowActionFinished(action, .shown))
precondition(state.snapshot.windowAction?.result != .shown, "unknown independent process accepted late activation success")
print("PASS independent discovery cannot downgrade proven ownership; historical receipt can claim an already discovered root")

final class Backend {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var blocked: Set<Int32> = [], entered: [Int32] = [], reads: [Int32: Inventory.Reading] = [:], inventory: [Int32] = []
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var driver: Discovery.Driver { .init(pids: { [self] in locked { inventory } }, read: { [self] pid, _ in
        precondition(!Thread.isMainThread)
        let hold = locked { entered.append(pid); return blocked.contains(pid) }
        if hold { precondition(gate.wait(timeout: .now() + 20) == .success, "fixture gate") }
        return locked { reads[pid] ?? .init(presence: .unavailable, match: nil) }
    }, observeExits: false) }
    func live(_ pid: Int32, scope: L.EnvironmentID, started: UInt64 = 1) -> L.ProcessID {
        let id = L.ProcessID(boot: "fixture", pid: pid, started: started)
        locked { reads[pid] = .init(presence: .live(.init(id: id, parent: 1)), match: .init(process: id, environment: scope, name: "Same.exe")) }
        return id
    }
}
let backend = Backend()
let blockedID = backend.live(43001, scope: scope), healthyID = backend.live(43002, scope: otherID)
backend.locked { backend.blocked = [blockedID.pid]; backend.inventory = [blockedID.pid, healthyID.pid] }
let mixed = CyderStatusItemController(windowDriver: noWindows, discoveryDriver: backend.driver)
mixed.setUIVisible(true); mixed.receiveLifecycleEvent(.manage(environment)); mixed.receiveLifecycleEvent(.manage(other))
pump("one blocked classification leaves healthy environment usable") { mixed.lifecycleSnapshot.processes[healthyID]?.existence == .alive }
precondition(mixed.lifecycleSnapshot.processes[blockedID] == nil)
backend.locked { backend.reads[healthyID.pid] = .init(presence: .unavailable, match: nil); backend.inventory = [] }
pump("inventory omission still reads known birth", timeout: 5) { mixed.lifecycleSnapshot.processes[healthyID]?.existence == .unconfirmed }
precondition(mixed.lifecycleSnapshot.hasEnvironment)
let replacement = backend.live(healthyID.pid, scope: otherID, started: 2)
pump("PID reuse replaces exact independent birth", timeout: 5) { mixed.lifecycleSnapshot.processes[healthyID]?.existence == .exited && mixed.lifecycleSnapshot.processes[replacement]?.existence == .alive }
mixed.quiesce(); backend.gate.signal(); settle()
precondition(mixed.lifecycleSnapshot.processes[blockedID] == nil)
print("PASS fault injection: one blocked PID permits another environment; inventory omission is not exit; unavailable becomes unknown, exact PID reuse, quit fences late read")

let changing = Backend(), changingID = changing.live(43501, scope: scope)
changing.locked { changing.inventory = [changingID.pid]; changing.blocked = [changingID.pid] }
let generation = CyderStatusItemController(windowDriver: noWindows, discoveryDriver: changing.driver)
generation.setUIVisible(true); generation.receiveLifecycleEvent(.manage(environment))
pump("old generation scan entered") { changing.locked { changing.entered.count == 1 } }
var changedEnvironment = environment; changedEnvironment.generation = 2
generation.receiveLifecycleEvent(.manage(changedEnvironment))
pump("new generation in snapshot") { generation.lifecycleSnapshot.environments[scope]?.generation == 2 }
changing.gate.signal()
pump("new generation requires new physical read", timeout: 5) { changing.locked { changing.entered.count == 2 } }
precondition(generation.lifecycleSnapshot.processes.isEmpty, "old-generation read attached to new environment")
changing.gate.signal()
pump("fresh generation can attach") { generation.lifecycleSnapshot.processes[changingID]?.existence == .alive }
let generationStamp = L.Stamp(epoch: generation.lifecycleEpoch, environment: scope, generation: 2)
let calibration = UUID()
generation.receiveLifecycleEvent(.reconcileStarted(generationStamp, calibration))
generation.receiveLifecycleEvent(.reconciled(generationStamp, calibration, .unconfirmed, .degraded))
pump("lost environment proof disables independent capabilities") { generation.lifecycleSnapshot.processes[changingID]?.existence == .unconfirmed }
generation.receiveLifecycleEvent(.independentProcess(generationStamp, changingID, name: "Late", existence: .alive))
settle(); precondition(generation.lifecycleSnapshot.processes[changingID]?.existence == .unconfirmed)
generation.quiesce()
print("PASS changed generation rejects old evidence, fresh physical read can attach; degraded environment rejects late alive and retains unknown process")

let held = Backend(), first = held.live(44001, scope: scope), second = held.live(44002, scope: scope)
held.locked { held.inventory = [first.pid, second.pid] + Array(44003...44030); held.blocked = [first.pid, second.pid] }
let blocked = CyderStatusItemController(windowDriver: noWindows, discoveryDriver: held.driver)
blocked.setUIVisible(true); blocked.receiveLifecycleEvent(.manage(environment))
pump("two physical reads") { held.locked { held.entered.count == 2 } }
// Change generation while the physical reads are held. Old reads cannot attach.
var replacementEnvironment = environment; replacementEnvironment.generation = 2
blocked.receiveLifecycleEvent(.manage(replacementEnvironment))
settle(5.2)
precondition(held.locked { held.entered.count == 2 } && blocked.lifecycleSnapshot.processes.isEmpty)
let blockedStamp = L.Stamp(epoch: blocked.lifecycleEpoch, environment: scope, generation: 2)
for pid in 46000..<46032 {
    blocked.receiveLifecycleEvent(.independentProcess(blockedStamp, .init(boot: "fixture", pid: Int32(pid), started: 1), name: "Same.exe", existence: .alive))
}
pump("32 independent snapshot rows") { blocked.lifecycleSnapshot.processes.count == 32 }
let blockedMenu = NSMenu(); var samples: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    blocked.menuNeedsUpdate(blockedMenu); blocked.menuWillOpen(blockedMenu); blocked.menuDidClose(blockedMenu)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
blocked.quiesce(); held.gate.signal(); held.gate.signal(); settle()
precondition(held.locked { held.entered.count == 2 } && blocked.lifecycleSnapshot.processes.count == 32)
precondition(blocked.lifecycleSnapshot.processes[first] == nil && blocked.lifecycleSnapshot.processes[second] == nil)
let labels = blockedMenu.items.filter { $0.title.hasPrefix("Same.exe") }.map(\.title)
precondition(labels.count == 32 && Set(labels).count == 32, "same-named independent rows are not distinguishable")
print("independent callback-cycle proxy independent_rows=32 samples=30 p95_ms=\(samples.sorted()[28]) max_ms=\(samples.max()!)")
print("independent_sample,callback_cycle_ms")
for (i, sample) in samples.enumerated() { print("\(i + 1),\(sample)") }
print("PASS held reads retain physical slots beyond deadline; stale generation and quit reject late evidence; menu remains responsive")

try "passed\n".write(to: directory.appendingPathComponent("passed"), atomically: true, encoding: .utf8)
