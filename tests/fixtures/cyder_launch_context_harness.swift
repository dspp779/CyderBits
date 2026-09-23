import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
final class BlockedResolver: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func resolve(_ path: String) -> String {
        require(!Thread.isMainThread, "resource I/O executed on main thread")
        lock.lock(); entered = true; lock.unlock()
        require(release.wait(timeout: .now() + 10) == .success, "resolver never released")
        return path + "/engine-test.tar.zst"
    }
}
func spin(until predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    require(predicate(), "main event loop deadline")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let resolver = BlockedResolver()
var loaded: CyderLaunchContext?
Task { @MainActor in
    require(Thread.isMainThread, "fixture must call context from main actor")
    loaded = await CyderLaunchContext(resourcePath: root.path, resolveEngine: { resolver.resolve($0) })
}
spin { resolver.started }
var ticks = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in ticks += 1 }
spin { ticks >= 30 }
require(loaded == nil, "blocked resource read unexpectedly completed")
require(CyderLaunchContext.launcherPath(resourcePath: root.path) == root.path + "/ogom-scripts/cyder_launcher.sh", "lexical URI launcher path")
resolver.release.signal()
spin { loaded != nil }
timer.invalidate()
let context = loaded!
require(context.engineSrc == root.path + "/engine-test.tar.zst", "resolved archive")
require(context.environment["CYDER_ENGINE_SRC"] == context.engineSrc, "environment engine source")
require(context.environment["WINE_INSTALL"] == context.engineSrc, "Wine source")
require(context.environment["CYDER_SCRIPTS"] == root.path + "/ogom-scripts", "script location")
require(context.engineVersionFile == root.path + "/engine-version.txt", "version file path")

// Exercise the real on-disk resolver through the asynchronous product API.
func loadReal() -> CyderLaunchContext {
    var result: CyderLaunchContext?
    Task { @MainActor in result = await CyderLaunchContext(resourcePath: root.path) }
    spin { result != nil }
    return result!
}
require(loadReal().engineSrc == root.path + "/engine-payload", "unpacked fallback")
try "CX 26.3 (test)\n".write(to: root.appendingPathComponent("engine-version.txt"), atomically: true, encoding: .utf8)
let archive = root.appendingPathComponent("engine-CX-26-3-test.tar.zst")
try Data().write(to: archive)
require(loadReal().engineSrc == archive.path, "version slug archive fallback")
let named = root.appendingPathComponent("custom.tar.zst")
try Data().write(to: named)
try "custom.tar.zst\n".write(to: root.appendingPathComponent("engine-archive.txt"), atomically: true, encoding: .utf8)
require(loadReal().engineSrc == named.path, "archive manifest takes precedence")
try FileManager.default.removeItem(at: named)
require(loadReal().engineSrc == archive.path, "missing manifest archive falls back")
print("PASS: context I/O off main; 30 main-run-loop callbacks while blocked; archive/environment behavior preserved")
try Data("complete\n".utf8).write(to: root.appendingPathComponent("complete"))
