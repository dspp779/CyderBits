import Foundation

/// Coordinates native effects, not game lifetime. A lease remains owned until
/// the real executor releases it; observation timeout is deliberately absent.
final class CyderOperationGate {
    enum Scope: Equatable {
        case allEnvironments
        case environment(String)
        func overlaps(_ other: Scope) -> Bool {
            if case .allEnvironments = self { return true }
            if case .allEnvironments = other { return true }
            return self == other
        }
        static func prefix(_ url: URL) -> Scope {
            precondition(!Thread.isMainThread)
            return .environment(url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }
    struct Lease: Equatable { let id: UUID; let scope: Scope }
    private struct Pending { let lease: Lease; let completion: (Lease?) -> Void }
    private let queue = DispatchQueue(label: "local.cyder.operation-gate")
    private let delivery: DispatchQueue
    private var active: [UUID: Lease] = [:]
    private var pending: [Pending] = []
    private var closed = false
    init(delivery: DispatchQueue = .main) { self.delivery = delivery }

    @discardableResult
    func acquire(_ scope: Scope, completion: @escaping (Lease?) -> Void) -> UUID {
        let lease = Lease(id: UUID(), scope: scope)
        queue.async { [self] in
            guard !closed, pending.count < 512 else { delivery.async { completion(nil) }; return }
            pending.append(Pending(lease: lease, completion: completion))
            drain()
        }
        return lease.id
    }
    func acquire(_ scope: Scope) async -> Lease? {
        await withCheckedContinuation { c in acquire(scope) { c.resume(returning: $0) } }
    }
    func release(_ lease: Lease) {
        queue.async { [self] in
            guard active[lease.id] == lease else { return }
            active.removeValue(forKey: lease.id)
            drain()
        }
    }
    /// Only a still-pending acquisition can be cancelled. An issued lease is
    /// released by its owner, never revoked beneath a running mutation.
    func cancel(_ id: UUID) {
        queue.async { [self] in
            guard let index = pending.firstIndex(where: { $0.lease.id == id }) else { return }
            let item = pending.remove(at: index)
            delivery.async { item.completion(nil) }
            drain()
        }
    }
    func quiesce() {
        queue.async { [self] in
            closed = true
            let items = pending; pending.removeAll()
            for item in items { delivery.async { item.completion(nil) } }
        }
    }
    private func drain() {
        guard !closed else { return }
        var waiting: [Pending] = []
        for item in pending {
            let scope = item.lease.scope
            // Preserve ordering among conflicting operations; unrelated bottles
            // may pass a blocked one. An all-environment mutation is a barrier.
            if active.values.contains(where: { $0.scope.overlaps(scope) }) ||
                waiting.contains(where: { $0.lease.scope.overlaps(scope) }) {
                waiting.append(item)
            } else {
                active[item.lease.id] = item.lease
                delivery.async { item.completion(item.lease) }
            }
        }
        pending = waiting
    }
}
