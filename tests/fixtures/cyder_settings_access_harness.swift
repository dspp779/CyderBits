import Foundation
import Darwin
func pump(_ condition: () -> Bool, timeout: TimeInterval = 10) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "missing settings completion")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let url = root.appendingPathComponent("settings.json")
let baseline = CyderSettings(fontMingLiuTarget: "songti")
let backend = CyderSettingsStore(value: baseline, url: url)
try backend.update { $0.dpi = 96 }
let original = try CyderSettingsStore.readValidated(at: url)
var first = original; first.dpi = 144
var second = original; second.wineDiagnostics = .errors
let access = CyderSettingsAccess(url: url)
var done = false
access.perform({ store in
    precondition(!Thread.isMainThread)
    try store.apply(.init(before: original, after: first))
}) { event in if case .ready = event { done = true } }
pump { done }; done = false
access.perform({ store in try store.apply(.init(before: original, after: second)); return store.value }) { event in
    if case .ready(let value) = event { precondition(value.dpi == 144 && value.wineDiagnostics == .errors); done = true }
}
pump { done }; done = false
let beforeConflict = try Data(contentsOf: url)
var conflicting = original; conflicting.dpi = 192
access.perform({ store in try store.apply(.init(before: original, after: conflicting)) }) { event in
    if case .failed(let error) = event { precondition(error is CyderSettingsAccess.Failure); done = true }
}
pump { done }
let afterConflict = try Data(contentsOf: url)
precondition(beforeConflict == afterConflict, "conflict rewrote settings")
var oneProfile = original, twoProfiles = original
oneProfile.perProfile["profile-aaaaaaaaaaaaaaaaaaaaaaaa"] = CyderExecutableSettings(arguments: ["one"])
twoProfiles.perProfile["profile-bbbbbbbbbbbbbbbbbbbbbbbb"] = CyderExecutableSettings(arguments: ["two"])
var merged = original
try CyderSettingsPatch(before: original, after: oneProfile).apply(to: &merged)
try CyderSettingsPatch(before: original, after: twoProfiles).apply(to: &merged)
precondition(merged.perProfile.count == 2)
try Data("corrupt".utf8).write(to: url)
done = false
access.perform({ store in try store.update { $0.dpi = 240 } }) { event in if case .failed = event { done = true } }
pump { done }
let corruptBytes = try Data(contentsOf: url)
precondition(corruptBytes == Data("corrupt".utf8), "corrupt history was replaced with defaults")
try FileManager.default.removeItem(at: url)
precondition(mkfifo(url.path, 0o600) == 0)
do { _ = try CyderSettingsStore.readValidated(at: url); fatalError("FIFO should fail without blocking") } catch {}
try FileManager.default.removeItem(at: url)
let gate = DispatchSemaphore(value: 0)
let lock = NSLock(); var reads = 0
let stalled = CyderSettingsAccess(url: url, deadline: 0.03, read: { _ in
    precondition(!Thread.isMainThread)
    lock.lock(); reads += 1; lock.unlock()
    gate.wait(); return original
})
var pendingEvents = 0, readyEvents = 0, busyEvents = 0
stalled.perform({ $0.value }) { event in
    if case .unconfirmed = event { pendingEvents += 1 }
    if case .ready = event { readyEvents += 1 }
}
pump { pendingEvents == 1 }
for _ in 0..<60 { stalled.perform({ $0.value }) { event in if case .busy = event { busyEvents += 1 } } }
precondition(busyEvents == 60 && readyEvents == 0)
lock.lock(); precondition(reads == 1); lock.unlock()
gate.signal(); pump { readyEvents == 1 }
precondition(pendingEvents == 1)
let quitGate = DispatchSemaphore(value: 0)
let quitting = CyderSettingsAccess(url: url, deadline: 0.03, read: { _ in quitGate.wait(); return original })
var quitEvents = 0, physicalReturned = false
quitting.perform({ _ in DispatchQueue.main.async { physicalReturned = true }; return true }) { _ in quitEvents += 1 }
quitting.quiesce(); quitGate.signal(); pump { physicalReturned }
RunLoop.main.run(until: Date().addingTimeInterval(0.06))
precondition(quitEvents == 0)
var rejected = false
quitting.perform({ _ in fatalError("work after quit") }) { event in if case .busy = event { rejected = true } }
precondition(rejected)
print("PASS settings owner: real disk merge/conflict/corruption, bounded stalled worker, deadline/late completion, quit fence, FIFO")
