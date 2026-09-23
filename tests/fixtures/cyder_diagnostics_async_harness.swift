import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
    if !condition() { fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
func pump(_ condition: () -> Bool) {
    let until = ProcessInfo.processInfo.systemUptime + 8
    while !condition(), ProcessInfo.processInfo.systemUptime < until {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    check(condition(), "diagnostic callback deadline")
}
final class Counter {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for blockedCall in [1, 2] {
    let directory = root.appendingPathComponent("blocked-\(blockedCall)")
    let counter = Counter(), gate = DispatchSemaphore(value: 0)
    let diagnostics = CyderDiagnostics(support: directory, redirectStreams: false, beforeIO: {
        check(!Thread.isMainThread, "diagnostic I/O entered main")
        if counter.increment() == blockedCall { gate.wait() }
    })
    diagnostics.info("first")
    pump { counter.value == blockedCall }
    for i in 0..<10_000 { diagnostics.info("queued \(i)") }
    diagnostics.info(String(repeating: "x", count: 100_000))
    for i in 0..<1_000 {
        diagnostics.record(.init(code: "F\(i)", stage: .bootstrap, summary: "latest error",
            technicalDetails: String(repeating: "x", count: 20_000)))
    }
    check(diagnostics.pendingWriteCount <= 128, "stalled writer grew an unbounded backlog")
    check(counter.value == blockedCall, "stalled writer created another physical operation")
    var ticks = 0
    let timer = Timer(timeInterval: 0.002, repeats: true) { _ in ticks += 1 }
    RunLoop.main.add(timer, forMode: .common)
    pump { ticks >= 30 }; timer.invalidate()
    let finishStart = ProcessInfo.processInfo.systemUptime
    diagnostics.finish(outcome: "bounded-quit")
    check(ProcessInfo.processInfo.systemUptime - finishStart < 0.1, "finish waited for blocked diagnostics")
    diagnostics.enter(.wineSpawn, detail: "late stage must not revive finished session")
    diagnostics.finish(outcome: "duplicate")
    var flushed = false
    diagnostics.flush { DispatchQueue.main.async { flushed = true } }
    check(!flushed, "flush falsely completed while writer was blocked")
    gate.signal()
    pump { flushed }
    let state = try! JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Logs/session-state.json"))) as! [String: Any]
    check(state["state"] as? String == "completed" && state["stage"] as? String == "completed", "finish state lost")
    check(state["outcome"] as? String == "bounded-quit", "duplicate finish overwrote first outcome")
    let error = try! JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Logs/last-error.json"))) as! [String: Any]
    check(error["code"] as? String == "F999", "latest error lost under ordinary log backlog")
    check((error["technicalDetails"] as? String)?.utf8.count == 16_384, "error payload was not bounded")
    let log = try! String(contentsOf: diagnostics.sessionLogURL, encoding: .utf8)
    check(log.contains("diagnostic backlog dropped="), "dropped diagnostics were not disclosed")
    check(diagnostics.pendingWriteCount == 0, "drained writer retained its reservation")
    diagnostics.warning("cleanup-unconfirmed")
    flushed = false
    diagnostics.flush { DispatchQueue.main.async { flushed = true } }
    pump { flushed }
    let finalLog = try! String(contentsOf: diagnostics.sessionLogURL, encoding: .utf8)
    check(finalLog.contains("cleanup-unconfirmed"), "final cleanup warning was dropped")
    print("PASS diagnostic I/O stall \(blockedCall): 30 main timers, 128 queued cap, latest error, bounded payload, finish/recovery state, no late stage")
}
try! Data("complete\n".utf8).write(to: root.appendingPathComponent("complete"))
