import Foundation
import Darwin
import CryptoKit

/// Native executor authority survives the UI process. A prepared ticket is
/// revocable; once claimed, only the executor's actual outcome releases it.
/// Arguments/environment remain in process memory, never in this ledger.
enum CyderExecutionOwner {
    enum Failure: Error { case invalid, unavailable, busy, full, revoked, uncertain }
    struct Birth: Codable, Equatable {
        let boot: String
        let pid: Int32
        let started: UInt64
        static func current(_ pid: Int32 = getpid()) -> Self? {
            var info = proc_bsdinfo(), boot = [CChar](repeating: 0, count: 128)
            var size = boot.count
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
                  info.pbi_uid == getuid(), info.pbi_status != SZOMB,
                  sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0 else { return nil }
            return .init(boot: String(cString: boot), pid: pid, started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
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
        var phase: String
        var owner: Birth?
        var child: Birth?
        var status: Int32?
        var signalled: Bool? = nil
        var correlation: Correlation? = nil
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
                  let ticket = try? JSONDecoder().decode(Ticket.self, from: data), ticket.schema == 1,
                  name == ticket.id.uuidString + ".json",
                  ["prepared", "active", "finished", "revoked", "uncertain"].contains(ticket.phase),
                  ticket.correlation?.isValid != false else { throw Failure.invalid }
            return ticket
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
    static func prepare(root: URL, issuer: UUID, scope: String?, correlation: Correlation? = nil) throws -> UUID {
        precondition(!Thread.isMainThread)
        guard correlation?.isValid != false else { throw Failure.invalid }
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        if try directory.names().count >= 128 { try prune(directory, confirmed: []) }
        guard try directory.names().count < 512 else { throw Failure.full }
        let identity = try identify(scope)
        let ticket = Ticket(schema: 1, id: UUID(), issuer: issuer, scope: identity.key, prefix: identity.path, phase: "prepared", correlation: correlation)
        try directory.write(ticket)
        return ticket.id
    }
    static func snapshot(root: URL) throws -> [Ticket] {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        return try directory.names().map { try directory.read($0) }
    }
    /// Correlated results are eligible only after the exact snapshot has been
    /// durably copied into the request journal. Missing tickets cannot execute.
    static func prune(root: URL, confirmed: [Ticket]) throws {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        try prune(directory, confirmed: confirmed)
    }
    private static func prune(_ directory: Directory, confirmed: [Ticket]) throws {
        let tickets = try directory.names().map { try directory.read($0) }
        let disposable = tickets.filter { $0.correlation == nil && ["finished", "revoked"].contains($0.phase) }
        let disposableIDs = Set(disposable.dropFirst(32).map(\.id))
        for ticket in tickets where ["finished", "revoked"].contains(ticket.phase) {
            guard disposableIDs.contains(ticket.id) || confirmed.contains(ticket) else { continue }
            let lock: Int32
            do { lock = try directory.lock(ticket.id.uuidString + ".lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(lock) }
            guard try directory.read(ticket.id.uuidString + ".json") == ticket else { continue }
            guard unlinkat(directory.fd, ticket.id.uuidString + ".json", 0) == 0,
                  fsync(directory.fd) == 0 else { throw Failure.unavailable }
            // No ticket may be recreated with an old UUID. A late helper must
            // reread it under its lock and therefore refuses after deletion.
            _ = unlinkat(directory.fd, ticket.id.uuidString + ".lock", 0)
        }
    }
    /// Called before the new primary can issue effects. A helper takes its
    /// scope locks before claiming a ticket, so waiting old helpers are revoked.
    static func recover(root: URL) throws {
        precondition(!Thread.isMainThread)
        let directory = try Directory(root)
        let serial = try directory.lock("catalog.lock"); defer { Darwin.close(serial) }
        let currentBoot = Birth.current()?.boot
        for name in try directory.names() {
            var ticket = try directory.read(name)
            let ownerLock: Int32
            do { ownerLock = try directory.lock(ticket.id.uuidString + ".lock") }
            catch Failure.busy { continue }
            defer { Darwin.close(ownerLock) }
            ticket = try directory.read(name)
            if ticket.phase == "prepared" { ticket.phase = "revoked"; try directory.write(ticket) }
            else if ["active", "uncertain"].contains(ticket.phase), let oldBoot = ticket.owner?.boot, let currentBoot, oldBoot != currentBoot {
                ticket.phase = "revoked"; try directory.write(ticket) // no process survives an OS boot boundary
            } else if ticket.phase == "active" { ticket.phase = "uncertain"; try directory.write(ticket) }
        }
    }
    private static func overlaps(_ a: String?, _ b: String?) -> Bool { a == nil || b == nil || a == b }
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
        for name in try directory.names() {
            let previous = try directory.read(name)
            guard !overlaps(scope, previous.scope) || !["active", "uncertain"].contains(previous.phase) else { throw Failure.uncertain }
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
            let global = try directory.lock("all-environments.lock", exclusive: ticket.scope == nil)
            defer { Darwin.close(global) }
            var scopeLock: Int32 = -1
            if let scope = ticket.scope {
                let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
                scopeLock = try directory.lock("prefix-" + digest + ".lock")
            }
            defer { if scopeLock >= 0 { Darwin.close(scopeLock) } }
            let ownerLock = try directory.lock(id.uuidString + ".lock"); defer { Darwin.close(ownerLock) }
            ticket = try directory.read(name)
            guard ticket.phase == "prepared", let owner = Birth.current() else { throw Failure.revoked }
            guard try identify(ticket.prefix).key == ticket.scope else { throw Failure.invalid }
            // An executor crash can leave descendants alive. Absence of its
            // lock is not permission to bypass an unresolved prior operation.
            for otherName in try directory.names() where otherName != name {
                let other = try directory.read(otherName)
                if overlaps(ticket.scope, other.scope), ["active", "uncertain"].contains(other.phase) { throw Failure.uncertain }
            }
            ticket.phase = "active"; ticket.owner = owner; try directory.write(ticket)
            let child = Process(); child.executableURL = URL(fileURLWithPath: command[0]); child.arguments = Array(command.dropFirst())
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
            do { try child.run() }
            catch { ticket.phase = "finished"; ticket.status = 127; try directory.write(ticket); return 127 }
            ticket.child = Birth.current(child.processIdentifier)
            // If this write fails, keep owning the child and scope until it
            // actually returns; never abandon a running mutation on disk error.
            try? directory.write(ticket)
            child.waitUntilExit()
            ticket.phase = "finished"; ticket.status = child.terminationStatus
            ticket.signalled = child.terminationReason == .uncaughtSignal
            try directory.write(ticket)
            return child.terminationReason == .uncaughtSignal ? 128 + child.terminationStatus : child.terminationStatus
        } catch {
            fputs("Cyder executor could not claim or confirm its operation: \(error)\n", stderr)
            return 75
        }
    }
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 6, arguments[1] == "--execution-owner", let id = UUID(uuidString: arguments[3]), arguments[4] == "--" else { return 64 }
        return execute(root: URL(fileURLWithPath: arguments[2]), id: id, command: Array(arguments.dropFirst(5)))
    }
}
