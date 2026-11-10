import Foundation
import Darwin

/// Read-only access to this user's process table, shared by the lifecycle
/// monitor and the native helper. No environment/argv dumps are retained or
/// logged; only WINEPREFIX and the first .exe argument are extracted.
enum CyderProcessTable {
    struct Metadata: Equatable { let prefix: String; let name: String }
    /// Executables of an engine's Wine client processes (not wineserver).
    static let clientImages = ["bin/wine", "bin/wine64", "bin/wine-preloader", "bin/wine64-preloader",
                               "lib/wine/x86_64-unix/wine", "lib/wine/i386-unix/wine", "lib/wine/aarch64-unix/wine"]
    /// This user's processes, or nil when the table could not be read in full.
    static func completePIDs() -> [Int32]? {
        precondition(!Thread.isMainThread)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
            // Headroom for processes born between the size probe and the read.
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
            size = entries.count * MemoryLayout<kinfo_proc>.stride
            let result = entries.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result != 0 && errno == ENOMEM { continue }
            guard result == 0 else { return nil }
            return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
        }
        return nil
    }
    /// What KERN_PROCARGS2 shows. Wine overwrites its child processes'
    /// argument area with the Windows command line, so their WINEPREFIX is
    /// gone while the .exe name remains.
    struct Arguments: Equatable { let prefix: String?; let name: String? }
    static func parse(_ bytes: [UInt8]) -> Metadata? {
        guard let fields = arguments(bytes), let prefix = fields.prefix else { return nil }
        // CX_BOTTLE alone is not an absolute prefix identity.
        return .init(prefix: prefix, name: fields.name ?? "Windows 程序")
    }
    static func arguments(_ bytes: [UInt8]) -> Arguments? {
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
        return .init(prefix: prefix, name: name)
    }
    static func metadata(_ pid: Int32) -> Metadata? {
        arguments(pid).flatMap { fields in fields.prefix.map { .init(prefix: $0, name: fields.name ?? "Windows 程序") } }
    }
    static func arguments(_ pid: Int32) -> Arguments? {
        precondition(!Thread.isMainThread)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard bytes.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0,
              size <= bytes.count else { return nil }
        return arguments(Array(bytes.prefix(size)))
    }
    static func image(_ pid: Int32) -> String? {
        precondition(!Thread.isMainThread)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    }
    /// Kernel identities of a process's Unix-domain sockets and of the sockets
    /// they are connected to. A Wine client stays connected to its prefix's
    /// wineserver over a socketpair; matching `peers` against a server's `own`
    /// attributes the client even when its WINEPREFIX is unreadable.
    struct UnixSockets: Equatable { var own: Set<UInt64> = []; var peers: Set<UInt64> = [] }
    static func unixSockets(_ pid: Int32) -> UnixSockets? {
        precondition(!Thread.isMainThread)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard read > 0 else { return nil }
        var result = UnixSockets()
        for fd in fds.prefix(Int(read) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                    == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_family == AF_UNIX else { continue }
            if info.psi.soi_pcb != 0 { result.own.insert(info.psi.soi_pcb) }
            let peer = info.psi.soi_proto.pri_un.unsi_conn_pcb
            if peer != 0 { result.peers.insert(peer) }
        }
        return result
    }
}
