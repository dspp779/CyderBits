import Foundation
import Darwin

/// Supplements the private environment journal using only Cyder's own bottle
/// directory. Merely having a prefix on disk never creates a live environment.
final class CyderBottleRecovery {
    typealias Identity = CyderEnvironmentProbe.Identity
    typealias Owner = CyderLifecycle.ProcessID
    struct Candidate { let url: URL; let device: UInt64; let inode: UInt64 }
    private let queue = DispatchQueue(label: "local.cyder.bottle-recovery-state")
    private let workers = DispatchQueue(label: "local.cyder.bottle-recovery-read", qos: .utility, attributes: .concurrent)
    private let enumerate: () -> [Candidate]
    private let inspect: (Candidate) -> (Identity, Owner)?
    private let recovered: (Identity, Owner, TimeInterval) -> Void
    private var pending: [Candidate] = []
    private var round: UUID?
    private var inventory: UUID?
    private var inventoryExpired = false
    private var jobs: [UUID: Bool] = [:] // value is logical expiry; physical slots stay occupied
    private var closed = false
    private var completion: (() -> Void)?

    init(enumerate: @escaping () -> [Candidate], inspect: @escaping (Candidate) -> (Identity, Owner)?,
         recovered: @escaping (Identity, Owner, TimeInterval) -> Void) {
        self.enumerate = enumerate; self.inspect = inspect; self.recovered = recovered
    }
    convenience init(support: URL, engine: URL,
                     probe: @escaping (Identity) -> CyderEnvironmentProbe.Result = { CyderEnvironmentProbe.inspect($0) },
                     recovered: @escaping (Identity, Owner, TimeInterval) -> Void) {
        self.init(enumerate: { Self.candidates(support: support) },
            inspect: { Self.inspect($0, engine: engine, probe: probe) }, recovered: recovered)
    }
    static func inspect(_ candidate: Candidate, engine: URL,
                        probe: (Identity) -> CyderEnvironmentProbe.Result = { CyderEnvironmentProbe.inspect($0) }) -> (Identity, Owner)? {
        precondition(!Thread.isMainThread)
        var info = stat()
        guard lstat(candidate.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              let identity = CyderEnvironmentProbe.identify(prefix: candidate.url, engine: engine),
              identity.environment.device == candidate.device, identity.environment.inode == candidate.inode,
              case .alive(let owner) = probe(identity) else { return nil }
        return (identity, owner)
    }
    func refresh(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !closed, inventory == nil, jobs.isEmpty, pending.isEmpty else {
                DispatchQueue.main.async(execute: completion); return
            }
            self.completion = completion
            let token = UUID(); round = token; inventory = token; inventoryExpired = false
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.round == token else { return }; self.finishCompletion()
            }
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.inventory == token else { return }; self.inventoryExpired = true; self.finishCompletion()
            }
            workers.async { [self] in
                let candidates = enumerate()
                queue.async {
                    guard self.inventory == token else { return }
                    self.inventory = nil
                    guard !self.closed, !self.inventoryExpired else { self.finishCompletion(); return }
                    self.pending = Array(candidates.prefix(4096)); self.schedule()
                }
            }
        }
    }
    func stop() { queue.async { [self] in closed = true; pending.removeAll(); finishCompletion() } }
    private func finishCompletion() {
        round = nil
        if let completion { self.completion = nil; DispatchQueue.main.async(execute: completion) }
    }
    private func schedule() {
        guard !closed else { return }
        while jobs.count < 2 && !pending.isEmpty {
            let candidate = pending.removeFirst(), token = UUID(); jobs[token] = false
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.jobs[token] != nil else { return }; self.jobs[token] = true
            }
            workers.async { [self] in
                let needed = queue.sync { !closed && jobs[token] == false }
                let observedAt = ProcessInfo.processInfo.systemUptime
                let result = needed ? inspect(candidate) : nil
                queue.async {
                    guard let expired = self.jobs.removeValue(forKey: token) else { return }
                    if !self.closed, !expired, let (identity, owner) = result {
                        // The receiving monitor has its own quit fence. Delivery
                        // stays on this queue so stop cannot race a queued UI call.
                        self.recovered(identity, owner, observedAt)
                    }
                    self.schedule()
                }
            }
        }
        if jobs.isEmpty && pending.isEmpty { finishCompletion() }
    }
    static func candidates(support: URL) -> [Candidate] {
        precondition(!Thread.isMainThread)
        func trustedDirectory(_ fd: Int32) -> stat? {
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else { return nil }
            return info
        }
        let root = Darwin.open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return [] }; defer { Darwin.close(root) }
        guard trustedDirectory(root) != nil else { return [] }
        let bottles = openat(root, "bottles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard bottles >= 0 else { return [] }; defer { Darwin.close(bottles) }
        guard trustedDirectory(bottles) != nil else { return [] }
        let copy = dup(bottles)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); return [] }
        defer { closedir(directory) }
        var result: [Candidate] = [], count = 0
        while let entry = readdir(directory), count < 4096 {
            count += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard !name.hasPrefix("."), !name.isEmpty, !name.contains("/") else { continue }
            let fd = openat(bottles, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard let info = trustedDirectory(fd) else { continue }
            // Check the current directory layout without reading registry data.
            var user = stat(), system = stat(), drive = stat()
            guard fstatat(fd, "user.reg", &user, AT_SYMLINK_NOFOLLOW) == 0, user.st_mode & S_IFMT == S_IFREG,
                  fstatat(fd, "system.reg", &system, AT_SYMLINK_NOFOLLOW) == 0, system.st_mode & S_IFMT == S_IFREG,
                  fstatat(fd, "drive_c", &drive, AT_SYMLINK_NOFOLLOW) == 0, drive.st_mode & S_IFMT == S_IFDIR,
                  user.st_uid == getuid(), system.st_uid == getuid(), drive.st_uid == getuid() else { continue }
            result.append(.init(url: support.appendingPathComponent("bottles/" + name, isDirectory: true),
                device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }
}
