import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.contains("--child") { alarm(10); while true { pause() } }
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { done.signal() }
    typealias P = CyderProcessEvidence
    func id(_ pid: Int32, _ born: UInt64, _ boot: String = "fixture") -> P.ID { .init(boot: boot, pid: pid, started: born) }
    let parent = id(10, 100), child = id(20, 200), grandchild = id(30, 300), reused = id(10, 400)
    let nodes: [Int32: P.Node] = [10: .init(id: parent, parent: 1), 20: .init(id: child, parent: 10), 30: .init(id: grandchild, parent: 20)]
    let read: (Int32) -> P.Presence = { nodes[$0].map { .live($0) } ?? .unavailable }
    let children: (Int32) -> [Int32] = { $0 == 10 ? [20, 30] : ($0 == 20 ? [30] : []) }
    precondition(P.tree(roots: [parent], read: read, children: children) == [parent, child, grandchild])
    precondition(P.tree(roots: [reused], read: read, children: children).isEmpty, "same PID is not same root")
    precondition(P.tree(roots: [id(10, 100, "other-boot")], read: read, children: children).isEmpty)
    let unrelated: (Int32) -> P.Presence = { pid in pid == 20 ? .live(.init(id: child, parent: 99)) : read(pid) }
    precondition(P.tree(roots: [parent], read: unrelated, children: children) == [parent], "numeric child listing alone proved ownership")
    let olderChild: (Int32) -> P.Presence = { pid in pid == 20 ? .live(.init(id: id(20, 50), parent: 10)) : read(pid) }
    precondition(P.tree(roots: [parent], read: olderChild, children: children) == [parent])
    var parentReads = 0
    let raced: (Int32) -> P.Presence = { pid in
        if pid == 10 { parentReads += 1; if parentReads > 1 { return .live(.init(id: reused, parent: 1)) } }
        return read(pid)
    }
    precondition(P.tree(roots: [parent], read: raced, children: children).isEmpty, "parent reuse during scan claimed a foreign descendant")
    precondition(!P.hasEnded(parent, read: { _ in .unavailable }))
    precondition(P.hasEnded(parent, read: { _ in .absent }))
    precondition(P.hasEnded(parent, read: { _ in .live(.init(id: reused, parent: 1)) }))
    guard case .live(let actualParent) = P.inspect(getpid()) else { fatalError("native process birth unavailable") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = [root.path, "--child"]
    try! process.run()
    defer { process.terminate(); process.waitUntilExit() }
    guard case .live(let actualChild) = P.inspect(process.processIdentifier) else { fatalError("native child birth unavailable") }
    let actualTree = P.tree(roots: [actualParent.id])
    precondition(actualTree.contains(actualChild.id) && actualChild.parent == getpid())
    let wrongBirth = P.ID(boot: actualChild.id.boot, pid: actualChild.id.pid, started: actualChild.id.started + 1)
    precondition(!P.live(wrongBirth) && P.tree(roots: [wrongBirth]).isEmpty)
    print("PASS formal process evidence: native parent/child birth, injected reused PID/boot/parent edge/race/older child, unavailable is not exited")
}
precondition(done.wait(timeout: .now() + 15) == .success)
