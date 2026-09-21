import Foundation
import Darwin

/// Native scope evidence, never evidence of a launch relationship. All reads
/// run off the UI/state queues. No environment/argv dumps are retained or logged.
enum CyderProcessInventory {
    typealias L = CyderLifecycle
    struct Metadata: Equatable { let prefix: String; let name: String }
    struct Match: Equatable { let process: L.ProcessID; let environment: L.EnvironmentID; let name: String }
    struct Reading { let presence: CyderProcessEvidence.Presence; let match: Match? }
    static func pids() -> [Int32] {
        precondition(!Thread.isMainThread)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        // A truncated/failed inventory is not proof of anyone's exit.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: 4096)
        var size = entries.count * MemoryLayout<kinfo_proc>.stride
        let result = entries.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size <= entries.count * MemoryLayout<kinfo_proc>.stride else { return [] }
        return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }
    static func parse(_ bytes: [UInt8]) -> Metadata? {
        guard bytes.count > 4, bytes.count <= 2 * 1024 * 1024 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes.prefix(4)) }
        guard argc > 0, argc <= 4096 else { return nil }
        var offset = 4
        func string() -> ArraySlice<UInt8>? {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { return nil }
            let value = bytes[start..<offset]; offset += 1; return value
        }
        guard let executable = string(), !executable.isEmpty else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var name: String?
        for _ in 0..<argc {
            guard let raw = string() else { return nil }
            if name == nil, let argument = String(bytes: raw, encoding: .utf8), argument.lowercased().hasSuffix(".exe") {
                let leaf = argument.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
                let clean = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
                if !clean.isEmpty { name = clean }
            }
        }
        var prefix: String?
        var count = 0
        while offset < bytes.count && bytes[offset] != 0 {
            count += 1
            guard count <= 4096, let raw = string() else { return nil }
            let key = Array("WINEPREFIX=".utf8)
            if raw.starts(with: key) {
                guard prefix == nil, let value = String(bytes: raw.dropFirst(key.count), encoding: .utf8),
                      value.hasPrefix("/"), value.utf8.count < 4096 else { return nil }
                prefix = value
            }
        }
        guard let prefix else { return nil } // CX_BOTTLE alone is not an absolute prefix identity.
        return .init(prefix: prefix, name: name ?? "Windows 程序")
    }
    static func metadata(_ pid: Int32) -> Metadata? {
        precondition(!Thread.isMainThread)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard bytes.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0,
              size <= bytes.count else { return nil }
        return parse(Array(bytes.prefix(size)))
    }
    static func image(_ pid: Int32) -> String? {
        precondition(!Thread.isMainThread)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    }
    static func prefixID(_ prefix: String) -> L.EnvironmentID? {
        precondition(!Thread.isMainThread)
        var info = stat()
        guard prefix.hasPrefix("/"), stat(prefix, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return .init(uid: info.st_uid, device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino, namespace: "wine-user")
    }
    static func trusted(_ image: String, engine: String) -> Bool {
        precondition(!Thread.isMainThread)
        let suffix = "/bin/wineserver"
        guard engine.hasPrefix("/"), engine.hasSuffix(suffix) else { return false }
        let root = String(engine.dropLast(suffix.count))
        let paths = ["bin/wine", "bin/wine64", "bin/wine-preloader", "bin/wine64-preloader",
                     "lib/wine/x86_64-unix/wine", "lib/wine/i386-unix/wine", "lib/wine/aarch64-unix/wine"]
        // The monitor supplied a canonical server path. Keep the allowlist
        // lexical: resolving every environment here would let one unavailable
        // mount stall both workers even while inspecting unrelated PIDs.
        return paths.contains { root + "/" + $0 == image }
    }
    static func read(_ pid: Int32, environments: [L.Environment]) -> Reading {
        precondition(!Thread.isMainThread)
        let presence = CyderProcessEvidence.inspect(pid)
        guard case .live(let node) = presence, let executable = image(pid) else { return .init(presence: presence, match: nil) }
        let candidates = environments.filter { $0.id.uid == getuid() && $0.id.namespace == "wine-user" && trusted(executable, engine: $0.engine) }
        // Do not read arbitrary other applications' arguments/environment.
        guard !candidates.isEmpty, let data = metadata(pid), let scope = prefixID(data.prefix),
              let environment = candidates.first(where: { $0.id == scope }),
              prefixID(environment.prefix) == scope, prefixID(data.prefix) == scope,
              image(pid) == executable, CyderProcessEvidence.live(node.id) else { return .init(presence: presence, match: nil) }
        return .init(presence: presence, match: .init(process: node.id, environment: scope, name: data.name))
    }
}

