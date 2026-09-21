import Foundation

/// Journal entries are candidates, never dispatch authority or proof of life.
/// This adapter only re-observes exact native births in calibrated environments.
final class CyderRecoveryObserver {
    typealias L = CyderLifecycle
    struct Record: Equatable {
        let version: UInt64
        let request: L.Request
        let name: String
        let root: CyderLaunchObserver.NativeRoot?
    }
    private struct Attempt: Equatable { let record: Record; let stamp: L.Stamp }
    private struct Job { let attempt: Attempt; let token: UUID; var expired = false }
    private let queue = DispatchQueue(label: "local.cyder.recovery-state")
    private let workers = DispatchQueue(label: "local.cyder.recovery-read", qos: .utility, attributes: .concurrent)
    private let inspect: (Int32) -> CyderProcessEvidence.Presence
    private let recovered: (Record, L.Stamp) -> Void
    private var records: [String: Record] = [:]
    private var snapshot: L.Snapshot?
    private var birthClaims: [L.ProcessID: Int] = [:]
    private var attempts: [String: Attempt] = [:]
    private var jobs: [String: Job] = [:]
    private var closed = false

    init(inspect: @escaping (Int32) -> CyderProcessEvidence.Presence = CyderProcessEvidence.inspect,
         recovered: @escaping (Record, L.Stamp) -> Void) { self.inspect = inspect; self.recovered = recovered }
    func update(_ records: [Record]) {
        queue.async { [self] in
            guard !closed else { return }
            for record in records {
                let id = record.request.id
                guard self.records[id].map({ record.version > $0.version && record.request.digest == $0.request.digest }) ?? true else { continue }
                self.records[id] = record
            }
            birthClaims.removeAll(keepingCapacity: true)
            for record in self.records.values {
                guard let root = record.root, root.phase == "spawned", root.authority.request == record.request.id,
                      root.authority.digest == record.request.digest, root.authority.launch == record.request.launch else { continue }
                birthClaims[.init(boot: root.boot, pid: root.pid, started: root.started), default: 0] += 1
            }
            schedule()
        }
    }
    func update(_ snapshot: L.Snapshot) {
        queue.async { [self] in
            guard !closed else { return }
            self.snapshot = snapshot
            if snapshot.phase != .active { closed = true; return }
            schedule()
        }
    }
    func refresh() { queue.async { [self] in attempts.removeAll(); schedule() } }
    func stop() { queue.async { [self] in closed = true; records.removeAll(); attempts.removeAll() } }
    private func candidate(_ record: Record) -> Attempt? {
        guard !closed, let snapshot, snapshot.phase == .active,
              [.completed, .failed, .uncertain].contains(record.request.phase),
              let root = record.root, root.phase == "spawned", root.pid > 0, root.started > 0, !root.boot.isEmpty,
              root.authority.request == record.request.id, root.authority.digest == record.request.digest,
              root.authority.launch == record.request.launch,
              birthClaims[.init(boot: root.boot, pid: root.pid, started: root.started)] == 1,
              snapshot.launches[root.authority.launch] == nil else { return nil }
        let environments = snapshot.environments.values.filter {
            $0.existence == .alive && $0.health == .healthy && $0.id.namespace == "wine-user" &&
                root.prefixScope == "\($0.id.uid):\(Int64(bitPattern: $0.id.device)):\($0.id.inode)"
        }
        guard environments.count == 1, let environment = environments.first else { return nil }
        return .init(record: record, stamp: .init(epoch: snapshot.epoch, environment: environment.id, generation: environment.generation))
    }
    private func schedule() {
        guard !closed, jobs.count < 2 else { return }
        for record in records.values.sorted(by: { $0.request.id < $1.request.id }) {
            let id = record.request.id
            guard jobs[id] == nil, let attempt = candidate(record), attempts[id] != attempt else { continue }
            attempts[id] = attempt
            let token = UUID(); jobs[id] = Job(attempt: attempt, token: token)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.jobs[id]?.token == token else { return }
                self.jobs[id]?.expired = true // retain the physical slot
            }
            workers.async { [self] in
                let needed = queue.sync { !closed && jobs[id]?.token == token && records[id] == record && candidate(record) == attempt }
                let root = record.root!
                let expected = L.ProcessID(boot: root.boot, pid: root.pid, started: root.started)
                let live: Bool
                if needed, case .live(let node) = inspect(root.pid) { live = node.id == expected } else { live = false }
                queue.async {
                    guard let job = self.jobs.removeValue(forKey: id), job.token == token else { return }
                    if live, !job.expired, !self.closed, self.records[id] == record, self.candidate(record) == attempt {
                        DispatchQueue.main.async { self.recovered(record, attempt.stamp) }
                    }
                    self.schedule()
                }
            }
            if jobs.count >= 2 { break }
        }
    }
}
