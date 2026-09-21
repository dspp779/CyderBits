import Foundation

/// Owns native subprocess lifetime independently from a caller's observation.
/// Deadline/cancellation may release an observation but never turns an unknown
/// launch into failure or kills its supervisor. Mutation ownership lasts until
/// the actual child exits, even after its caller's observation completes.
final class CyderProcessRunner {
    enum Policy { case observation, launch, mutation }
    enum Outcome: Equatable {
        case exited(Int32, signalled: Bool)
        case failedToStart(String)
        case unconfirmed
        case cancelledBeforeSpawn
    }
    struct Receipt { let operation: UUID; let supervisorPID: Int32 }
    private final class Operation {
        let id: UUID
        let process: Process
        let policy: Policy
        let output: FileHandle?
        let completion: (Outcome) -> Void
        let released: () -> Void
        let expiresAt: TimeInterval?
        var starting = false
        var runReturned = false
        var exitOutcome: Outcome?
        var delivered = false
        var spawned = false
        var finished = false
        init(id: UUID, process: Process, policy: Policy, output: FileHandle?,
             completion: @escaping (Outcome) -> Void, released: @escaping () -> Void, expiresAt: TimeInterval?) {
            self.id = id; self.process = process; self.policy = policy; self.output = output
            self.completion = completion; self.released = released; self.expiresAt = expiresAt
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.process-runner")
    private let delivery: DispatchQueue
    private let spawnWorkers: OperationQueue
    private let beforeSpawn: () -> Void
    private var operations: [UUID: Operation] = [:]
    private var quiescing = false
    init(delivery: DispatchQueue = .main, beforeSpawn: @escaping () -> Void = {}) {
        self.delivery = delivery; self.beforeSpawn = beforeSpawn
        spawnWorkers = OperationQueue()
        spawnWorkers.name = "local.cyder.process-spawn"
        spawnWorkers.maxConcurrentOperationCount = 2
        spawnWorkers.qualityOfService = .userInitiated
    }

    @discardableResult
    func run(process: Process, policy: Policy, deadline: TimeInterval? = nil,
             output: FileHandle? = nil, onSpawn: @escaping (Receipt) -> Void = { _ in },
             onRelease: @escaping () -> Void = {}, completion: @escaping (Outcome) -> Void) -> UUID {
        let id = UUID(), expiresAt = deadline.map { ProcessInfo.processInfo.systemUptime + max(0, $0) }
        queue.async { [self] in
            let operation = Operation(id: id, process: process, policy: policy, output: output,
                                      completion: completion, released: onRelease, expiresAt: expiresAt)
            guard !quiescing else {
                try? output?.close()
                delivery.async { completion(.cancelledBeforeSpawn); onRelease() }
                return
            }
            guard operations.count < 32 else {
                try? output?.close()
                delivery.async { completion(.failedToStart("Native operation capacity reached")); onRelease() }
                return
            }
            operations[id] = operation // register owner before Process.run can exit
            process.terminationHandler = { [weak self, weak operation] process in
                guard let self, let operation else { return }
                let outcome = Outcome.exited(process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
                self.queue.async {
                    operation.exitOutcome = outcome
                    // A fast child can exit before Process.run returns. Keep
                    // its output and owner until the spawn call also returns.
                    if operation.runReturned { self.finish(operation, outcome: outcome) }
                }
            }
            if let expiresAt {
                queue.asyncAfter(deadline: .now() + max(0, expiresAt - ProcessInfo.processInfo.systemUptime)) { [weak self, weak operation] in
                    guard let self, let operation, !operation.finished else { return }
                    self.abandonObservation(operation)
                }
            }
            // An OS spawn call may stall. It never occupies the state queue,
            // and only two physical calls may be in flight, even after timeout.
            spawnWorkers.addOperation { [self] in
                let claimed = queue.sync { () -> Bool in
                    guard !operation.finished, !quiescing else { return false }
                    operation.starting = true
                    return true
                }
                guard claimed else { return }
                beforeSpawn()
                do {
                    try process.run()
                    let receipt = Receipt(operation: id, supervisorPID: process.processIdentifier)
                    queue.async {
                        operation.runReturned = true; operation.spawned = true
                        self.delivery.async { onSpawn(receipt) }
                        if let outcome = operation.exitOutcome { self.finish(operation, outcome: outcome) }
                        else if operation.delivered { self.stopOwnedObserver(operation) }
                    }
                } catch {
                    let message = error.localizedDescription
                    queue.async {
                        operation.runReturned = true
                        self.finish(operation, outcome: .failedToStart(message))
                    }
                }
            }
        }
        return id
    }
    func run(process: Process, policy: Policy, deadline: TimeInterval? = nil,
             output: FileHandle? = nil, onSpawn: @escaping (Receipt) -> Void = { _ in },
             onRelease: @escaping () -> Void = {}) async -> Outcome {
        await withCheckedContinuation { continuation in
            run(process: process, policy: policy, deadline: deadline, output: output,
                onSpawn: onSpawn, onRelease: onRelease) { continuation.resume(returning: $0) }
        }
    }
    func cancelObservation(_ id: UUID) {
        queue.async { [self] in
            if let operation = operations[id] { abandonObservation(operation) }
        }
    }
    func quiesce() {
        queue.async { [self] in
            quiescing = true
            for operation in Array(operations.values) {
                if operation.starting { abandonObservation(operation) }
                else { finish(operation, outcome: .cancelledBeforeSpawn) }
            }
        }
    }
    func inspect(completion: @escaping (Int) -> Void) {
        queue.async { [self] in let count = operations.count; delivery.async { completion(count) } }
    }
    private func abandonObservation(_ operation: Operation) {
        guard !operation.finished else { return }
        deliver(operation, .unconfirmed)
        stopOwnedObserver(operation)
        // Launch/mutation processes, their output descriptors and onRelease
        // remain owned here until terminationHandler confirms actual exit.
    }
    private func stopOwnedObserver(_ operation: Operation) {
        if operation.policy == .observation, operation.spawned, operation.process.isRunning {
            operation.process.terminate() // exclusively this runner's observer
        }
    }
    private func deliver(_ operation: Operation, _ outcome: Outcome) {
        guard !operation.delivered else { return }
        operation.delivered = true
        delivery.async { operation.completion(outcome) }
    }
    private func finish(_ operation: Operation, outcome: Outcome) {
        guard !operation.finished else { return }
        operation.finished = true
        try? operation.output?.close()
        operation.process.terminationHandler = nil
        // A delayed timer is not an extension of the observation budget.
        // The actual exit still releases ownership exactly once.
        let expired = operation.expiresAt.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
        deliver(operation, expired && outcome != .cancelledBeforeSpawn ? .unconfirmed : outcome)
        operations.removeValue(forKey: operation.id)
        delivery.async { operation.released() }
    }
}
