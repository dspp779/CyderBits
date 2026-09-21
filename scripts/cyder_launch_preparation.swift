import Foundation

/// Bounded read-only launch preflight. Physical workers are retained after a
/// deadline/cancel until they really return. Results are delivered in accepted
/// order, but a stuck earlier read can hold that order only until its deadline.
final class CyderLaunchPreparation<Value> {
    enum Outcome { case resolved(Value), unconfirmed, cancelled }
    private final class Work {
        let id = UUID()
        let body: () -> Value
        let completion: (Outcome) -> Void
        let expiresAt: TimeInterval
        var started = false
        var outcome: Outcome?
        init(deadline: TimeInterval, body: @escaping () -> Value, completion: @escaping (Outcome) -> Void) {
            self.body = body; self.completion = completion
            expiresAt = ProcessInfo.processInfo.systemUptime + max(0, deadline)
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.launch-preparation-state")
    private let worker = DispatchQueue(label: "local.cyder.launch-preparation-io", qos: .userInitiated, attributes: .concurrent)
    private let delivery: DispatchQueue
    private var ordered: [Work] = []
    private var active = 0
    private var closed = false
    init(delivery: DispatchQueue = .main) { self.delivery = delivery }
    @discardableResult
    func resolve(deadline: TimeInterval = 5, work: @escaping () -> Value, completion: @escaping (Outcome) -> Void) -> UUID {
        let item = Work(deadline: deadline, body: work, completion: completion)
        queue.async { [self] in
            guard !closed else { delivery.async { completion(.cancelled) }; return }
            guard ordered.count < 512 else { delivery.async { completion(.unconfirmed) }; return }
            ordered.append(item)
            queue.asyncAfter(deadline: .now() + max(0, item.expiresAt - ProcessInfo.processInfo.systemUptime)) { [weak self, weak item] in
                guard let self, let item, item.outcome == nil else { return }
                item.outcome = .unconfirmed
                self.deliverReady()
                self.startReady()
            }
            startReady()
        }
        return item.id
    }
    func cancel(_ id: UUID) {
        queue.async { [self] in
            if let item = ordered.first(where: { $0.id == id }), item.outcome == nil { item.outcome = .cancelled }
            deliverReady(); startReady()
        }
    }
    func quiesce() {
        queue.async { [self] in
            closed = true
            for item in ordered { item.outcome = .cancelled }
            deliverReady()
        }
    }
    private func startReady() {
        guard !closed else { return }
        for item in ordered where !item.started && item.outcome == nil {
            if ProcessInfo.processInfo.systemUptime >= item.expiresAt { item.outcome = .unconfirmed; continue }
            guard active < 2 else { break }
            active += 1; item.started = true
            worker.async { [self] in
                let value = item.body()
                queue.async {
                    self.active -= 1
                    if item.outcome == nil {
                        item.outcome = ProcessInfo.processInfo.systemUptime >= item.expiresAt ? .unconfirmed : .resolved(value)
                    }
                    self.deliverReady(); self.startReady()
                }
            }
        }
        deliverReady()
    }
    private func deliverReady() {
        while let item = ordered.first, let outcome = item.outcome {
            ordered.removeFirst()
            delivery.async { item.completion(outcome) }
        }
    }
}
