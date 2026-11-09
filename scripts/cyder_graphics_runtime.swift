import Foundation
import Darwin

/// Shared graphics changes require complete, current process evidence. No argv/env reads.
enum CyderGraphicsRuntime {
    enum State: Equatable { case idle, busy, unknown }
    struct Entry {
        let pid: Int32; let uid: uid_t; let image: String?; let gone: Bool
        var signedOtherPublisherWithMissingImage = false
    }
    struct Identity: Equatable {
        let pid: Int32; let uid: uid_t; let seconds: UInt64; let micros: UInt64
        init(_ info: proc_bsdinfo) {
            pid = Int32(info.pbi_pid); uid = info.pbi_uid
            seconds = info.pbi_start_tvsec; micros = info.pbi_start_tvusec
        }
        init(pid: Int32, uid: uid_t, seconds: UInt64, micros: UInt64) {
            self.pid = pid; self.uid = uid; self.seconds = seconds; self.micros = micros
        }
    }
    struct CodeIdentity: Equatable { let flags: UInt32; let team: String; let cdHash: [UInt8] }
    // Same publisher contract as CyderIntegrity::TEAM, not an exclusion for a named app.
    static let enginePublisherTeam = "3U9565WWM2"
    private typealias CSOps = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let csops: CSOps? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        return unsafeBitCast(symbol, to: CSOps.self)
    }()
    static func parseTeam(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 9 else { return nil }
        let length = bytes[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 8, length <= bytes.count, bytes[length - 1] == 0,
              length == 19, // kernel blob header + ten-character Apple team + NUL
              bytes[8..<(length - 1)].allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return String(bytes: bytes[8..<(length - 1)], encoding: .ascii)
    }
    static func liveCode(_ pid: Int32) -> CodeIdentity? {
        guard let csops else { return nil } // Optional kernel API; absence never proves idle.
        var flags: UInt32 = 0, hash = [UInt8](repeating: 0, count: 20), team = [UInt8](repeating: 0, count: 256)
        // CS_OPS_STATUS, CS_OPS_CDHASH, CS_OPS_TEAMID read the live kernel signature blob.
        guard csops(pid, 0, &flags, 4) == 0, csops(pid, 5, &hash, hash.count) == 0,
              csops(pid, 14, &team, team.count) == 0, let value = parseTeam(team) else { return nil }
        return CodeIdentity(flags: flags, team: value, cdHash: hash)
    }
    static func identity(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB, info.pbi_pid == pid else { return nil }
        return Identity(info)
    }
    static func unrelatedMissingImage(pid: Int32, before: Identity, pathError: Int32,
                                      readIdentity: (Int32) -> Identity? = identity,
                                      readCode: (Int32) -> CodeIdentity? = liveCode) -> Bool {
        guard pathError == ENOENT, before.pid == pid, before.uid == getuid(),
              readIdentity(pid) == before, let first = readCode(pid),
              readIdentity(pid) == before, let second = readCode(pid), first == second,
              readIdentity(pid) == before,
              first.flags & 0x1 != 0, // CS_VALID
              first.flags & (0x2 | 0x10000000) == 0, // neither CS_ADHOC nor CS_DEBUGGED
              first.cdHash.count == 20, first.cdHash.contains(where: { $0 != 0 }),
              first.team.count == 10, first.team != enginePublisherTeam else { return false }
        return true
    }
    static func failureSummary(status: Int32, output: String) -> String {
        guard status == 75 else { return "準備圖形元件時發生問題。請開啟診斷記錄查看原因。" }
        let report = output.split(whereSeparator: { $0.isNewline }).reversed().compactMap { line -> [String: String]? in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  value["status"] == "deferred" else { return nil }
            return value
        }.first
        switch report?["reason"] {
        case "publisher_unverified":
            return "無法確認此 App 的發行者。請使用 Developer ID 簽署的 Cyder，再準備圖形元件。"
        case "system_signature_verifier_unavailable":
            return "系統簽章驗證服務暫時無法使用。請稍後重試，或開啟診斷記錄查看原因。"
        case "windows_busy_retry_when_idle":
            return "圖形元件更新已延後。請關閉 Windows 程序後重試。"
        default:
            return "圖形元件準備已暫停。請開啟診斷記錄確認原因後重試。"
        }
    }
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
            errno = 0
            let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            let pathError = errno
            let unrelated = length <= 0 && info.pbi_status != SZOMB && unrelatedMissingImage(pid: pid, before: Identity(info), pathError: pathError)
            return Entry(pid: pid, uid: info.pbi_uid, image: length > 0 ? String(cString: bytes) : nil,
                         gone: info.pbi_status == SZOMB, signedOtherPublisherWithMissingImage: unrelated)
        }
    }
    static func classify(_ entries: [Entry]?, engines: String, uid: uid_t = getuid(), targetPrefix: State = .unknown) -> State {
        guard let entries else { return .unknown }
        var uncertain = false
        for entry in entries where entry.uid == uid && !entry.gone {
            guard let image = entry.image else {
                if entry.signedOtherPublisherWithMissingImage {
                    if targetPrefix == .busy { return .busy }
                    if targetPrefix == .idle { continue }
                }
                uncertain = true; continue
            }
            let name = URL(fileURLWithPath: image).lastPathComponent.lowercased()
            if image.hasPrefix(engines + "/") || name.hasSuffix(".exe") ||
                ["wine", "wine64", "wineserver", "wineloader", "wine-preloader", "wine64-preloader"].contains(name) { return .busy }
        }
        return uncertain ? .unknown : .idle
    }
    static func prefixState(prefix: String?, server: String?) -> State {
        guard let prefix, prefix.hasPrefix("/"), let server, server.hasPrefix("/") else { return .unknown }
        var info = stat()
        if lstat(prefix, &info) != 0 { return errno == ENOENT ? .idle : .unknown }
        guard let target = CyderEnvironmentProbe.identify(prefix: URL(fileURLWithPath: prefix), engine: URL(fileURLWithPath: server)) else { return .unknown }
        switch CyderEnvironmentProbe.inspect(target) {
        case .empty: return .idle
        case .alive: return .busy
        case .unknown: return .unknown
        }
    }
    static func probe(engines: String, prefix: String? = nil, server: String? = nil,
                      read: () -> [Entry]? = inventory, pause: () -> Void = { usleep(50_000) },
                      readPrefix: (String?, String?) -> State = prefixState) -> State {
        func sample() -> State {
            let entries = read()
            let needsPrefix = entries?.contains { $0.signedOtherPublisherWithMissingImage && !$0.gone && $0.uid == getuid() } == true
            return classify(entries, engines: engines, targetPrefix: needsPrefix ? readPrefix(prefix, server) : .unknown)
        }
        let first = sample()
        guard first == .idle else { return first }
        pause()
        return sample()
    }
    static func run(arguments: [String]) -> Int32 {
        if [3, 5].contains(arguments.count), arguments[1] == "--graphics-runtime-state",
           arguments.dropFirst(2).allSatisfy({ $0.hasPrefix("/") }) {
            switch probe(engines: arguments[2], prefix: arguments.count == 5 ? arguments[3] : nil,
                         server: arguments.count == 5 ? arguments[4] : nil) {
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
