import Foundation
import Darwin

/// Shared graphics changes require complete, current process evidence. No argv/env reads.
enum CyderGraphicsRuntime {
    enum State: Equatable { case idle, busy, unknown }
    struct Entry { let pid: Int32; let uid: uid_t; let image: String?; let gone: Bool }
    static var needsGlobalScope: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent("ogom-scripts/cyder-graphics-update.rb").path)
    }
    static func inventory() -> [Entry]? {
        precondition(!Thread.isMainThread)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var values = [kinfo_proc](repeating: kinfo_proc(), count: 8192)
        var size = values.count * MemoryLayout<kinfo_proc>.stride
        let result = values.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > 0, size < values.count * MemoryLayout<kinfo_proc>.stride,
              size % MemoryLayout<kinfo_proc>.stride == 0 else { return nil }
        return values.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { value in
            let pid = value.kp_proc.p_pid
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            errno = 0
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
            if count != MemoryLayout<proc_bsdinfo>.stride {
                return Entry(pid: pid, uid: getuid(), image: nil, gone: errno == ESRCH)
            }
            var bytes = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            return Entry(pid: pid, uid: info.pbi_uid, image: length > 0 ? String(cString: bytes) : nil, gone: info.pbi_status == SZOMB)
        }
    }
    static func classify(_ entries: [Entry]?, engines: String, uid: uid_t = getuid()) -> State {
        guard let entries else { return .unknown }
        var uncertain = false
        for entry in entries where entry.uid == uid && !entry.gone {
            guard let image = entry.image else { uncertain = true; continue }
            let name = URL(fileURLWithPath: image).lastPathComponent.lowercased()
            if image.hasPrefix(engines + "/") || name.hasSuffix(".exe") ||
                ["wine", "wine64", "wineserver", "wineloader", "wine-preloader", "wine64-preloader"].contains(name) { return .busy }
        }
        return uncertain ? .unknown : .idle
    }
    static func probe(engines: String, read: () -> [Entry]? = inventory, pause: () -> Void = { usleep(50_000) }) -> State {
        let first = classify(read(), engines: engines)
        guard first == .idle else { return first }
        pause()
        return classify(read(), engines: engines)
    }
    static func run(arguments: [String]) -> Int32 {
        if arguments.count == 3, arguments[1] == "--graphics-runtime-state", arguments[2].hasPrefix("/") {
            switch probe(engines: arguments[2]) {
            case .idle: print("cyder-graphics-v1 idle"); return 10
            case .busy: print("cyder-graphics-v1 busy"); return 0
            case .unknown: return 75
            }
        }
        guard arguments.count == 7, arguments[1] == "--graphics-update-guard",
              arguments[2...6].allSatisfy({ $0.hasPrefix("/") }) else { return 64 }
        do {
            return try CyderExecutionOwner.withScope(root: URL(fileURLWithPath: arguments[2]), scope: nil) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
                process.arguments = [arguments[3] + "/ogom-scripts/cyder-graphics-update.rb", "apply",
                    "--resources", arguments[3], "--runtime", arguments[4], "--engine", arguments[5], "--prefix", arguments[6]]
                var environment = ProcessInfo.processInfo.environment
                environment["CYDER_EXECUTION_RUNTIME_MUTATION"] = "1"
                process.environment = environment
                try process.run(); process.waitUntilExit()
                return process.terminationReason == .exit ? process.terminationStatus : 75
            }
        } catch { return 75 }
    }
}
