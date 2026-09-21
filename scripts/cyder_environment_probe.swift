import Foundation
import Darwin

/// Read-only calibration of the CX26 server namespace. Never creates a Wine
/// lock, takes its lock, removes a socket, or sends a Wine protocol request.
/// See engine server/request.c:create_server_dir/acquire_lock and main.c:-w.
struct CyderEnvironmentProbe {
    struct Identity: Codable, Equatable {
        let environment: CyderLifecycle.EnvironmentID
        let prefix: String
        let engine: String
    }
    enum Result: Equatable {
        case alive(CyderLifecycle.ProcessID)
        case empty
        case unknown(String)
    }
    static func identify(prefix: URL, engine: URL) -> Identity? {
        let path = prefix.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return nil }
        return Identity(environment: .init(uid: getuid(), device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino), namespace: "wine-user"), prefix: path,
            engine: engine.resolvingSymlinksInPath().standardizedFileURL.path)
    }
    static func processIdentity(_ pid: Int32) -> CyderLifecycle.ProcessID? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        var boot = [CChar](repeating: 0, count: 128)
        var size = boot.count
        guard sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0 else { return nil }
        return .init(boot: String(cString: boot), pid: pid,
                     started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
    static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
    static func serverDirectory(_ identity: Identity) -> URL {
        URL(fileURLWithPath: "/private/tmp/.wine-\(identity.environment.uid)/server-\(String(identity.environment.device, radix: 16))-\(String(identity.environment.inode, radix: 16))")
    }
    /// Injectable lookups allow native lock/socket fixtures to exercise this
    /// exact production calibration without impersonating a Wine server.
    static func inspect(_ identity: Identity,
                        process: (Int32) -> CyderLifecycle.ProcessID? = processIdentity,
                        image: (Int32) -> String? = processPath) -> Result {
        precondition(!Thread.isMainThread, "environment calibration belongs to an observer worker")
        guard let current = identify(prefix: URL(fileURLWithPath: identity.prefix), engine: URL(fileURLWithPath: identity.engine)),
              current == identity else { return .unknown("prefix-identity-changed") }
        guard FileManager.default.isExecutableFile(atPath: identity.engine) else { return .unknown("engine-unavailable") }
        let directory = serverDirectory(identity)
        var info = stat()
        for path in [directory.deletingLastPathComponent().path, directory.path] {
            if lstat(path, &info) != 0 {
                return errno == ENOENT ? .empty : .unknown("namespace-unreadable")
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == identity.environment.uid,
                  info.st_mode & 0o077 == 0 else { return .unknown("namespace-invalid") }
        }
        let lockPath = directory.appendingPathComponent("lock").path
        let fd = Darwin.open(lockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            // A socket-only server is possible when POSIX locks are unavailable.
            guard errno == ENOENT else { return .unknown("lock-unreadable") }
            return socketAbsent(directory.appendingPathComponent("socket").path) ? .empty : .unknown("socket-without-lock")
        }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == identity.environment.uid else { return .unknown("lock-invalid") }
        let lockDevice = info.st_dev, lockInode = info.st_ino
        func holder() -> Int32? {
            var region = flock(l_start: 0, l_len: 1, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
            guard fcntl(fd, F_GETLK, &region) == 0 else { return nil }
            if region.l_type == F_UNLCK { return 0 }
            guard region.l_type == F_WRLCK, region.l_pid > 0 else { return nil }
            return region.l_pid
        }
        guard let before = holder() else { return .unknown("lock-query-failed") }
        let result: Result
        if before > 0 {
            guard let owner = process(before), image(before) == identity.engine,
                  let after = process(before), after == owner else { return .unknown("lock-owner-unverified") }
            // '-w' itself can momentarily acquire this same write lock after
            // the server exits. A live server endpoint distinguishes that
            // waiter from an actual environment and excludes stale lock owners.
            guard socketState(directory.appendingPathComponent("socket").path) == .connected else { return .unknown("lock-without-live-socket") }
            result = .alive(owner)
        } else {
            guard socketAbsent(directory.appendingPathComponent("socket").path) else { return .unknown("socket-may-be-live") }
            result = .empty
        }
        guard holder() == before, lstat(lockPath, &info) == 0,
              info.st_dev == lockDevice, info.st_ino == lockInode,
              identify(prefix: URL(fileURLWithPath: identity.prefix), engine: URL(fileURLWithPath: identity.engine)) == identity
        else { return .unknown("observation-raced") }
        return result
    }
    private enum SocketState { case connected, absent, unknown }
    private static func socketAbsent(_ path: String) -> Bool { socketState(path) == .absent }
    private static func socketState(_ path: String) -> SocketState {
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT ? .absent : .unknown }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return .unknown }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return .unknown }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return .unknown }
        withUnsafeMutableBytes(of: &address.sun_path) { output in
            bytes.withUnsafeBytes { input in output.copyBytes(from: input) }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status == 0 { return .connected }
        return errno == ECONNREFUSED || errno == ENOENT ? .absent : .unknown
    }
}
