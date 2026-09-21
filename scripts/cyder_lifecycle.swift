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
        let deadline: TimeInterval // monotonic; never reset by root exit
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
    }
    struct Window: Equatable {
        let id: WindowID
        var title: String
        var capability: Capability
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
        let environments: [EnvironmentID: Environment]
        let requests: [String: Request]
        let launches: [String: Launch]
        let processes: [ProcessID: ProcessRecord]
        let windows: [WindowID: Window]
        var hasActiveWork: Bool { ingressPending || requests.values.contains { $0.phase.isActive } }
        var hasEnvironment: Bool { environments.values.contains { $0.existence != .exited } }
        var keepStatusItem: Bool { phase == .active && (visibleUI || hasActiveWork || hasEnvironment) }
        var canAutoTerminate: Bool { phase == .active && !keepStatusItem }
    }
    enum Event {
        case visibleUI(Bool)
        case ingressPending(Bool)
        case manage(Environment)
        case accepted(Request) // emitted only after durable acceptance
        case dispatchCommitted(request: String, launch: Launch)
        case cancellationCommitted(request: String)
        case observationFinished(launch: String, outcome: Outcome)
        case deadline(TimeInterval)
        case waiterStarted(Stamp, UUID)
        case waiterFinished(Stamp, UUID, cancelled: Bool)
        case reconcileStarted(Stamp, UUID)
        case reconciled(Stamp, UUID, Existence, Health)
        case processObserved(Stamp, ProcessRecord)
        case processExited(Stamp, ProcessID)
        case windowObserved(Stamp, Window)
        case windowClosed(Stamp, WindowID)
        case stopRequested(Stamp, UUID)
        case stopFinished(Stamp, UUID, success: Bool)
        case quit
        case terminated
    }
    enum Effect: Equatable {
        case reconcile(Stamp)
        case stop(Stamp, UUID)
        case observationCompleted(String, Outcome)
        case persistQuiescing
        case cancelOwnedObservers
    }
    struct State {
        let epoch: UUID
        private(set) var revision: UInt64 = 0
        private(set) var phase: Phase = .active
        private(set) var visibleUI = false
        private(set) var ingressPending = false
        private(set) var environments: [EnvironmentID: Environment] = [:]
        private(set) var requests: [String: Request] = [:]
        private(set) var launches: [String: Launch] = [:]
        private(set) var processes: [ProcessID: ProcessRecord] = [:]
        private(set) var windows: [WindowID: Window] = [:]
        // Tombstones prevent an older scan from resurrecting the same process instance.
        private var exitedProcesses: Set<ProcessID> = []
        init(epoch: UUID = UUID()) { self.epoch = epoch }
        var snapshot: Snapshot {
            Snapshot(epoch: epoch, revision: revision, phase: phase, visibleUI: visibleUI,
                     ingressPending: ingressPending, environments: environments, requests: requests,
                     launches: launches, processes: processes, windows: windows)
        }
        func stamp(for id: EnvironmentID) -> Stamp? {
            guard let environment = environments[id] else { return nil }
            return Stamp(epoch: epoch, environment: id, generation: environment.generation)
        }
        private func accepts(_ stamp: Stamp) -> Bool {
            phase == .active && stamp.epoch == epoch && environments[stamp.environment]?.generation == stamp.generation
        }
        private mutating func finish(_ id: String, _ outcome: Outcome) -> [Effect] {
            guard var launch = launches[id], launch.outcome == nil else { return [] }
            launch.outcome = outcome
            launches[id] = launch
            if var request = requests[launch.request] {
                request.phase = outcome == .failed ? .failed : .completed
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
            case .manage(let environment):
                guard phase == .active else { return [] }
                if let previous = environments[environment.id] {
                    guard environment.generation > previous.generation else { return [] }
                    // A new execution generation invalidates all old window capabilities.
                    processes = processes.filter { $0.value.environment != environment.id }
                    windows = windows.filter { processes[$0.key.process] != nil }
                }
                environments[environment.id] = environment
            case .accepted(var request):
                guard requests[request.id] == nil else { return [] }
                // Late journal completion must never cause a post-quit dispatch.
                if phase != .active && (request.phase == .queued || request.phase == .submitted) { request.phase = .awaitingUserResume }
                requests[request.id] = request
            case .dispatchCommitted(let id, let launch):
                guard phase == .active, var request = requests[id], request.phase == .queued,
                      environments[launch.environment] != nil, request.environment == launch.environment,
                      launch.request == id, launches[launch.id] == nil,
                      environments[launch.environment]?.stop != .executing,
                      environments[launch.environment]?.stop != .unconfirmed else { return [] }
                request.phase = .observing
                request.launch = launch.id
                requests[id] = request
                launches[launch.id] = launch
            case .cancellationCommitted(let id):
                guard var request = requests[id], [.submitted, .queued, .awaitingUserResume].contains(request.phase) else { return [] }
                request.phase = .cancelled
                request.outcome = .cancelled
                requests[id] = request
            case .observationFinished(let id, let outcome):
                guard phase == .active else { return [] }
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
                // An empty observation while dispatch is pending cannot prove its future environment ended.
                let pending = requests.values.contains { $0.environment == stamp.environment && $0.phase.isActive }
                if existence != .exited || !pending { environments[stamp.environment]?.existence = existence }
                environments[stamp.environment]?.health = health
                if existence == .exited && !pending {
                    if environments[stamp.environment]?.stop != .idle { environments[stamp.environment]?.stop = .finished }
                    environments[stamp.environment]?.operation = nil
                    for id in processes.keys where processes[id]?.environment == stamp.environment {
                        exitedProcesses.insert(id)
                        processes[id]?.existence = .exited
                    }
                    windows = windows.filter { processes[$0.key.process]?.existence != .exited }
                }
            case .processObserved(let stamp, var process):
                guard accepts(stamp), process.environment == stamp.environment, !exitedProcesses.contains(process.id) else { return [] }
                if process.ownership == nil || process.launch.flatMap({ launches[$0]?.environment }) != stamp.environment {
                    process.launch = nil
                    process.ownership = nil
                }
                processes[process.id] = process
                if let id = process.launch { launches[id]?.processes.insert(process.id) }
            case .processExited(let stamp, let id):
                guard accepts(stamp) else { return [] }
                exitedProcesses.insert(id)
                processes[id]?.existence = .exited
                windows = windows.filter { $0.key.process != id }
            case .windowObserved(let stamp, let window):
                guard accepts(stamp), processes[window.id.process]?.environment == stamp.environment,
                      processes[window.id.process]?.existence == .alive, !exitedProcesses.contains(window.id.process) else { return [] }
                windows[window.id] = window
            case .windowClosed(let stamp, let id):
                guard accepts(stamp) else { return [] }
                windows.removeValue(forKey: id)
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
                ingressPending = false
                for (id, request) in requests where request.phase == .queued || request.phase == .submitted {
                    requests[id]?.phase = .awaitingUserResume
                }
                effects = [.persistQuiescing, .cancelOwnedObservers]
            case .terminated:
                guard phase == .quiescing else { return [] }
                phase = .terminated
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
        queue.async { [self] in
            let effects = state.reduce(event)
            let snapshot = state.snapshot
            delivery.async { [consume] in consume(snapshot, effects) }
        }
    }
}
