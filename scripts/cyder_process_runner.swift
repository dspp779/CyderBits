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
        var delivered = false
        var spawned = false
        var finished = false
        init(id: UUID, process: Process, policy: Policy, output: FileHandle?,
             completion: @escaping (Outcome) -> Void, released: @escaping () -> Void) {
            self.id = id; self.process = process; self.policy = policy; self.output = output
            self.completion = completion; self.released = released
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.process-runner")
    private let delivery: DispatchQueue
    private var operations: [UUID: Operation] = [:]
    private var quiescing = false
    init(delivery: DispatchQueue = .main) { self.delivery = delivery }

    @discardableResult
    func run(process: Process, policy: Policy, deadline: TimeInterval? = nil,
             output: FileHandle? = nil, onSpawn: @escaping (Receipt) -> Void = { _ in },
             onRelease: @escaping () -> Void = {}, completion: @escaping (Outcome) -> Void) -> UUID {
        let id = UUID()
        queue.async { [self] in
            let operation = Operation(id: id, process: process, policy: policy, output: output,
                                      completion: completion, released: onRelease)
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
                self.queue.async {
                    self.finish(operation, outcome: .exited(process.terminationStatus,
                        signalled: process.terminationReason == .uncaughtSignal))
                }
            }
            do {
                try process.run()
                operation.spawned = true
                let receipt = Receipt(operation: id, supervisorPID: process.processIdentifier)
                delivery.async { onSpawn(receipt) }
            } catch {
                finish(operation, outcome: .failedToStart(error.localizedDescription))
                return
            }
            if let deadline {
                queue.asyncAfter(deadline: .now() + max(0, deadline)) { [weak self, weak operation] in
                    guard let self, let operation, !operation.finished else { return }
                    self.abandonObservation(operation)
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
            for operation in operations.values { abandonObservation(operation) }
        }
    }
    func inspect(completion: @escaping (Int) -> Void) {
        queue.async { [self] in let count = operations.count; delivery.async { completion(count) } }
    }
    private func abandonObservation(_ operation: Operation) {
        guard !operation.finished else { return }
        deliver(operation, .unconfirmed)
        if operation.policy == .observation, operation.process.isRunning {
            operation.process.terminate() // exclusively this runner's observer
        }
        // Launch/mutation processes, their output descriptors and onRelease
        // remain owned here until terminationHandler confirms actual exit.
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
        deliver(operation, outcome)
        operations.removeValue(forKey: operation.id)
        delivery.async { operation.released() }
    }
}
