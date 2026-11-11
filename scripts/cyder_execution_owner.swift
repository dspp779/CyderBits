import Foundation
import Darwin
import CryptoKit

/// Native executor authority survives the UI process. A prepared ticket is
/// revocable; once claimed, only the executor's actual outcome releases it.
/// Arguments/environment remain in process memory, never in this ledger.
enum CyderExecutionOwner {
    enum Failure: Error { case invalid, unavailable, busy, full, revoked, processIdentityUnavailable, uncertain, ownerMissing, scopeChanged, executableChanged }
    struct Birth: Codable, Equatable {
        let boot: String
        let pid: Int32
        let started: UInt64
        static func current(_ pid: Int32 = getpid(), includingZombie: Bool = false) -> Self? {
            var info = proc_bsdinfo(), boot = [CChar](repeating: 0, count: 128)
            var size = boot.count
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
                  info.pbi_uid == getuid(), includingZombie || info.pbi_status != SZOMB,
                  sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0 else { return nil }
            return .init(boot: String(cString: boot), pid: pid, started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
        }
    }
    struct Handoff: Codable, Equatable {
        let executable: String
        let pidFile: String
        var isValid: Bool {
            executable.hasPrefix("/") && pidFile.hasPrefix("/")
                && !executable.contains("\0") && !pidFile.contains("\0")
        }
    }
    struct NativeSpawn: Codable, Equatable {
        var phase: CyderSpawnPhase
        let bridge: Birth
        var process: Birth?
        var status: Int32?
        var signalled: Bool?
        var isValid: Bool {
            guard bridge.pid > 0, bridge.started > 0, !bridge.boot.isEmpty else { return false }
            if phase.hasProcess {
                guard let process, process.pid > 0, process.started > 0, process.boot == bridge.boot else { return false }
            }
            return phase != .exited || (status != nil && signalled != nil)
        }
    }
    struct Correlation: Codable, Equatable {
        let requestID: String
        let launchID: String
        let digest: String
        var isValid: Bool {
            requestID.utf8.count <= 100 && requestID.split(separator: ":", omittingEmptySubsequences: false).count == 2
                && requestID.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { UUID(uuidString: String($0)) != nil }
                && UUID(uuidString: launchID) != nil && digest.count == 64
                && digest.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }
    struct Ticket: Codable, Equatable {
        let schema: Int
        let id: UUID
        let issuer: UUID
        let scope: String? // nil = all environments; UID/device/inode otherwise
        var prefix: String? = nil
        var phase: CyderTicketPhase
        var owner: Birth?
        var child: Birth?
        var status: Int32?
        var signalled: Bool? = nil
        var correlation: Correlation? = nil
        var handoff: Handoff? = nil
        var nativeSpawn: NativeSpawn? = nil
        // Keep the actual prefix identity for the final handoff even when
        // shared-runtime preparation requires a global mutation barrier.
        var requiresGlobalScope: Bool? = nil
        /// What the user launched, for showing a game that is still running
        /// after Cyder restarts. Tickets are the only launch state that survives.
        var displayName: String? = nil
        /// Process group of the operation: the helper makes itself a group
        /// leader before claiming and runs Bash in that group, so every process
        /// the operation started (and did not detach) is a member. Recorded
        /// before anything runs; nil only on tickets from older helpers.
        var group: Int32? = nil
        /// Why a ticket that was holding its scope was released without its
        /// helper, e.g. "abandoned" (nothing from it is still running) or
        /// "terminated" (the user stopped its leftover processes).
        var resolution: String? = nil
        var effectiveScope: String? { requiresGlobalScope == true ? nil : scope }
    }
    private final class Directory {
        let fd: Int32
        init(_ root: URL) throws {
            if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
            fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                Darwin.close(fd); throw Failure.invalid
            }
        }
        deinit { Darwin.close(fd) }
        func lock(_ name: String, exclusive: Bool = true) throws -> Int32 {
            let file = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard file >= 0 else { throw Failure.unavailable }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0 else { Darwin.close(file); throw Failure.invalid }
            guard flock(file, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                Darwin.close(file); throw Failure.busy
            }
            return file
        }
        // Only the independent executor helpers wait for a physical mutation.
        // UI observation deadlines never release this ownership.
        func waitLock(_ name: String) throws -> Int32 {
            while true {
                do { return try lock(name) }
                catch Failure.busy { usleep(100_000) }
            }
        }
        /// Waits for another helper's operation on the same scope instead of
        /// failing at once; gives up (busy) after `deadline` seconds.
        func waitLock(_ name: String, exclusive: Bool, deadline: TimeInterval) throws -> Int32 {
            let end = ProcessInfo.processInfo.systemUptime + deadline
            while true {
                do { return try lock(name, exclusive: exclusive) }
                catch Failure.busy where ProcessInfo.processInfo.systemUptime < end { usleep(100_000) }
            }
        }
        func names() throws -> [String] {
            let copy = dup(fd)
            guard copy >= 0 else { throw Failure.unavailable }
            guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Failure.unavailable }
            defer { closedir(stream) }
            rewinddir(stream)
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard name.hasSuffix(".json") else { continue }
                guard names.count < 512 else { throw Failure.full }
                names.append(name)
            }
            return names.sorted()
        }
        func read(_ name: String) throws -> Ticket {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(file) }
            var before = stat(), after = stat()
            guard fstat(file, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
                  before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= 8192 else { throw Failure.invalid }
            var data = Data(count: Int(before.st_size))
            let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            guard count == data.count, fstat(file, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  let ticket = try? JSONDecoder().decode(Ticket.self, from: data), [1, 2].contains(ticket.schema),
                  (ticket.schema == 2) == (ticket.requiresGlobalScope == true),
                  name == ticket.id.uuidString + ".json",
                  ticket.correlation?.isValid != false, ticket.handoff?.isValid != false,
                  (ticket.displayName?.count ?? 0) <= 100, ticket.group.map { $0 > 1 } != false,
                  ticket.nativeSpawn?.isValid != false,
                  (ticket.handoff == nil || ticket.scope != nil),
                  (ticket.nativeSpawn == nil || ticket.handoff != nil),
                  (ticket.phase != .handedOff || ticket.nativeSpawn?.phase.hasProcess == true) else { throw Failure.invalid }
            return ticket
        }
        /// Moves an unreadable ticket out of the ledger, bytes unchanged, so one
        /// bad file cannot leave Cyder unable to coordinate (and read-only).
        func quarantine(_ name: String) throws {
            if mkdirat(fd, "quarantine", 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
            let target = "quarantine/" + name + ".\(Int(Date().timeIntervalSince1970))"
            guard renameat(fd, name, fd, target) == 0, fsync(fd) == 0 else { throw Failure.unavailable }
        }
        func write(_ ticket: Ticket) throws {
            let data = try JSONEncoder().encode(ticket)
            guard data.count <= 8192 else { throw Failure.invalid }
            let temporary = ".write-" + UUID().uuidString
            let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
            let count = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
            guard count == data.count, fsync(file) == 0,
                  renameat(fd, temporary, fd, ticket.id.uuidString + ".json") == 0, fsync(fd) == 0 else { throw Failure.unavailable }
        }
    }
    private static func identify(_ path: String?) throws -> (key: String?, path: String?) {
        guard let path else { return (nil, nil) }
        guard path.hasPrefix("/") else { throw Failure.invalid }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        guard stat(canonical, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw Failure.invalid }
        return ("\(info.st_uid):\(info.st_dev):\(info.st_ino)", canonical)
    }
    static func prepare(root: URL, issuer: UUID, scope: String?, correlation: Correlation? = nil, handoff: Handoff? = nil,
                        requiresGlobalScope: Bool = false, displayName: String? = nil) throws -> UUID {
        precondition(!Thread.isMainThread)
        guard correlation?.isValid != false else { throw Failure.invalid }
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        if try directory.names().count >= 128 { try prune(directory, confirmed: []) }
        guard try directory.names().count < 512 else { throw Failure.full }
        let identity = try identify(scope)
        if let handoff {
            guard identity.key != nil, handoff.isValid else { throw Failure.invalid }
        }
        let canonicalHandoff = handoff.map {
            Handoff(executable: URL(fileURLWithPath: $0.executable).resolvingSymlinksInPath().path, pidFile: $0.pidFile)
        }
        // Older helpers reject schema 2 instead of silently ignoring the new
        // global barrier and executing a shared mutation under a prefix lock.
        let ticket = Ticket(schema: requiresGlobalScope ? 2 : 1, id: UUID(), issuer: issuer, scope: identity.key, prefix: identity.path,
                            phase: .prepared, correlation: correlation, handoff: canonicalHandoff,
                            requiresGlobalScope: requiresGlobalScope ? true : nil,
                            displayName: displayName.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(100)) })
        try directory.write(ticket)
        return ticket.id
    }
    /// Valid tickets only; an unreadable one is skipped here (and moved aside
    /// by recover at the next start) instead of hiding every other ticket.
    static func snapshot(root: URL) throws -> [Ticket] {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        return try directory.names().compactMap { name in
            do { return try directory.read(name) } catch Failure.invalid { return nil }
        }
    }
    /// Correlated results are eligible only after the exact snapshot has been
    /// delivered to the app. Missing tickets cannot execute.
    static func prune(root: URL, confirmed: [Ticket]) throws {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        try prune(directory, confirmed: confirmed)
    }
    private static func prune(_ directory: Directory, confirmed: [Ticket]) throws {
        let tickets = try directory.names().map { try directory.read($0) }
        let disposable = tickets.filter { $0.correlation == nil && $0.phase.isTerminal }
        let disposableIDs = Set(disposable.dropFirst(32).map(\.id))
        for ticket in tickets where ticket.phase.isTerminal {
            guard disposableIDs.contains(ticket.id) || confirmed.contains(ticket) else { continue }
            let lock: Int32
            do { lock = try directory.lock(ticket.id.uuidString + ".lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(lock) }
            let spawnLock: Int32
            do { spawnLock = try directory.lock(ticket.id.uuidString + ".spawn.lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(spawnLock) }
            guard try directory.read(ticket.id.uuidString + ".json") == ticket else { continue }
            guard unlinkat(directory.fd, ticket.id.uuidString + ".json", 0) == 0,
                  fsync(directory.fd) == 0 else { throw Failure.unavailable }
            // No ticket may be recreated with an old UUID. A late helper must
            // reread it under its lock and therefore refuses after deletion.
            _ = unlinkat(directory.fd, ticket.id.uuidString + ".lock", 0)
            _ = unlinkat(directory.fd, ticket.id.uuidString + ".spawn.lock", 0)
        }
    }
    /// Called before the new primary can issue effects. A helper takes its
    /// scope locks before claiming a ticket, so waiting old helpers are revoked.
    /// Returns the names of unreadable tickets it moved to `quarantine/`.
    @discardableResult
    static func recover(root: URL) throws -> [String] {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        let currentBoot = Birth.current()?.boot
        var quarantined: [String] = []
        for name in try directory.names() {
            var ticket: Ticket
            do { ticket = try directory.read(name) }
            catch Failure.invalid { try directory.quarantine(name); quarantined.append(name); continue }
            let ownerLock: Int32
            do { ownerLock = try directory.lock(ticket.id.uuidString + ".lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(ownerLock) }
            let spawnLock: Int32
            do { spawnLock = try directory.lock(ticket.id.uuidString + ".spawn.lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(spawnLock) }
            ticket = try directory.read(name)
            if ticket.phase == .prepared { ticket.phase = .revoked; try directory.write(ticket) }
            else if [.active, .handedOff, .uncertain].contains(ticket.phase), let oldBoot = ticket.owner?.boot, let currentBoot, oldBoot != currentBoot {
                ticket.phase = .revoked; try directory.write(ticket) // no process survives an OS boot boundary
            } else if [.active, .handedOff, .uncertain].contains(ticket.phase), ticket.nativeSpawn?.process != nil,
                      ticket.nativeSpawn?.phase.hasProcess == true {
                ticket.phase = ticket.nativeSpawn?.phase == .exited ? .finished : .handedOff
                try directory.write(ticket)
            } else if ticket.phase == .active { ticket.phase = .uncertain; try directory.write(ticket) }
            // Both locks are held here, so the helper is gone: release the
            // ticket if nothing it started is still running.
            if ticket.phase.holdsScope, remains(ticket) == .none {
                ticket.phase = .revoked; ticket.resolution = "abandoned"; try directory.write(ticket)
            }
        }
        return quarantined
    }
    private static func overlaps(_ a: String?, _ b: String?) -> Bool { a == nil || b == nil || a == b }
    // MARK: Unresolved operations (P0-2)
    //
    // A ticket that is active or uncertain blocks every overlapping operation,
    // because its preparation may still be changing the prefix (user.reg,
    // DLLs, registry imports) or shared runtime links. Once its helper is gone
    // (its owner lock can be taken), the question is only whether anything the
    // operation started is still running. The recorded process group answers
    // that exactly; an operation with no surviving process is released.

    enum Remains: Equatable {
        /// Bash, the bridge, or an unknown older operation may still be running.
        case running
        /// The operation's own processes outlived its helper (orphaned group).
        case leftovers(group: Int32)
        /// Nothing from the operation can still be running.
        case none
    }

    /// Call only while holding the ticket's owner lock (its helper is gone).
    static func remains(_ ticket: Ticket, serverRunning: (String) -> Bool = prefixServerRunning) -> Remains {
        if let child = ticket.child, Birth.current(child.pid, includingZombie: true) == child { return .running }
        if let bridge = ticket.nativeSpawn?.bridge, Birth.current(bridge.pid, includingZombie: true) == bridge { return .running }
        if let group = ticket.group {
            // POSIX never reuses a PID while it is still a process group ID.
            // A live process with the leader's PID is therefore either the
            // helper itself or a reuse, which proves the old group is empty.
            if let owner = ticket.owner, Birth.current(group, includingZombie: true) == owner { return .running }
            if kill(group, 0) == 0 || errno == EPERM { return .none }
            if killpg(group, 0) == 0 || errno == EPERM { return .leftovers(group: group) }
            return .none
        }
        // Older helpers recorded no group. Release only with full evidence:
        // the helper and its Bash are provably gone, the operation was
        // prefix-scoped (a shared-runtime change has no server to observe),
        // and that prefix's Wine server has exited.
        if let owner = ticket.owner, Birth.current(owner.pid, includingZombie: true) == owner { return .running }
        guard ticket.owner != nil, ticket.child != nil, ticket.effectiveScope != nil,
              let prefix = ticket.prefix, !serverRunning(prefix) else { return .running }
        return .none
    }

    /// Wine's per-prefix server socket: <tmp>/.wine-<uid>/server-<dev>-<ino>/socket.
    static func prefixServerRunning(_ prefix: String) -> Bool {
        var info = stat()
        guard stat(prefix, &info) == 0 else { return false }
        let leaf = ".wine-\(getuid())/server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))/socket"
        var roots = ["/tmp"]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty { roots.append(tmp) }
        return roots.contains { root in
            var socket = stat()
            return lstat((root as NSString).appendingPathComponent(leaf), &socket) == 0 && socket.st_mode & S_IFMT == S_IFSOCK
        }
    }

    /// Releases a scope-holding ticket whose helper is gone and whose
    /// processes have all exited. Returns true when the ticket no longer holds
    /// its scope. Never blocks: a held lock means its helper is alive.
    private static func releaseIfAbandoned(_ directory: Directory, _ name: String) throws -> Bool {
        let id = String(name.dropLast(5))
        let owner: Int32
        do { owner = try directory.lock(id + ".lock") } catch Failure.busy { return false }
        defer { Darwin.close(owner) }
        let spawn: Int32
        do { spawn = try directory.lock(id + ".spawn.lock") } catch Failure.busy { return false }
        defer { Darwin.close(spawn) }
        var ticket = try directory.read(name)
        guard ticket.phase.holdsScope else { return true }
        guard remains(ticket) == .none else { return false }
        ticket.phase = .revoked; ticket.resolution = "abandoned"
        try directory.write(ticket)
        return true
    }

    enum StopResult: Equatable { case stopped, nothingLeft, stillRunning, notFound }

    /// User action: stop the processes an interrupted operation left behind,
    /// then release its scope. Only ever signals the ticket's own orphaned
    /// group (its helper must be gone and its leader PID unused).
    static func stopLeftovers(root: URL, id: UUID, grace: TimeInterval = 5) throws -> StopResult {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let name = id.uuidString + ".json"
        guard (try? directory.names().contains(name)) == true else { return .notFound }
        let owner: Int32
        do { owner = try directory.lock(id.uuidString + ".lock") } catch Failure.busy { return .stillRunning }
        defer { Darwin.close(owner) }
        let spawn: Int32
        do { spawn = try directory.lock(id.uuidString + ".spawn.lock") } catch Failure.busy { return .stillRunning }
        defer { Darwin.close(spawn) }
        var ticket = try directory.read(name)
        guard ticket.phase.holdsScope else { return .nothingLeft }
        var result = StopResult.nothingLeft
        if case .leftovers(let group) = remains(ticket) {
            _ = killpg(group, SIGTERM)
            let end = ProcessInfo.processInfo.systemUptime + grace
            while killpg(group, 0) == 0, ProcessInfo.processInfo.systemUptime < end { usleep(100_000) }
            if killpg(group, 0) == 0 {
                _ = killpg(group, SIGKILL)
                let hard = ProcessInfo.processInfo.systemUptime + 2
                while killpg(group, 0) == 0, ProcessInfo.processInfo.systemUptime < hard { usleep(50_000) }
            }
            result = .stopped
        }
        guard remains(ticket) == .none else { return .stillRunning }
        ticket.phase = .revoked; ticket.resolution = result == .stopped ? "terminated" : "abandoned"
        try directory.write(ticket)
        return result
    }

    /// Overlapping scope holders, after releasing the abandoned ones. Prints a
    /// machine-readable line naming the first remaining holder for the app.
    private static func blockingTicket(_ directory: Directory, scope: String?, excluding name: String?) throws -> Ticket? {
        for otherName in try directory.names() where otherName != name {
            let other = try directory.read(otherName)
            guard overlaps(scope, other.effectiveScope), other.phase.holdsScope else { continue }
            if try releaseIfAbandoned(directory, otherName) { continue }
            return try directory.read(otherName)
        }
        return nil
    }
    static let leftoverMarker = "CYDER-SCOPE-BLOCKED ticket="
    /// The blocking ticket named in a helper's output, if a launch or
    /// maintenance step was refused because of an interrupted operation.
    static func blockingTicket(in output: String) -> UUID? {
        guard let range = output.range(of: leftoverMarker, options: .backwards) else { return nil }
        return UUID(uuidString: String(output[range.upperBound...].prefix(36)))
    }
    private static func reportBlocked(_ ticket: Ticket) {
        fputs("\(leftoverMarker)\(ticket.id.uuidString) group=\(ticket.group.map(String.init) ?? "-")\n", stderr)
    }

    /// Seconds a helper waits for another helper's operation on its scope.
    static let scopeWait: TimeInterval = 25 // below the app's 30 s launch observation

    /// In-process filesystem mutations use the same cross-process barriers as
    /// native launchers. The lease lasts through actual work, not UI observation.
    static func withScope<T>(root: URL, scope: String?, _ work: () throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let identity = try identify(scope)
        let scope = identity.key
        let global = try directory.lock("all-environments.lock", exclusive: scope == nil)
        defer { Darwin.close(global) }
        var prefix: Int32 = -1
        if let scope {
            let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
            prefix = try directory.lock("prefix-" + digest + ".lock")
        }
        defer { if prefix >= 0 { Darwin.close(prefix) } }
        if let blocker = try blockingTicket(directory, scope: scope, excluding: nil) {
            reportBlocked(blocker); throw Failure.uncertain
        }
        guard try identify(identity.path).key == scope else { throw Failure.invalid }
        return try work()
    }
    /// Runs only in the native helper, before AppKit starts. Blocking wait is
    /// intentional here; neither the UI nor its request coordinator waits.
    static func execute(root: URL, id: UUID, command: [String]) -> Int32 {
        guard !command.isEmpty, command[0].hasPrefix("/") else { return 64 }
        do {
            let directory = try Directory(root)
            let name = id.uuidString + ".json"
            var ticket = try directory.read(name)
            // Another helper preparing the same scope finishes first; waiting
            // replaces the former immediate failure, bounded by scopeWait.
            let global = try directory.waitLock("all-environments.lock", exclusive: ticket.effectiveScope == nil, deadline: scopeWait)
            defer { Darwin.close(global) }
            var scopeLock: Int32 = -1
            if let scope = ticket.scope {
                let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
                scopeLock = try directory.waitLock("prefix-" + digest + ".lock", exclusive: true, deadline: scopeWait)
            }
            defer { if scopeLock >= 0 { Darwin.close(scopeLock) } }
            let ownerLock = try directory.lock(id.uuidString + ".lock"); defer { Darwin.close(ownerLock) }
            ticket = try directory.read(name)
            guard ticket.phase == .prepared else { throw Failure.revoked }
            // An unreadable process/boot identity is not a revoked ticket.
            // Fail closed and leave the prepared ticket untouched so a host
            // permission problem is diagnosable without weakening ownership.
            guard let owner = Birth.current() else { throw Failure.processIdentityUnavailable }
            guard try identify(ticket.prefix).key == ticket.scope else { throw Failure.invalid }
            // An executor crash can leave descendants alive. Absence of its
            // lock is not permission to bypass an unresolved prior operation;
            // only an empty process group is (see remains).
            if let blocker = try blockingTicket(directory, scope: ticket.effectiveScope, excluding: name) {
                reportBlocked(blocker); throw Failure.uncertain
            }
            // Lead a new process group before claiming, so the group exists and
            // is recorded before anything the operation runs.
            if getpgrp() != getpid() { _ = setpgid(0, 0) }
            ticket.group = getpgrp() == getpid() ? getpid() : nil
            ticket.phase = .active; ticket.owner = owner; try directory.write(ticket)
            // Authority is reconstructed from this ticket, never inherited
            // from a parent launch or user-provided game environment.
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CYDER_EXECUTION_") }
            environment["CYDER_EXECUTION_RUNTIME_MUTATION"] = ticket.effectiveScope == nil ? "1" : "0"
            if ticket.handoff != nil {
                environment["CYDER_EXECUTION_OWNER_ROOT"] = root.path
                environment["CYDER_EXECUTION_OWNER_TICKET"] = id.uuidString
                environment["CYDER_EXECUTION_OWNER_HELPER"] = CommandLine.arguments[0]
            }
            let childPID: Int32
            do { childPID = try spawnInGroup(command, environment: environment, group: ticket.group) }
            catch { ticket.phase = .finished; ticket.status = 127; try directory.write(ticket); return 127 }
            // If this write fails, keep owning the child and scope until it
            // actually returns; never abandon a running mutation on disk error.
            do {
                let updateLock = try directory.waitLock(id.uuidString + ".spawn.lock")
                defer { Darwin.close(updateLock) }
                ticket = try directory.read(name)
                ticket.child = Birth.current(childPID, includingZombie: true)
                try directory.write(ticket)
            } catch {}
            let exit = waitForChild(childPID) ?? (status: 127, signalled: false)
            let finalLock = try directory.waitLock(id.uuidString + ".spawn.lock")
            defer { Darwin.close(finalLock) }
            ticket = try directory.read(name)
            // The final bridge and this settlement use the same lock. A bridge
            // arriving after settlement cannot claim; one already spawning must
            // return before the scope is released, even if Bash exited early.
            switch ticket.nativeSpawn?.phase {
            case .spawned: ticket.phase = .handedOff
            case .claiming: ticket.phase = .uncertain
            case .exited, .failed, nil: ticket.phase = .finished
            }
            ticket.status = exit.status
            ticket.signalled = exit.signalled
            try directory.write(ticket)
            if ticket.phase == .uncertain || (ticket.handoff != nil && ticket.nativeSpawn == nil && exit.status == 0) { return 75 }
            return exit.signalled ? 128 + exit.status : exit.status
        } catch {
            if case Failure.processIdentityUnavailable = error {
                fputs("Cyder executor cannot verify process identity (same-user proc_pidinfo / kern.bootsessionuuid); host permissions are required.\n", stderr)
            }
            fputs("Cyder executor could not claim or confirm its operation: \(error)\n", stderr)
            return 75
        }
    }
    private static func publishPID(_ pid: Int32, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = try Directory(url.deletingLastPathComponent())
        let temporary = ".pid-" + UUID().uuidString
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); unlinkat(directory.fd, temporary, 0) }
        let data = Data("\(pid)\n".utf8)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0,
              renameat(directory.fd, temporary, directory.fd, url.lastPathComponent) == 0,
              fsync(directory.fd) == 0 else { throw Failure.unavailable }
    }
    private static func spawnWine(_ command: [String], correlation: Correlation?) throws -> Int32 {
        // No shell, arch or taskpolicy trampoline may remain after this call.
        // Apple posix_spawn performs the executable-image creation atomically;
        // the x86 preference also handles a future universal Wine executable.
        let file = Darwin.open(command[0], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw Failure.invalid }
        defer { Darwin.close(file) }
        var info = stat(), magic: UInt32 = 0
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              pread(file, &magic, 4, 0) == 4,
              [UInt32(0xfeedfacf), 0xfeedface, 0xbebafeca, 0xbfbafeca].contains(magic) else { throw Failure.invalid }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var architecture = cpu_type_t(CPU_TYPE_X86_64), accepted = 0
        guard posix_spawnattr_setbinpref_np(&attributes, 1, &architecture, &accepted) == 0, accepted == 1 else { throw Failure.unavailable }
        var argv = command.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CYDER_EXECUTION_") }
        // This public correlation label is observation-only. Never pass the
        // executor ticket, even when the Wine child later double-forks.
        environment["CYDER_LAUNCH_GROUP"] = correlation?.isValid == true ? correlation?.launchID : nil
        var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: Int32 = 0
        let error = posix_spawn(&pid, command[0], nil, &attributes, &argv, &env)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        return pid
    }
    /// Runs the operation's Bash in the helper's process group (Foundation's
    /// Process would give it a new group of its own), stdin from /dev/null,
    /// stdout/stderr inherited.
    private static func spawnInGroup(_ command: [String], environment: [String: String], group: Int32?) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if let group { flags |= Int16(POSIX_SPAWN_SETPGROUP); posix_spawnattr_setpgroup(&attributes, group) }
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else { throw Failure.unavailable }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // CLOEXEC_DEFAULT closes everything else; keep exactly stdio.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        var argv = command.map { strdup($0) } + [nil]
        var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: Int32 = 0
        let error = posix_spawn(&pid, command[0], &actions, &attributes, &argv, &env)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        return pid
    }
    private static func waitForChild(_ pid: Int32) -> (status: Int32, signalled: Bool)? {
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0 {
            if errno == EINTR { continue }
            return nil
        }
        let signal = raw & 0x7f
        return signal == 0 ? ((raw >> 8) & 0xff, false) : (signal, true)
    }
    /// Called by the last application-owned Wine wrapper. A durable one-use
    /// claim and the outer executor's scope lock cover the actual native spawn.
    static func executeWine(root: URL, id: UUID, command: [String]) -> Int32 {
        guard !command.isEmpty, command[0].hasPrefix("/"), command.allSatisfy({ !$0.contains("\0") }) else { return 64 }
        var pid: Int32 = 0
        var childResult: (status: Int32, signalled: Bool)?
        defer { if pid > 0, childResult == nil { _ = waitForChild(pid) } }
        do {
            let directory = try Directory(root)
            let name = id.uuidString + ".json"
            do {
                let claimLock = try directory.waitLock(id.uuidString + ".spawn.lock")
                defer { Darwin.close(claimLock) }
                var ticket = try directory.read(name)
                guard ticket.phase == .active, ticket.nativeSpawn == nil, let handoff = ticket.handoff else { throw Failure.revoked }
                guard let owner = ticket.owner, Birth.current(owner.pid) == owner,
                      let bridge = Birth.current() else { throw Failure.ownerMissing }
                guard try identify(ProcessInfo.processInfo.environment["WINEPREFIX"]).key == ticket.scope,
                      try identify(ticket.prefix).key == ticket.scope else { throw Failure.scopeChanged }
                guard URL(fileURLWithPath: command[0]).resolvingSymlinksInPath().path == handoff.executable else { throw Failure.executableChanged }
                ticket.nativeSpawn = .init(phase: .claiming, bridge: bridge)
                try directory.write(ticket)
                do { pid = try spawnWine([handoff.executable] + command.dropFirst(), correlation: ticket.correlation) }
                catch {
                    ticket.nativeSpawn?.phase = .failed; ticket.nativeSpawn?.status = 127
                    try directory.write(ticket); throw error
                }
                // This is our unreaped child, including a very fast zombie;
                // its PID cannot be reused before our waitpid below.
                guard let birth = Birth.current(pid, includingZombie: true) else {
                    childResult = waitForChild(pid)
                    throw Failure.uncertain
                }
                ticket.nativeSpawn?.process = birth
                ticket.nativeSpawn?.phase = .spawned
                // Spawn has crossed the real native image boundary. The outer
                // owner may still hold its scope while Bash returns, but a
                // concurrent owner crash must not strand this as pre-spawn.
                ticket.phase = .handedOff
                do {
                    try directory.write(ticket)
                    try publishPID(pid, to: handoff.pidFile)
                } catch {
                    // Disk failure must not abandon a spawned child or release
                    // a possibly unrecorded effect. Retain the claim until exit.
                    childResult = waitForChild(pid)
                    throw error
                }
            }
            childResult = waitForChild(pid)
            guard let result = childResult else { throw Failure.uncertain }
            let resultLock = try directory.waitLock(id.uuidString + ".spawn.lock")
            defer { Darwin.close(resultLock) }
            var ticket = try directory.read(name)
            ticket.nativeSpawn?.phase = .exited
            ticket.nativeSpawn?.status = result.status; ticket.nativeSpawn?.signalled = result.signalled
            // The Bash result can arrive after this very fast native child.
            // Only the second of those outcomes seals an immutable terminal
            // ticket, so reconciliation cannot preserve a premature terminal.
            if ticket.phase == .handedOff, ticket.status != nil { ticket.phase = .finished }
            try directory.write(ticket)
            return result.signalled ? 128 + result.status : result.status
        } catch {
            fputs("Cyder final Wine executor could not confirm its operation: \(error)\n", stderr)
            return 75
        }
    }
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 6, ["--execution-owner", "--execution-wine"].contains(arguments[1]), let id = UUID(uuidString: arguments[3]), arguments[4] == "--" else { return 64 }
        let root = URL(fileURLWithPath: arguments[2]), command = Array(arguments.dropFirst(5))
        return arguments[1] == "--execution-wine" ? executeWine(root: root, id: id, command: command) : execute(root: root, id: id, command: command)
    }
}
