import Foundation

/// Pure state machine. All OS, journal and AppKit work belongs to adapters.
/// Events are ordered by the store, never by wall-clock timestamps.
enum CyderLifecycle {
    struct EnvironmentID: Hashable, Codable {
        let uid: UInt32
        let device: UInt64
        let inode: UInt64
        let namespace: String
    }
    struct ProcessID: Hashable, Codable {
        let boot: String
        let pid: Int32
        let started: UInt64
    }
    struct WindowID: Hashable, Codable {
        let process: ProcessID
        let source: String
        let token: String
    }
    enum Phase: String, Codable { case active, quiescing, terminated }
    enum Existence: String, Codable { case unconfirmed, alive, exited }
    enum Health: String, Codable { case attaching, healthy, degraded }
    enum Stop: String, Codable { case idle, executing, unconfirmed, finished, failed }
    enum RequestPhase: String, Codable {
        case submitted, queued, dispatching, observing, completed, failed, cancelled, uncertain, awaitingUserResume
        var isActive: Bool {
            switch self {
            case .submitted, .queued, .dispatching, .observing: return true
            default: return false
            }
        }
    }
    enum Outcome: String, Codable { case confirmedStarted, finishedWithoutWindow, failed, unconfirmed, cancelled }
    enum Capability: String, Codable { case available, checking, temporarilyUnavailable, permissionRequired, unsupported }
    enum Ownership: String, Codable { case rootReceipt, processTree, explicitHandoff }
    struct Environment: Equatable {
        let id: EnvironmentID
        let prefix: String
        let engine: String
        var generation: UInt64
        var existence: Existence = .unconfirmed
        var health: Health = .attaching
        var stop: Stop = .idle
        var waiter: UUID?
        var reconciliation: UUID?
        var operation: UUID?
    }
    struct Request: Equatable {
        let id: String
        let digest: String
        let environment: EnvironmentID?
        var phase: RequestPhase
        var launch: String?
        var outcome: Outcome?
    }
    struct Launch: Equatable {
        let id: String
        let request: String
        let environment: EnvironmentID
        let name: String
        var deadline: TimeInterval // monotonic; never reset by root exit
        var outcome: Outcome?
        var processes: Set<ProcessID> = []
    }
    struct ProcessRecord: Equatable {
        let id: ProcessID
        var name: String
        let environment: EnvironmentID
        var launch: String?
        var ownership: Ownership?
        var existence: Existence
        var windowCapability: Capability? = nil
    }
    struct Window: Equatable {
        let id: WindowID
        var title: String
        var capability: Capability
        var minimized: Bool? = nil
        var focused: Bool? = nil
    }
    enum WindowResult: String { case shown, windowGone, processEnded, permissionRequired, unsupported, unconfirmed }
    struct WindowAction {
        let id: UUID
        let window: WindowID
        var showingProgress = false
        var result: WindowResult?
    }
    struct Stamp: Equatable {
        let epoch: UUID
        let environment: EnvironmentID
        let generation: UInt64
    }
    struct Snapshot {
        let epoch: UUID
        let revision: UInt64
        let phase: Phase
        let visibleUI: Bool
        let ingressPending: Bool
        let restoring: Bool
        let environments: [EnvironmentID: Environment]
        let requests: [String: Request]
        let launches: [String: Launch]
        let processes: [ProcessID: ProcessRecord]
        let windows: [WindowID: Window]
        let windowAction: WindowAction?
        var hasActiveWork: Bool { restoring || ingressPending || requests.values.contains { $0.phase.isActive }
            || (windowAction != nil && windowAction?.result != .shown) }
        var hasEnvironment: Bool { environments.values.contains { $0.existence != .exited } }
        var keepStatusItem: Bool { phase == .active && (visibleUI || hasActiveWork || hasEnvironment) }
        var canAutoTerminate: Bool { phase == .active && !keepStatusItem }
    }
    enum Event {
        case visibleUI(Bool)
        case ingressPending(Bool)
        case restoring(Bool)
        case journalRequest(Request, version: UInt64)
        case recoveredLaunch(Stamp, request: String, launch: Launch, root: ProcessID)
        case manage(Environment)
        case accepted(Request) // emitted only after durable acceptance
        case dispatchCommitted(Stamp, request: String, launch: Launch)
        // Attaches an already committed executor; this never emits a spawn.
        case executionAttached(Stamp, Request, Launch)
        case observationStarted(Stamp, launch: String, deadline: TimeInterval)
        case cancellationCommitted(request: String)
        case observationFinished(Stamp, launch: String, outcome: Outcome)
        case deadline(TimeInterval)
        case waiterStarted(Stamp, UUID)
        case waiterFinished(Stamp, UUID, cancelled: Bool)
        case reconcileStarted(Stamp, UUID)
        case reconciled(Stamp, UUID, Existence, Health)
        case independentProcess(Stamp, ProcessID, name: String, existence: Existence)
        case processObserved(Stamp, ProcessRecord)
        case processExited(Stamp, ProcessID)
        case windowObserved(Stamp, Window)
        case windowClosed(Stamp, WindowID)
        case windowSnapshot(Stamp, ProcessID, source: String, windows: [Window]?, capability: Capability)
        case activateWindow(WindowID, UUID)
        case windowActionProgress(UUID)
        case windowActionFinished(UUID, WindowResult)
        case dismissWindowFeedback(UUID)
        case stopRequested(Stamp, UUID)
        case stopFinished(Stamp, UUID, success: Bool)
        case quit
        case terminated
    }
    enum Effect: Equatable {
        case reconcile(Stamp)
        case stop(Stamp, UUID)
        case observationCompleted(String, Outcome)
        case windowConfirmed(String)
        case activateWindow(Stamp, WindowID, UUID)
        case restoreObservation(Stamp, String)
        case persistQuiescing
        case cancelOwnedObservers
    }
    struct State {
        let epoch: UUID
        private(set) var revision: UInt64 = 0
        private(set) var phase: Phase = .active
        private(set) var visibleUI = false
        private(set) var ingressPending = false
        private(set) var restoring = false
        private var journalVersions: [String: UInt64] = [:]
        private(set) var environments: [EnvironmentID: Environment] = [:]
        private(set) var requests: [String: Request] = [:]
        private(set) var launches: [String: Launch] = [:]
        private(set) var processes: [ProcessID: ProcessRecord] = [:]
        private(set) var windows: [WindowID: Window] = [:]
        private(set) var windowAction: WindowAction?
        // Tombstones prevent an older scan from resurrecting the same process instance.
        private struct ProcessKey: Hashable { let environment: EnvironmentID; let process: ProcessID }
        private var exitedProcesses: Set<ProcessKey> = []
        private var launchStamps: [String: Stamp] = [:]
        init(epoch: UUID = UUID()) { self.epoch = epoch }
        var snapshot: Snapshot {
            Snapshot(epoch: epoch, revision: revision, phase: phase, visibleUI: visibleUI,
                     ingressPending: ingressPending, restoring: restoring, environments: environments, requests: requests,
                     launches: launches, processes: processes, windows: windows, windowAction: windowAction)
        }
        func stamp(for id: EnvironmentID) -> Stamp? {
            guard let environment = environments[id] else { return nil }
            return Stamp(epoch: epoch, environment: id, generation: environment.generation)
        }
        private func accepts(_ stamp: Stamp, includingExited: Bool = false) -> Bool {
            phase == .active && stamp.epoch == epoch && environments[stamp.environment]?.generation == stamp.generation
                && (includingExited || environments[stamp.environment]?.existence != .exited)
        }
        private func windowFailure(_ id: WindowID) -> WindowResult? {
            if processes[id.process]?.existence == .exited { return .processEnded }
            guard let window = windows[id], let process = processes[id.process], process.existence == .alive,
                  let stamp = stamp(for: process.environment), accepts(stamp) else { return .windowGone }
            switch window.capability {
            case .available: return nil
            case .permissionRequired: return .permissionRequired
            case .unsupported: return .unsupported
            case .checking, .temporarilyUnavailable: return .unconfirmed
            }
        }
        private mutating func finish(_ id: String, _ outcome: Outcome) -> [Effect] {
            guard var launch = launches[id], launch.outcome == nil else { return [] }
            launch.outcome = outcome
            launches[id] = launch
            if var request = requests[launch.request] {
                switch outcome {
                case .failed: request.phase = .failed
                case .unconfirmed: request.phase = .uncertain
                case .cancelled: request.phase = .cancelled
                case .confirmedStarted, .finishedWithoutWindow: request.phase = .completed
                }
                request.outcome = outcome
                requests[request.id] = request
            }
            return [.observationCompleted(id, outcome)]
        }
        @discardableResult mutating func reduce(_ event: Event) -> [Effect] {
            guard phase != .terminated else { return [] }
            var effects: [Effect] = []
            switch event {
            case .visibleUI(let visible):
                guard phase == .active else { return [] }
                visibleUI = visible
            case .ingressPending(let pending):
                guard phase == .active else { return [] }
                ingressPending = pending
            case .restoring(let pending):
                guard phase == .active else { return [] }
                restoring = pending
            case .journalRequest(let incoming, let version):
                guard journalVersions[incoming.id].map({ version > $0 }) ?? true,
                      requests[incoming.id].map({ $0.digest == incoming.digest }) ?? true else { return [] }
                let previous = requests[incoming.id]
                var request = Request(id: incoming.id, digest: incoming.digest,
                    environment: previous?.environment ?? incoming.environment, phase: incoming.phase,
                    launch: incoming.launch ?? previous?.launch, outcome: incoming.outcome)
                // The current observer owns its bounded outcome; a later native
                // receipt must not regress or restart that observation.
                if let launch = request.launch.flatMap({ launches[$0] }), let previous,
                   launch.request == incoming.id {
                    request.phase = previous.phase; request.outcome = previous.outcome
                }
                if phase != .active {
                    if [.queued, .submitted].contains(request.phase) { request.phase = .awaitingUserResume }
                    else if [.dispatching, .observing].contains(request.phase) { request.phase = .uncertain }
                }
                requests[incoming.id] = request; journalVersions[incoming.id] = version
            case .recoveredLaunch(let stamp, let id, var launch, let root):
                guard accepts(stamp), environments[stamp.environment]?.existence == .alive,
                      environments[stamp.environment]?.health == .healthy, let request = requests[id],
                      [.completed, .failed, .uncertain].contains(request.phase), request.launch == launch.id,
                      request.environment == nil || request.environment == stamp.environment,
                      launch.request == id, launch.environment == stamp.environment, launches[launch.id] == nil,
                      processes[root].map({ $0.launch == nil && $0.ownership == nil && $0.environment == stamp.environment && $0.existence != .exited }) ?? true,
                      !exitedProcesses.contains(.init(environment: stamp.environment, process: root)) else { return [] }
                launch.deadline = 0; launch.outcome = request.outcome ?? .unconfirmed
                launch.processes = [root]
                launches[launch.id] = launch; launchStamps[launch.id] = stamp
                requests[id] = Request(id: request.id, digest: request.digest, environment: stamp.environment,
                    phase: request.phase, launch: request.launch, outcome: request.outcome)
                processes[root] = .init(id: root, name: launch.name, environment: stamp.environment,
                    launch: launch.id, ownership: .rootReceipt, existence: .alive)
                effects = [.restoreObservation(stamp, id)]
            case .manage(let environment):
                guard phase == .active else { return [] }
                if let previous = environments[environment.id] {
                    guard environment.generation > previous.generation else { return [] }
                    // A new execution generation invalidates all old window capabilities.
                    processes = processes.filter { $0.value.environment != environment.id }
                    windows = windows.filter { processes[$0.key.process] != nil }
                    for id in launches.keys where launches[id]?.environment == environment.id {
                        launches[id]?.processes.removeAll()
                        // A different server cannot finish or inherit an old
                        // observation. Release it without guessing success.
                        effects += finish(id, .unconfirmed)
                    }
                }
                environments[environment.id] = environment
            case .accepted(var request):
                guard requests[request.id] == nil else { return [] }
                // Late journal completion must never cause a post-quit dispatch.
                if phase != .active && (request.phase == .queued || request.phase == .submitted) { request.phase = .awaitingUserResume }
                requests[request.id] = request
            case .dispatchCommitted(let stamp, let id, let launch):
                guard accepts(stamp), stamp.environment == launch.environment,
                      var request = requests[id], request.phase == .queued, request.environment == launch.environment,
                      launch.request == id, launches[launch.id] == nil,
                      environments[launch.environment]?.stop != .executing,
                      environments[launch.environment]?.stop != .unconfirmed else { return [] }
                request.phase = .observing
                request.launch = launch.id
                requests[id] = request
                launches[launch.id] = launch
                launchStamps[launch.id] = stamp
            case .executionAttached(let stamp, var request, let launch):
                guard accepts(stamp), request.environment == stamp.environment,
                      launch.environment == stamp.environment, launch.request == request.id,
                      request.launch == launch.id, [.dispatching, .observing].contains(request.phase),
                      !request.id.isEmpty, !request.digest.isEmpty, launches[launch.id] == nil else { return [] }
                if let previous = requests[request.id] {
                    guard previous.digest == request.digest, previous.launch == launch.id,
                          [.dispatching, .observing].contains(previous.phase),
                          previous.environment == nil || previous.environment == stamp.environment else { return [] }
                }
                request.phase = .observing
                requests[request.id] = request
                launches[launch.id] = launch
                launchStamps[launch.id] = stamp
            case .observationStarted(let stamp, let id, let deadline):
                guard accepts(stamp, includingExited: true), launchStamps[id] == stamp,
                      launches[id]?.outcome == nil, launches[id]?.deadline == .infinity,
                      deadline.isFinite else { return [] }
                launches[id]?.deadline = deadline
            case .cancellationCommitted(let id):
                guard var request = requests[id], [.submitted, .queued, .awaitingUserResume].contains(request.phase) else { return [] }
                request.phase = .cancelled
                request.outcome = .cancelled
                requests[id] = request
            case .observationFinished(let stamp, let id, let outcome):
                // A root+drain outcome can arrive after the environment exit
                // event, but never after a new server generation takes over.
                guard accepts(stamp, includingExited: true), launchStamps[id] == stamp,
                      outcome != .cancelled else { return [] } // dispatch has already committed
                effects += finish(id, outcome)
            case .deadline(let now):
                guard phase == .active else { return [] }
                for launch in launches.values where launch.outcome == nil && now >= launch.deadline {
                    effects += finish(launch.id, .unconfirmed)
                }
            case .waiterStarted(let stamp, let token):
                guard accepts(stamp), environments[stamp.environment]?.waiter == nil else { return [] }
                environments[stamp.environment]?.waiter = token
            case .waiterFinished(let stamp, let token, let cancelled):
                guard accepts(stamp), environments[stamp.environment]?.waiter == token else { return [] }
                environments[stamp.environment]?.waiter = nil
                if cancelled {
                    environments[stamp.environment]?.health = .degraded
                } else if environments[stamp.environment]?.reconciliation == nil {
                    effects = [.reconcile(stamp)]
                }
            case .reconcileStarted(let stamp, let token):
                guard accepts(stamp) else { return [] }
                environments[stamp.environment]?.reconciliation = token
            case .reconciled(let stamp, let token, let existence, let health):
                guard accepts(stamp), environments[stamp.environment]?.reconciliation == token else { return [] }
                environments[stamp.environment]?.reconciliation = nil
                // The monitor has already checked executor ownership and the
                // calibration token. Pending requests retain UI separately;
                // they do not keep this drained server generation alive.
                environments[stamp.environment]?.existence = existence
                environments[stamp.environment]?.health = health
                if existence == .exited {
                    if environments[stamp.environment]?.stop != .idle { environments[stamp.environment]?.stop = .finished }
                    environments[stamp.environment]?.operation = nil
                    environments[stamp.environment]?.waiter = nil
                    for id in processes.keys where processes[id]?.environment == stamp.environment {
                        exitedProcesses.insert(.init(environment: stamp.environment, process: id))
                        processes[id]?.existence = .exited
                    }
                    windows = windows.filter { processes[$0.key.process]?.existence != .exited }
                }
            case .independentProcess(let stamp, let id, let name, let existence):
                guard accepts(stamp), id.pid > 0, id.started > 0, !id.boot.isEmpty,
                      existence != .alive || (environments[stamp.environment]?.existence == .alive && environments[stamp.environment]?.health == .healthy),
                      !exitedProcesses.contains(.init(environment: stamp.environment, process: id)),
                      processes[id].map({ $0.environment == stamp.environment && $0.launch == nil && $0.ownership == nil }) ?? true,
                      existence == .alive || processes[id] != nil else { return [] }
                var record = processes[id] ?? .init(id: id, name: name, environment: stamp.environment,
                    launch: nil, ownership: nil, existence: existence)
                record.name = name; record.existence = existence
                if record == processes[id] { return [] }
                processes[id] = record
                if existence != .alive { windows = windows.filter { $0.key.process != id } }
                if existence == .exited { exitedProcesses.insert(.init(environment: stamp.environment, process: id)) }
            case .processObserved(let stamp, var process):
                guard accepts(stamp), process.environment == stamp.environment,
                      !exitedProcesses.contains(.init(environment: stamp.environment, process: process.id)),
                      processes[process.id] == nil || processes[process.id]?.environment == stamp.environment else { return [] }
                if process.ownership == nil || process.launch.flatMap({ launchStamps[$0] }) != stamp {
                    process.launch = nil
                    process.ownership = nil
                }
                if process.windowCapability == nil { process.windowCapability = processes[process.id]?.windowCapability }
                processes[process.id] = process
                if let id = process.launch { launches[id]?.processes.insert(process.id) }
                if process.existence == .exited {
                    exitedProcesses.insert(.init(environment: stamp.environment, process: process.id))
                    windows = windows.filter { $0.key.process != process.id }
                }
            case .processExited(let stamp, let id):
                guard accepts(stamp), processes[id] == nil || processes[id]?.environment == stamp.environment else { return [] }
                exitedProcesses.insert(.init(environment: stamp.environment, process: id))
                processes[id]?.existence = .exited
                windows = windows.filter { $0.key.process != id }
            case .windowObserved(let stamp, let window):
                guard accepts(stamp), processes[window.id.process]?.environment == stamp.environment,
                      processes[window.id.process]?.existence == .alive,
                      !exitedProcesses.contains(.init(environment: stamp.environment, process: window.id.process)) else { return [] }
                windows[window.id] = window
                if let launch = processes[window.id.process]?.launch, launches[launch]?.outcome == nil {
                    effects.append(.windowConfirmed(launch))
                }
            case .windowClosed(let stamp, let id):
                guard accepts(stamp), processes[id.process]?.environment == stamp.environment else { return [] }
                windows.removeValue(forKey: id)
            case .windowSnapshot(let stamp, let process, let source, let observed, let capability):
                guard accepts(stamp), processes[process]?.environment == stamp.environment,
                      processes[process]?.existence == .alive else { return [] }
                if let observed {
                    guard observed.allSatisfy({ $0.id.process == process && $0.id.source == source }),
                          Set(observed.map(\.id)).count == observed.count else { return [] }
                }
                processes[process]?.windowCapability = capability
                if let observed {
                    windows = windows.filter { $0.key.process != process || $0.key.source != source }
                    for window in observed { windows[window.id] = window }
                } else {
                    for id in windows.keys where id.process == process && id.source == source {
                        windows[id]?.capability = capability
                        windows[id]?.focused = nil; windows[id]?.minimized = nil
                    }
                }
            case .activateWindow(let id, let operation):
                guard phase == .active else { return [] }
                if windowAction?.window == id && windowAction?.result == nil { return [] }
                var action = WindowAction(id: operation, window: id)
                if let failure = windowFailure(id) { action.result = failure }
                else if let process = processes[id.process], let stamp = stamp(for: process.environment) {
                    effects = [.activateWindow(stamp, id, operation)]
                }
                windowAction = action
            case .windowActionProgress(let operation):
                guard phase == .active, windowAction?.id == operation, windowAction?.result == nil else { return [] }
                windowAction?.showingProgress = true
            case .windowActionFinished(let operation, let result):
                guard phase == .active, windowAction?.id == operation, windowAction?.result == nil else { return [] }
                let verified = result == .shown ? (windowFailure(windowAction!.window) ?? .shown) : result
                windowAction?.result = verified
            case .dismissWindowFeedback(let operation):
                guard windowAction?.id == operation, windowAction?.result != nil else { return [] }
                windowAction = nil
            case .stopRequested(let stamp, let token):
                guard accepts(stamp), let environment = environments[stamp.environment],
                      environment.existence != .exited, environment.stop != .executing,
                      environment.stop != .unconfirmed else { return [] }
                environments[stamp.environment]?.stop = .executing
                environments[stamp.environment]?.operation = token
                effects = [.stop(stamp, token)]
            case .stopFinished(let stamp, let token, let success):
                guard accepts(stamp), environments[stamp.environment]?.operation == token else { return [] }
                environments[stamp.environment]?.operation = nil
                environments[stamp.environment]?.stop = success ? .unconfirmed : .failed
                effects = [.reconcile(stamp)] // command exit 0 is not environment exit evidence
            case .quit:
                guard phase == .active else { return [] }
                phase = .quiescing
                windowAction = nil
                restoring = false
                ingressPending = false
                for (id, request) in requests where request.phase == .queued || request.phase == .submitted {
                    requests[id]?.phase = .awaitingUserResume
                }
                effects = [.persistQuiescing, .cancelOwnedObservers]
            case .terminated:
                guard phase == .quiescing else { return [] }
                phase = .terminated
            }
            // Revoke pending capabilities in the same state transaction as a
            // close/exit/generation change, before a late OS success can arrive.
            if let action = windowAction, action.result == nil, let failure = windowFailure(action.window) {
                windowAction?.result = failure
            }
            revision &+= 1
            return effects
        }
    }
}

/// Single writer. A blocked observer or journal must never occupy this queue.
final class CyderLifecycleStore {
    private let queue = DispatchQueue(label: "local.cyder.lifecycle-state")
    private var state: CyderLifecycle.State
    private let delivery: DispatchQueue
    private let consume: (CyderLifecycle.Snapshot, [CyderLifecycle.Effect]) -> Void
    init(epoch: UUID = UUID(), delivery: DispatchQueue = .main,
         consume: @escaping (CyderLifecycle.Snapshot, [CyderLifecycle.Effect]) -> Void) {
        state = CyderLifecycle.State(epoch: epoch)
        self.delivery = delivery
        self.consume = consume
    }
    func send(_ event: CyderLifecycle.Event) {
        send([event])
    }
    /// One evidence batch yields one UI snapshot, preserving event order and
    /// every effect without copying the growing model once per scanned PID.
    func send(_ events: [CyderLifecycle.Event]) {
        guard !events.isEmpty else { return }
        queue.async { [self] in
            var effects: [CyderLifecycle.Effect] = []
            for event in events { effects += state.reduce(event) }
            let snapshot = state.snapshot
            delivery.async { [consume] in consume(snapshot, effects) }
        }
    }
}
