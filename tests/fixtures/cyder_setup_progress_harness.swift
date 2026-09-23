import Foundation
import Darwin

func require(_ ok: @autoclosure () -> Bool, _ label: String) {
    if !ok() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func spin(_ seconds: Double = 3, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    require(done(), "event-loop deadline")
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
final class Reader {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read(_ url: URL) -> String? {
        require(!Thread.isMainThread, "progress read on main thread")
        lock.lock(); count += 1; let sequence = count; lock.unlock()
        if sequence == 1 { require(gate.wait(timeout: .now() + 5) == .success, "fixture stalled") }
        return url.lastPathComponent
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let reader = Reader()
let progress = CyderSetupProgress(interval: 0.01, read: reader.read)
var shown: [String] = []
let first = progress.present()
let old = progress.begin(presentation: first, url: root.appendingPathComponent("old")) { shown.append($0) }!
spin { reader.calls == 1 }
progress.end(old)
progress.invalidate() // the old setup panel closes
for index in 0..<40 {
    let id = progress.present()
    _ = progress.begin(presentation: id, url: root.appendingPathComponent("replacement-\(index)")) { shown.append($0) }
}
let current = progress.present()
let active = progress.begin(presentation: current, url: root.appendingPathComponent("current")) { shown.append($0) }!
progress.end(old) // late old operation completion must not cancel the new watch
require(progress.begin(presentation: first, url: root) { shown.append($0) } == nil, "late begin cannot adopt newer presentation")
var heartbeat = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeat += 1 }
spin { heartbeat >= 30 }
timer.invalidate()
require(reader.calls == 1 && shown.isEmpty, "replacement must retain the one physical blocked reader")
reader.gate.signal()
spin { shown == ["current"] }
settle()
require(shown == ["current"], "stale read suppressed, duplicates coalesced")
progress.end(active)
let stoppedCalls = reader.calls
settle()
require(reader.calls <= stoppedCalls + 1, "end stops polling")

// Closing/quitting while a real worker is blocked cannot reopen UI on return.
let closingReader = Reader()
let closing = CyderSetupProgress(interval: 0.01, read: closingReader.read)
let closingID = closing.present()
_ = closing.begin(presentation: closingID, url: root.appendingPathComponent("closed")) { shown.append($0) }
spin { closingReader.calls == 1 }
closing.invalidate()
closingReader.gate.signal()
settle()
require(!shown.contains("closed"), "late read after hide/quit must not show UI")
require(closing.begin(presentation: closingID, url: root) { shown.append($0) } == nil, "quit revokes delayed begin")

// Actual file reader, including missing/invalid transport and continued updates.
let file = root.appendingPathComponent("progress.txt")
let files = CyderSetupProgress(interval: 0.01)
var fileMessages: [String] = []
let fileID = files.present()
_ = files.begin(presentation: fileID, url: file) { fileMessages.append($0) }
settle()
require(fileMessages.isEmpty, "missing file leaves UI unchanged")
try Data("  label=first\n".utf8).write(to: file, options: .atomic)
spin { fileMessages == ["label=first"] }
try Data([0xff, 0xfe]).write(to: file, options: .atomic)
settle()
try Data(repeating: 65, count: 65_537).write(to: file, options: .atomic)
settle()
require(fileMessages == ["label=first"], "invalid and oversize progress ignored")
try Data("label=second\n".utf8).write(to: file, options: .atomic)
spin { fileMessages == ["label=first", "label=second"] }
files.invalidate()
try Data("label=too-late\n".utf8).write(to: file, options: .atomic)
settle()
require(fileMessages.count == 2, "closed presentation receives no more updates")
try Data("complete\n".utf8).write(to: root.appendingPathComponent("complete"))
print("PASS setup progress: late read/begin/end fenced, 40 replacements keep one physical reader, 30 main callbacks, duplicate and invalid data handling")
