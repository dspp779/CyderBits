import Foundation
import Darwin
import CryptoKit

/// Per-EXE winemac `UsePreciseScrolling` (HKCU\Software\Wine\AppDefaults\<exe>\Mac Driver).
///
/// Cost model (runs before every EXE launch, so the common path must be free):
/// - The current value is read from `user.reg` directly. When it already matches,
///   nothing else happens: no Wine process, no write.
/// - When the prefix's wineserver is not running, `user.reg` is authoritative and
///   is edited in place with an atomic rename. Still no Wine process.
/// - Only a running prefix (whose in-memory registry would overwrite a file edit)
///   uses Wine: exactly one `reg add` / `reg delete`.
/// A running wineserver flushes `user.reg` periodically, so the on-disk value can
/// lag an external regedit by seconds; Cyder is the only expected writer of this
/// AppDefaults value, so a matching disk value is accepted as current.
///
/// The original value is backed up once (format shared with the former Ruby tool,
/// `{"version":1,"original":"\"N\""|null}`) and `restore` puts it back.
enum CyderScrollingRegistry {
    enum Mode: String { case traditional, precise, restore, status }
    enum Failure: Error, CustomStringConvertible {
        case usage, invalidName, notInitialized, unsupportedValue, duplicate, busy, unsafePath(String),
             invalidBackup, unreadable, registry(String), verification
        var description: String {
            switch self {
            case .usage: return "Usage: CyderSwift --scrolling traditional|precise|restore|status <prefix> <wine> <EXE filename> [--prefix-running]"
            case .invalidName: return "A plain EXE filename is required"
            case .notInitialized: return "An initialized Wine prefix is required"
            case .unsupportedValue: return "Existing UsePreciseScrolling is not a supported REG_SZ; nothing changed"
            case .duplicate: return "Duplicate scrolling registry entries; nothing changed"
            case .busy: return "Another scrolling update is running"
            case .unsafePath(let what): return "\(what) must not be a symlink"
            case .invalidBackup: return "Invalid scrolling backup; nothing changed"
            case .unreadable: return "Wine registry file could not be read; nothing changed"
            case .registry(let detail): return "Wine registry update failed; backup retained for retry: \(detail)"
            case .verification: return "Registry write verification failed; backup retained"
            }
        }
    }
    static let valueName = "UsePreciseScrolling"
    /// Values Cyder can round-trip exactly through user.reg and `reg add /d`.
    static func isSimple(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value >= 0x20 && $0.value != 0x7f && $0 != "\"" && $0 != "\\"
        }
    }
    static func validName(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".exe"), name.count > 4,
              name.utf16.count * 2 < 520 else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f && !"\\/[]\":*?<>|".unicodeScalars.contains($0)
        }
    }
    /// ASCII names are written by Wine verbatim (with `\` doubled); others use
    /// `\x` escapes, which Cyder does not rewrite and leaves to `reg.exe`.
    static func fileEditable(_ name: String) -> Bool { name.unicodeScalars.allSatisfy { $0.isASCII } }

    // MARK: user.reg

    struct RegistryFile {
        var lines: [Substring]
        let identity: stat
        let trailingNewline: Bool
        /// Bracketed key path of this EXE's section, as Wine writes it.
        static func header(_ name: String) -> String {
            "[Software\\\\Wine\\\\AppDefaults\\\\" + name + "\\\\Mac Driver]"
        }
        static func read(_ url: URL) throws -> RegistryFile {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ENOENT ? Failure.notInitialized : Failure.unreadable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= 256 * 1024 * 1024 else { throw Failure.unreadable }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            guard data.count == Int(info.st_size), let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("WINE REGISTRY Version 2") else { throw Failure.unreadable }
            return RegistryFile(lines: text.split(separator: "\n", omittingEmptySubsequences: false),
                                identity: info, trailingNewline: text.hasSuffix("\n"))
        }
        private func isHeader(_ line: Substring, _ header: String) -> Bool {
            guard line.count >= header.count,
                  line.prefix(header.count).caseInsensitiveCompare(header) == .orderedSame else { return false }
            let rest = line.dropFirst(header.count)
            return rest.isEmpty || rest.first == " "
        }
        /// (section header index, value line index) for this EXE.
        func locate(_ name: String) throws -> (section: Int?, value: Int?) {
            let header = Self.header(name)
            var section: Int?, value: Int?
            var inside = false
            let prefix = "\"" + valueName + "\"="
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("[") {
                    inside = isHeader(line, header)
                    if inside { guard section == nil else { throw Failure.duplicate }; section = index }
                } else if inside, line.count >= prefix.count,
                          line.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame {
                    guard value == nil else { throw Failure.duplicate }
                    value = index
                }
            }
            return (section, value)
        }
        /// nil = value absent. Only plain REG_SZ is accepted.
        func value(_ name: String) throws -> String? {
            guard let index = try locate(name).value else { return nil }
            let raw = lines[index].dropFirst(valueName.count + 3)
            guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { throw Failure.unsupportedValue }
            let inner = String(raw.dropFirst().dropLast())
            guard isSimple(inner) else { throw Failure.unsupportedValue }
            return inner
        }
        mutating func set(_ name: String, _ value: String?, now: Date = Date()) throws {
            let (section, existing) = try locate(name)
            let line = value.map { Substring("\"" + valueName + "\"=\"" + $0 + "\"") }
            if let existing {
                if let line { lines[existing] = line } else {
                    lines.remove(at: existing)
                    // Drop a section left with only its header and metadata;
                    // an absent key and an empty one read the same to winemac.
                    if let section {
                        var end = section + 1
                        while end < lines.count, lines[end].hasPrefix("#") { end += 1 }
                        if end == lines.count || lines[end].isEmpty || lines[end].hasPrefix("[") {
                            if end < lines.count, lines[end].isEmpty { end += 1 }
                            lines.removeSubrange(section..<end)
                        }
                    }
                }
            } else if let line {
                if let section {
                    var insert = section + 1
                    while insert < lines.count, lines[insert].hasPrefix("#") { insert += 1 }
                    lines.insert(line, at: insert)
                } else {
                    let seconds = Int64(now.timeIntervalSince1970)
                    let filetime = UInt64(seconds + 11_644_473_600) * 10_000_000
                    if let last = lines.last, last.isEmpty { lines.removeLast() }
                    if let last = lines.last, !last.isEmpty { lines.append("") }
                    lines += [Substring(Self.header(name) + " \(seconds)"),
                              Substring("#time=" + String(filetime, radix: 16)), line, ""]
                }
            }
        }
        func data() -> Data {
            var text = lines.joined(separator: "\n")
            if trailingNewline, !text.hasSuffix("\n") { text += "\n" }
            return Data(text.utf8)
        }
    }

    // MARK: running prefix

    /// Mirrors Wine's server directory: <tmp>/.wine-<uid>/server-<dev>-<ino>/socket.
    static func serverSocketExists(prefix: URL) -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let leaf = ".wine-\(getuid())/server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))/socket"
        var roots = ["/tmp"]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty { roots.append(tmp) }
        return roots.contains { root in
            var socket = stat()
            return lstat((root as NSString).appendingPathComponent(leaf), &socket) == 0 && socket.st_mode & S_IFMT == S_IFSOCK
        }
    }

    // MARK: state

    struct Paths {
        let prefix: URL
        let state: URL
        init(prefix: URL, name: String) {
            self.prefix = prefix
            // Keep the original MapleStory baseline from the earlier explicit tool.
            if name.caseInsensitiveCompare("MapleStory.exe") == .orderedSame {
                state = prefix.appendingPathComponent(".cyder-maplestory-scrolling")
            } else {
                let digest = SHA256.hash(data: Data(name.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
                state = prefix.appendingPathComponent(".cyder-scrolling").appendingPathComponent(digest)
            }
        }
        var backup: URL { state.appendingPathComponent("original.json") }
        /// Present after a live reg.exe write until an idle run sees user.reg
        /// again: until wineserver flushes, the file may still show the old value.
        var pendingLive: URL { state.appendingPathComponent("pending-live") }
    }
    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
    /// Returns .some(nil) for a saved "absent" original, nil when there is no backup.
    static func readBackup(_ url: URL) throws -> String?? {
        guard !isSymlink(url) else { throw Failure.unsafePath("Scrolling backup") }
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1, object.keys.contains("original") else { throw Failure.invalidBackup }
        if object["original"] is NSNull { return .some(nil) }
        guard let literal = object["original"] as? String, literal.count >= 2,
              literal.hasPrefix("\""), literal.hasSuffix("\"") else { throw Failure.invalidBackup }
        let inner = String(literal.dropFirst().dropLast())
        guard isSimple(inner) else { throw Failure.invalidBackup }
        return .some(inner)
    }
    static func writeBackup(_ url: URL, original: String?) throws {
        let object: [String: Any] = ["version": 1, "original": original.map { "\"" + $0 + "\"" } ?? NSNull()]
        try atomicWrite(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url, mode: 0o600)
    }
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".cyder-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { Darwin.close(fd); unlink(temporary.path) }
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        guard ok, fchmod(fd, mode) == 0, fsync(fd) == 0,
              rename(temporary.path, url.path) == 0 else { throw Failure.unreadable }
    }

    // MARK: Wine fallback (running prefix only)

    typealias WineRunner = (_ arguments: [String]) -> (status: Int32, output: String)
    static func defaultRunner(prefix: URL, wine: URL, timeout: TimeInterval = 60) -> WineRunner {
        { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            process.arguments = ["-x86_64", wine.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix.path
            environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
            process.environment = environment
            // Never a pipe: Wine's services/explorer/winedevice inherit stdio and
            // can outlive reg.exe, so EOF would wait for the whole wineserver.
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("cyder-scrolling-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: log) else { return (127, "cannot create log") }
            defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
            process.standardOutput = handle; process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return (127, "\(error)") }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                _ = exited.wait(timeout: .now() + 5)
                return (124, "reg.exe did not finish within \(Int(timeout))s")
            }
            let output = (try? Data(contentsOf: log)) ?? Data()
            return (process.terminationStatus, String(decoding: output.suffix(2048), as: UTF8.self))
        }
    }
    static func registryKey(_ name: String) -> String { "HKCU\\Software\\Wine\\AppDefaults\\\(name)\\Mac Driver" }

    // MARK: operation

    struct Outcome: Equatable { let value: String?; let wineCalls: Int; let fileWrites: Int }

    static func apply(mode: Mode, prefix: URL, name: String, prefixRunning: Bool,
                      runner: WineRunner, isServerRunning: (URL) -> Bool = serverSocketExists) throws -> Outcome {
        guard validName(name) else { throw Failure.invalidName }
        let userReg = prefix.appendingPathComponent("user.reg")
        let paths = Paths(prefix: prefix, name: name)
        let current = try RegistryFile.read(userReg)
        let observed = try current.value(name)
        if mode == .status { return Outcome(value: observed, wineCalls: 0, fileWrites: 0) }
        if mode == .restore, !FileManager.default.fileExists(atPath: paths.backup.path), !isSymlink(paths.backup) {
            return Outcome(value: observed, wineCalls: 0, fileWrites: 0)
        }
        for url in [paths.state, prefix.appendingPathComponent(".cyder-scrolling")] where isSymlink(url) {
            throw Failure.unsafePath("Scrolling state")
        }
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = paths.state.appendingPathComponent("lock")
        guard !isSymlink(lockURL) else { throw Failure.unsafePath("Scrolling lock") }
        let lock = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure.unreadable }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }

        var fileWrites = 0, wineCalls = 0
        let saved = try readBackup(paths.backup)
        let desired: String?
        switch mode {
        case .traditional, .precise:
            desired = mode == .traditional ? "N" : "Y"
            // Durable baseline before any registry change, so a failed or
            // interrupted update can always be retried or restored.
            if saved == nil { try writeBackup(paths.backup, original: observed); fileWrites += 1 }
        case .restore:
            guard let original = saved else { return Outcome(value: observed, wineCalls: 0, fileWrites: 0) }
            desired = original
        case .status: desired = observed
        }

        let live = prefixRunning || isServerRunning(prefix)
        let diskStale = live && FileManager.default.fileExists(atPath: paths.pendingLive.path)
        if !live { unlink(paths.pendingLive.path) } // an idle prefix has flushed every live write
        if observed != desired || diskStale {
            var written = false
            if !live, fileEditable(name) {
                var next = current
                try next.set(name, desired)
                // Refuse if anything rewrote user.reg or started a server meanwhile.
                var now = stat()
                if lstat(userReg.path, &now) == 0, now.st_ino == current.identity.st_ino,
                   now.st_size == current.identity.st_size,
                   now.st_mtimespec.tv_sec == current.identity.st_mtimespec.tv_sec,
                   now.st_mtimespec.tv_nsec == current.identity.st_mtimespec.tv_nsec,
                   !isServerRunning(prefix) {
                    try atomicWrite(next.data(), to: userReg, mode: current.identity.st_mode & 0o7777)
                    fileWrites += 1
                    // A server that started during the rename may have loaded the
                    // old file; let reg.exe set the live value too.
                    written = !isServerRunning(prefix)
                    if written, try RegistryFile.read(userReg).value(name) != desired { throw Failure.verification }
                }
            }
            if !written {
                let key = registryKey(name)
                let arguments = desired.map { ["reg", "add", key, "/v", valueName, "/t", "REG_SZ", "/d", $0, "/f"] }
                    ?? ["reg", "delete", key, "/v", valueName, "/f"]
                var result = runner(arguments)
                wineCalls += 1
                if result.status != 0, desired == nil {
                    // reg delete also fails when the value is already absent;
                    // confirm absence rather than parse localized messages.
                    let query = runner(["reg", "query", key, "/v", valueName])
                    wineCalls += 1
                    if query.status != 0 { result.status = 0 }
                }
                guard result.status == 0 else {
                    throw Failure.registry(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if isServerRunning(prefix) || live {
                    try atomicWrite(Data(), to: paths.pendingLive, mode: 0o600)
                }
            }
        }
        if mode == .restore { unlink(paths.backup.path) }
        return Outcome(value: desired, wineCalls: wineCalls, fileWrites: fileWrites)
    }

    /// `CyderSwift --scrolling <mode> <prefix> <wine> <exe> [--prefix-running]`
    static func run(arguments: [String]) -> Int32 {
        let args = Array(arguments.dropFirst(2))
        do {
            guard (4...5).contains(args.count), let mode = Mode(rawValue: args[0]),
                  args.count == 4 || args[4] == "--prefix-running" else { throw Failure.usage }
            let prefix = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
            let wine = URL(fileURLWithPath: args[2])
            let outcome = try apply(mode: mode, prefix: prefix, name: args[3], prefixRunning: args.count == 5,
                                    runner: defaultRunner(prefix: prefix, wine: wine))
            print("\(args[3]) UsePreciseScrolling: \(outcome.value.map { "\"\($0)\"" } ?? "(inherit prefix default)")")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            if case Failure.usage = error { return 64 }
            return 1
        }
    }
}
