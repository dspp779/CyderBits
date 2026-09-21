import Foundation
import Darwin

/// Read-only process evidence. A numeric PID or shared prefix is never a
/// launch relationship. Every tree edge is bracketed by birth revalidation.
struct CyderProcessEvidence {
    typealias ID = CyderLifecycle.ProcessID
    struct Node: Equatable { let id: ID; let parent: Int32 }
    enum Presence: Equatable { case live(Node), absent, unavailable }
    static func inspect(_ pid: Int32) -> Presence {
        precondition(!Thread.isMainThread)
        guard pid > 0 else { return .unavailable }
        var info = proc_bsdinfo()
        errno = 0
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        guard size == MemoryLayout<proc_bsdinfo>.stride else { return errno == ESRCH ? .absent : .unavailable }
        guard info.pbi_uid == getuid() else { return .unavailable }
        if info.pbi_status == SZOMB { return .absent }
        var boot = [CChar](repeating: 0, count: 128), length = 128
        guard sysctlbyname("kern.bootsessionuuid", &boot, &length, nil, 0) == 0 else { return .unavailable }
        return .live(.init(id: .init(boot: String(cString: boot), pid: pid,
            started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec), parent: Int32(info.pbi_ppid)))
    }
    static func childPIDs(_ pid: Int32) -> [Int32] {
        precondition(!Thread.isMainThread)
        var children = [pid_t](repeating: 0, count: 256)
        let count = children.withUnsafeMutableBufferPointer {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        // Unlike proc_listpids, libproc already converts this result to a PID count.
        return Array(children.prefix(min(children.count, Int(count)))).filter { $0 > 0 }
    }
    static func live(_ id: ID, read: (Int32) -> Presence = inspect) -> Bool {
        if case .live(let node) = read(id.pid) { return node.id == id }
        return false
    }
    static func hasEnded(_ id: ID, read: (Int32) -> Presence = inspect) -> Bool {
        switch read(id.pid) {
        case .absent: return true
        case .live(let node): return node.id != id
        case .unavailable: return false
        }
    }
    static func tree(roots: Set<ID>, read: (Int32) -> Presence = inspect,
                     children: (Int32) -> [Int32] = childPIDs) -> Set<ID> {
        precondition(!Thread.isMainThread)
        var seen: Set<ID> = [], pending = Array(roots.prefix(1024))
        while let parent = pending.popLast(), seen.count < 1024 {
            guard !seen.contains(parent), live(parent, read: read) else { continue }
            seen.insert(parent)
            for pid in children(parent.pid).prefix(256) {
                guard case .live(let child) = read(pid), child.parent == parent.pid,
                      child.id.boot == parent.boot, child.id.started >= parent.started,
                      live(parent, read: read), read(pid) == .live(child), !seen.contains(child.id) else { continue }
                if pending.count + seen.count < 1024 { pending.append(child.id) }
            }
        }
        return Set(seen.filter { live($0, read: read) })
    }
}