/// Bounded discovery supplements native launch trees, including reparented,
/// headless clients. It can create only independent records, never launch owners.
final class CyderIndependentProcesses {
    typealias L = CyderLifecycle
    struct Driver {
        let pids: () -> [Int32]
        let read: (Int32, [L.Environment]) -> CyderProcessInventory.Reading
        let observeExits: Bool
        static let system = Driver(pids: CyderProcessInventory.pids, read: CyderProcessInventory.read, observeExits: true)
    }
    private struct Job { let token: UUID; let stamps: [L.EnvironmentID: L.Stamp]; var expired = false }
    private let queue = DispatchQueue(label: "local.cyder.independent-state")
    private let workers = DispatchQueue(label: "local.cyder.independent-read", qos: .utility, attributes: .concurrent)
    private let driver: Driver
    private let event: (L.Event) -> Void
    private var snapshot: L.Snapshot?
    private var timer: DispatchSourceTimer?
    private var inventoryRunning = false
    private var pending: [Int32] = []
    private var jobs: [Int32: Job] = [:]
    private var sources: [L.ProcessID: DispatchSourceProcess] = [:]
    private var closed = false
    init(driver: Driver = .system, event: @escaping (L.Event) -> Void) { self.driver = driver; self.event = event }
    func update(_ snapshot: L.Snapshot) {
        queue.async { [self] in
            guard !closed else { return }
            let oldScopes = self.snapshot.map { scopes($0) } ?? [:]
            self.snapshot = snapshot
            guard snapshot.phase == .active else { close(); return }
            let currentScopes = scopes(snapshot)
            for process in snapshot.processes.values where process.launch == nil && process.existence == .alive {
                if oldScopes[process.environment] != nil, currentScopes[process.environment] == nil,
                   let environment = snapshot.environments[process.environment], environment.existence != .exited {
                    event(.independentProcess(.init(epoch: snapshot.epoch, environment: environment.id, generation: environment.generation),
                        process.id, name: process.name, existence: .unconfirmed))
                }
            }
            synchronizeSources()
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 3, repeating: 3)
                timer.setEventHandler { [weak self] in self?.refreshOnQueue() }
                self.timer = timer; timer.resume()
            }
            if oldScopes != scopes(snapshot) { refreshOnQueue() }
        }
    }
    func refresh() { queue.async { [self] in refreshOnQueue() } }
    func stop() { queue.async { [self] in close() } }
    private func close() {
        closed = true; timer?.cancel(); timer = nil; pending.removeAll()
        for source in sources.values { source.cancel() }; sources.removeAll()
    }
    private func scopes(_ snapshot: L.Snapshot) -> [L.EnvironmentID: L.Stamp] {
        Dictionary(uniqueKeysWithValues: snapshot.environments.values.filter {
            $0.id.namespace == "wine-user" && $0.existence == .alive && $0.health == .healthy
        }.map { ($0.id, .init(epoch: snapshot.epoch, environment: $0.id, generation: $0.generation)) })
    }
    private func enqueue(_ pids: [Int32]) {
        var seen = Set(pending).union(jobs.keys)
        for pid in pids where pid > 0 && seen.insert(pid).inserted {
            if pending.count >= 4096 { break }; pending.append(pid)
        }
    }
    private func refreshOnQueue() {
        guard !closed, let snapshot, !scopes(snapshot).isEmpty else { return }
        // Inventory omissions never remove a known process. Explicit reads of
        // known births continue even when the inventory is unavailable/truncated.
        enqueue(snapshot.processes.values.filter { $0.launch == nil && $0.existence != .exited }.map { $0.id.pid })
        schedule()
        guard !inventoryRunning else { return }
        inventoryRunning = true
        workers.async { [self] in
            let pids = driver.pids()
            queue.async {
                self.inventoryRunning = false
                guard !self.closed else { return }
                self.enqueue(Array(pids.prefix(4096))); self.schedule()
            }
        }
    }
    private func schedule() {
        guard !closed, let snapshot else { return }
        let stamps = scopes(snapshot)
        guard !stamps.isEmpty else { pending.removeAll(); return }
        let environments = snapshot.environments.values.filter { stamps[$0.id] != nil }
        while jobs.count < 2 && !pending.isEmpty {
            let pid = pending.removeFirst(), token = UUID()
            jobs[pid] = .init(token: token, stamps: stamps)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.jobs[pid]?.token == token else { return }
                self.jobs[pid]?.expired = true
                self.unknown(pid, stamps: stamps) // keep the occupied physical slot
            }
            workers.async { [self] in
                let needed = queue.sync {
                    !closed && jobs[pid]?.token == token && self.snapshot.map { latest in
                        let current = scopes(latest)
                        return stamps.contains { current[$0.key] == $0.value }
                    } == true
                }
                let reading = needed ? driver.read(pid, Array(environments)) : nil
                queue.async {
                    guard let job = self.jobs.removeValue(forKey: pid), job.token == token else { return }
                    if !self.closed, !job.expired, let reading { self.consume(pid, reading, stamps: stamps) }
                    self.schedule()
                }
            }
        }
    }
    private func unknown(_ pid: Int32, stamps: [L.EnvironmentID: L.Stamp]) {
        guard !closed, let snapshot else { return }
        for process in snapshot.processes.values where process.id.pid == pid && process.launch == nil && process.existence != .exited {
            if let stamp = stamps[process.environment], scopes(snapshot)[process.environment] == stamp {
                event(.independentProcess(stamp, process.id, name: process.name, existence: .unconfirmed))
            }
        }
    }
    private func consume(_ pid: Int32, _ reading: CyderProcessInventory.Reading, stamps: [L.EnvironmentID: L.Stamp]) {
        guard let snapshot else { return }
        let current = scopes(snapshot)
        for process in snapshot.processes.values where process.id.pid == pid && process.launch == nil && process.existence != .exited {
            guard let stamp = stamps[process.environment], current[process.environment] == stamp else { continue }
            let ended: Bool
            switch reading.presence {
            case .absent: ended = true
            case .live(let node): ended = node.id != process.id
            case .unavailable: ended = false
            }
            if ended { event(.independentProcess(stamp, process.id, name: process.name, existence: .exited)) }
            else if reading.match?.process != process.id || reading.match?.environment != process.environment {
                event(.independentProcess(stamp, process.id, name: process.name, existence: .unconfirmed))
            }
        }
        if let match = reading.match, case .live(let node) = reading.presence, node.id == match.process,
           let stamp = stamps[match.environment], current[match.environment] == stamp {
            event(.independentProcess(stamp, match.process, name: match.name, existence: .alive))
        }
    }
    private func synchronizeSources() {
        guard driver.observeExits, let snapshot else { return }
        let live = Set(snapshot.processes.values.filter { $0.launch == nil && $0.existence != .exited }.map(\.id))
        for id in sources.keys where !live.contains(id) { sources.removeValue(forKey: id)?.cancel() }
        for id in live where sources[id] == nil && sources.count < 1024 {
            let source = DispatchSource.makeProcessSource(identifier: id.pid, eventMask: [.exit, .exec], queue: queue)
            // Notification is only a hint: verify the full birth on a worker.
            source.setEventHandler { [weak self] in self?.enqueue([id.pid]); self?.schedule() }
            sources[id] = source; source.resume()
        }
    }
}
