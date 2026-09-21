import Cocoa
import Foundation
import Darwin
enum CyderPaths { static let support = URL(fileURLWithPath: CommandLine.arguments[1]) }
func pump(_ condition: () -> Bool, timeout: TimeInterval = 6) {
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    guard condition() else { fputs("FAIL request UI deadline\n", stderr); exit(1) }
}
func result<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
    var value: T?; work { value = $0 }; pump { value != nil }; return value!
}
func ok<T>(_ value: Result<T, CyderRequestJournal.Failure>) -> T {
    guard case .success(let data) = value else { fatalError("\(value)") }; return data
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let journal = CyderRequestJournal(directory: CyderPaths.support.appendingPathComponent("request-journal"))
_ = ok(result { journal.open(completion: $0) })
let namespace: UUID = result { done in journal.namespace { done($0!) } }
func seed(_ path: String) -> CyderRequestJournal.Record {
    ok(result { journal.submit(id: CyderRequestJournal.makeID(namespace: namespace),
        payload: .init(files: [path], arguments: ["secret-never-display"], urls: [], showUI: false), completion: $0) })
}
let resume = seed("/trusted/繼續測試.exe"), cancel = seed("/trusted/取消測試.exe"), uncertain = seed("/trusted/結果未確認.exe")
let failed = seed("/trusted/啟動失敗.exe")
let failedDispatch = ok(result { journal.authorizeDispatch(id: failed.id, completion: $0) })
let failedRecord = ok(result { journal.complete(id: failed.id, launchID: failedDispatch.launchID!, epoch: failedDispatch.executorEpoch!, outcome: "precheck-failed", failed: true, completion: $0) })
precondition(failedRecord.payload == nil && failedRecord.displayName == "啟動失敗.exe")
_ = ok(result { journal.authorizeDispatch(id: uncertain.id, completion: $0) })
let _: Bool = result { done in journal.close { done(true) } }

let controller = CyderRequestWindowController()
let coordinator = CyderInstanceCoordinator(support: CyderPaths.support, bundleID: "request-ui-test")
var delivered: [CyderInstanceRequest] = [], cancelled: [String] = []
coordinator.onRecoveryChanged = { controller.update($0) }
coordinator.onRequestCancelled = { cancelled.append($0) }
controller.onResume = { coordinator.resumeRequest(id: $0, completion: $1) }
controller.onCancel = { coordinator.cancelRequest(id: $0, completion: $1) }
let role = result { done in coordinator.start(onRequest: { delivered.append($0) }, completion: done) }
precondition(role == .primary && delivered.isEmpty, "restoration automatically replayed a request")
precondition(controller.rows.count == 4)
precondition(controller.rows.first { $0.id == failed.id }?.title == "啟動失敗.exe")
if let path = ProcessInfo.processInfo.environment["CYDER_TEST_RENDER"] {
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
precondition(controller.rows.first { $0.id == uncertain.id }?.canResume == false)
controller.perform(.resume, id: uncertain.id)
controller.perform(.cancel, id: uncertain.id)
precondition(delivered.isEmpty && cancelled.isEmpty, "uncertain UI offered unsafe action")
precondition(!String(describing: controller.rows).contains("secret-never-display"))

// Use the production table-cell button and selector, then production coordinator
// and durable journal. This is an AppKit adapter test, not a second fake UI.
func click(_ id: String, tag: Int) -> NSButton {
    let index = controller.rows.firstIndex { $0.id == id }!
    let view = controller.tableView(NSTableView(), viewFor: nil, row: index)!
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let button = buttons(view).first { $0.tag == tag }!
    button.performClick(nil)
    return button
}
let staleCancelButton = click(cancel.id, tag: 1)
pump { cancelled == [cancel.id] && !controller.rows.contains { $0.id == cancel.id } }
staleCancelButton.performClick(nil)
precondition(cancelled.count == 1, "stale row action bypassed current capability")
_ = click(resume.id, tag: 0)
pump { delivered.count == 1 }
precondition(delivered[0].record.id == resume.id && delivered[0].record.phase == .queued)
var denied: Bool?; coordinator.resumeRequest(id: uncertain.id) { denied = $0 }; pump { denied != nil }
precondition(denied == false)

let authorized = result { coordinator.authorize(delivered[0].record, completion: $0) }!
coordinator.finish(authorized, outcome: "observation-deadline", uncertain: true)
pump { coordinator.recovered.first { $0.id == resume.id }?.phase == .uncertain }
coordinator.refreshRequests()
controller.update(coordinator.recovered)
precondition(controller.rows.allSatisfy { !$0.canResume && !$0.canCancel })
let _: Bool = result { coordinator.quiesce(completion: $0) }
let _: Bool = result { done in coordinator.stop { done(true) } }
let finalJournal = CyderRequestJournal(directory: CyderPaths.support.appendingPathComponent("request-journal"))
let records = ok(result { finalJournal.open(completion: $0) })
precondition(records.first { $0.id == cancel.id }?.phase == .cancelled)
precondition(records.filter { $0.phase == .uncertain }.count == 2)
let _: Bool = result { done in finalJournal.close { done(true) } }
try Data("PASS\n".utf8).write(to: CyderPaths.support.appendingPathComponent("ui-completed"))
print("PASS formal AppKit request actions: no replay, resume only awaiting, durable cancel, stale button, uncertain disabled, argv hidden, reopened state")
