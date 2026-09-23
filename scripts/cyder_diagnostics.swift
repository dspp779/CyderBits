import Foundation

enum CyderStage: String {
    case appStart = "app-start"
    case settingsLoad = "settings-load"
    case settingsSave = "settings-save"
    case resourceValidation = "resource-validation"
    case engineValidation = "engine-validation"
    case engineExtraction = "engine-extraction"
    case rosettaCheck = "rosetta-check"
    case bootstrap = "bootstrap"
    case settingsApply = "settings-apply"
    case exeValidation = "exe-validation"
    case wineSpawn = "wine-spawn"
    case wineActivation = "wine-activation"
    case completed = "completed"
}

struct CyderFailure {
    let code: String
    let stage: CyderStage
    let summary: String
    let technicalDetails: String
    let exitCode: Int32?
    let terminationReason: String?
    let logURL: URL?

    init(
        code: String,
        stage: CyderStage,
        summary: String,
        technicalDetails: String,
        exitCode: Int32? = nil,
        terminationReason: String? = nil,
        logURL: URL? = nil
    ) {
        self.code = code
        self.stage = stage
        self.summary = summary
        self.technicalDetails = technicalDetails
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.logURL = logURL
    }

    var diagnosticText: String {
        var lines = [
            "Cyder error: \(code)",
            "Stage: \(stage.rawValue)",
            "Summary: \(summary)",
        ]
        if let exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if let terminationReason {
            lines.append("Termination: \(terminationReason)")
        }
        if !technicalDetails.isEmpty {
            lines.append("")
            lines.append(technicalDetails)
        }
        if let logURL {
            lines.append("")
            lines.append("Log: \(logURL.path)")
        }
        return lines.joined(separator: "\n")
    }
}

struct CyderPreviousSession {
    let sessionID: String
    let stage: String
    let startedAt: String
    let logPath: String
}

struct CyderLogCleanupSummary {
    let fileCount: Int
    let byteCount: Int64
}

enum CyderDiagnosticsError: LocalizedError {
    case noPreviousGameLog
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPreviousGameLog:
            return "找不到可匯出的上次遊戲記錄。請先執行一次遊戲或測試啟動。"
        case .exportFailed(let detail):
            return "無法匯出遊戲記錄：\(detail)"
        }
    }
}

final class CyderDiagnostics {
    static let shared = CyderDiagnostics()

    let sessionID = UUID().uuidString
    let supportURL: URL
    let logsURL: URL
    let sessionLogURL: URL
    private let stateURL: URL
    private let lastErrorURL: URL
    private let startedAtDate = Date()
    private let startedAt: String
    private let lock = NSLock()
    private var logHandle: FileHandle?
    private var stage: CyderStage = .appStart
    private var stageEnteredAt = Date()
    private var didFinish = false
    private var operationSequence = 0
    private var previousSession: CyderPreviousSession?
    var previousUnexpectedSession: CyderPreviousSession? {
        lock.lock(); defer { lock.unlock() }; return previousSession
    }
    private let ioQueue = DispatchQueue(label: "local.cyder.diagnostics-io", qos: .utility)
    private var pendingWrites = 0
    private var droppedWrites = 0
    private var pendingFailure: CyderFailure?
    private var failureScheduled = false
    private let redirectStreams: Bool
    private let beforeIO: () -> Void
    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    // Nonblocking and bounded: a stalled filesystem retains one physical
    // writer and at most 128 ordinary records, one latest error and one finish.
    private func enqueue(afterFinish: Bool = false, _ work: @escaping () -> Void) {
        lock.lock()
        guard (!didFinish || afterFinish), pendingWrites < 128 else {
            if !didFinish { droppedWrites += 1 }
            lock.unlock(); return
        }
        pendingWrites += 1
        ioQueue.async { [self] in
            beforeIO(); work()
            lock.lock(); pendingWrites -= 1; lock.unlock()
        }
        lock.unlock()
    }

    var pendingWriteCount: Int {
        lock.lock(); defer { lock.unlock() }; return pendingWrites
    }

    /// The completion runs off main, after preceding diagnostics work. UI
    /// callers must keep an independent deadline and must never wait for it.
    func flush(completion: @escaping () -> Void) {
        ioQueue.async { DispatchQueue.global(qos: .utility).async(execute: completion) }
    }

    func loadPreviousSession(completion: @escaping (CyderPreviousSession?) -> Void) {
        flush { [self] in
            let previous = previousUnexpectedSession
            DispatchQueue.main.async { completion(previous) }
        }
    }

    private func bounded(_ text: String) -> String {
        String(decoding: text.utf8.prefix(16_384), as: UTF8.self)
    }

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(support: URL? = nil, redirectStreams: Bool = true, beforeIO: @escaping () -> Void = {}) {
        self.redirectStreams = redirectStreams
        self.beforeIO = beforeIO
        let environment = ProcessInfo.processInfo.environment
        if let support { supportURL = support }
        else if let override = environment["CYDER_SUPPORT"], !override.isEmpty {
            supportURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            supportURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
        }
        logsURL = supportURL.appendingPathComponent("Logs", isDirectory: true)
        let sessionsURL = logsURL.appendingPathComponent("sessions", isDirectory: true)
        let operationsURL = logsURL.appendingPathComponent("operations", isDirectory: true)
        stateURL = logsURL.appendingPathComponent("session-state.json")
        lastErrorURL = logsURL.appendingPathComponent("last-error.json")
        startedAt = timestampFormatter.string(from: startedAtDate)

        let timestamp = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        sessionLogURL = sessionsURL.appendingPathComponent("\(timestamp)-\(sessionID).log")

        ioQueue.async { [self] in
            beforeIO()
            initializeStorage(sessionsURL: sessionsURL, operationsURL: operationsURL)
        }
    }

    private func initializeStorage(sessionsURL: URL, operationsURL: URL) {
        precondition(!Thread.isMainThread)
        do {
            try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: operationsURL, withIntermediateDirectories: true)
            let previous = Self.readPreviousSession(from: stateURL)
            lock.lock(); previousSession = previous; lock.unlock()
            FileManager.default.createFile(atPath: sessionLogURL.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: sessionLogURL)
            try logHandle?.seekToEnd()
            if redirectStreams { redirectStandardStreams() }
            rotateLogs(in: sessionsURL, keeping: 10)
            writeState(state: "running", outcome: nil)
            writeLog(
                "INFO",
                "session started appVersion=\(appVersion) os=\(ProcessInfo.processInfo.operatingSystemVersionString) arch=\(Self.machineArchitecture())"
            )
        } catch {
            fputs("Cyder diagnostics initialization failed: \(error)\n", stderr)
        }
    }

    deinit {
        let handle = logHandle
        ioQueue.async { try? handle?.close() }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    func enter(_ newStage: CyderStage, detail: String? = nil) {
        let now = Date()
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        let previous = stage
        let previousMs = now.timeIntervalSince(stageEnteredAt) * 1000
        let sessionMs = now.timeIntervalSince(startedAtDate) * 1000
        stage = newStage
        stageEnteredAt = now
        lock.unlock()
        var message = "stage=\(newStage.rawValue)"
        if let detail {
            message += " detail=\(bounded(detail))"
        }
        message += String(
            format: " previous=%@ previous_ms=%.0f session_ms=%.0f",
            previous.rawValue,
            previousMs,
            sessionMs
        )
        let line = message
        enqueue { [self] in
            writeLog("INFO", line)
            writeState(state: "running", outcome: nil)
        }
    }

    func noteElapsed(operation: String, milliseconds: Double, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        log("INFO", String(format: "operation=%@ elapsed_ms=%.0f%@", operation, milliseconds, suffix))
    }

    func info(_ message: String) {
        log("INFO", message)
    }

    func warning(_ message: String) {
        let limited = bounded(message)
        // Final cleanup can still report a warning after the terminal state
        // was queued. It does not reopen the session or bypass the backlog cap.
        enqueue(afterFinish: true) { [self] in writeLog("WARN", limited) }
    }

    func record(_ failure: CyderFailure) {
        let limited = CyderFailure(code: bounded(failure.code), stage: failure.stage,
            summary: bounded(failure.summary), technicalDetails: bounded(failure.technicalDetails),
            exitCode: failure.exitCode, terminationReason: failure.terminationReason.map(bounded), logURL: failure.logURL)
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        pendingFailure = limited
        guard !failureScheduled else { lock.unlock(); return }
        failureScheduled = true
        ioQueue.async { [self] in
            beforeIO()
            lock.lock()
            let value = pendingFailure
            pendingFailure = nil; failureScheduled = false
            lock.unlock()
            if let value { writeFailure(value) }
        }
        lock.unlock()
    }

    private func writeFailure(_ failure: CyderFailure) {
        writeLog("ERROR", failure.diagnosticText.replacingOccurrences(of: "\n", with: " | "))
        var payload: [String: Any] = [
            "sessionID": sessionID,
            "timestamp": timestampFormatter.string(from: Date()),
            "code": failure.code,
            "stage": failure.stage.rawValue,
            "summary": failure.summary,
            "technicalDetails": redact(failure.technicalDetails),
            "logPath": failure.logURL?.path ?? sessionLogURL.path,
        ]
        if let exitCode = failure.exitCode {
            payload["exitCode"] = exitCode
        }
        if let terminationReason = failure.terminationReason {
            payload["terminationReason"] = terminationReason
        }
        writeJSON(payload, to: lastErrorURL)
    }

    func finish(outcome: String) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        stage = .completed
        let sessionMs = Date().timeIntervalSince(startedAtDate) * 1000
        let limitedOutcome = bounded(outcome)
        // Reserved independently of ordinary log capacity. Ordering under the
        // same lock prevents a pre-finish submit from landing after this write.
        ioQueue.async { [self] in
            beforeIO()
            lock.lock(); let dropped = droppedWrites; lock.unlock()
            if dropped > 0 { writeLog("WARN", "diagnostic backlog dropped=\(dropped)") }
            writeLog("INFO", String(format: "session finished outcome=%@ session_ms=%.0f", limitedOutcome, sessionMs))
            writeState(state: "completed", outcome: limitedOutcome)
        }
        lock.unlock()
    }

    func makeOperationLog(_ name: String) -> URL {
        if name == "apply-settings-fast" || name == "apply-settings-running" {
            return logsURL
                .appendingPathComponent("operations", isDirectory: true)
                .appendingPathComponent("settings-apply.log")
        }
        if name == "wine-launch" {
            let sessionsURL = logsURL.appendingPathComponent("sessions", isDirectory: true)
            let launchURL = sessionsURL.appendingPathComponent("last-wine-launch.log")
            let pointerURL = logsURL.appendingPathComponent("last-launch.log")
            let compressedPointerURL = logsURL.appendingPathComponent("last-launch.log.gz")
            try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: pointerURL.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: pointerURL.path)) != nil {
                try? FileManager.default.removeItem(at: pointerURL)
            }
            try? FileManager.default.removeItem(at: compressedPointerURL)
            try? FileManager.default.createSymbolicLink(at: pointerURL, withDestinationURL: launchURL)
            return launchURL
        }
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        lock.lock()
        operationSequence += 1
        let sequence = operationSequence
        lock.unlock()
        return logsURL
            .appendingPathComponent("operations", isDirectory: true)
            .appendingPathComponent(String(format: "%@-%03d-%@.log", sessionID, sequence, safeName))
    }

    /// Prepare an operation log for one launcher invocation. The settings
    /// diagnostic is append-only until the rolling size cap is reached;
    /// launch and other operation logs start a fresh invocation at offset zero.
    func prepareOperationLog(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            if url.lastPathComponent != "settings-apply.log" {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.close()
            }
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url.path])
        }
    }

    /// Keep the settings apply diagnostic as a single bounded rolling file.
    /// The tail is retained because it contains the most useful registry or
    /// validation failure when a command emits an unusually large trace.
    func trimRollingOperationLog(at url: URL, maxBytes: Int = 512 * 1024) {
        guard url.lastPathComponent == "settings-apply.log",
              let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        let marker = Data("[Cyder] settings-apply.log truncated; showing newest output\n".utf8)
        guard maxBytes > marker.count,
              let size = try? handle.seekToEnd(),
              size > UInt64(maxBytes) else { return }
        let offset = size - UInt64(maxBytes - marker.count)
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        var replacement = marker
        replacement.append(data)
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: replacement)
    }

    /// Export only the most recent game launch log.
    /// Other pre-launch failures provide their own copyable diagnostics.
    func exportLastGameLog(to destinationURL: URL) throws {
        let manager = FileManager.default
        guard let source = lastGameLogURL() else {
            throw CyderDiagnosticsError.noPreviousGameLog
        }
        do {
            try manager.copyItem(at: source.resolvingSymlinksInPath(), to: destinationURL)
        } catch {
            throw CyderDiagnosticsError.exportFailed(error.localizedDescription)
        }
    }

    /// Remove diagnostic records, including launch pointers and the contents of
    /// the operations/sessions directories. The active Cyder session file is
    /// truncated in place so this running app can continue logging safely.
    func cleanupDebugLogs() throws -> CyderLogCleanupSummary {
        precondition(!Thread.isMainThread)
        return try ioQueue.sync { try cleanupDebugLogsOnWorker() }
    }

    private func cleanupDebugLogsOnWorker() throws -> CyderLogCleanupSummary {
        let manager = FileManager.default
        var targets: [URL] = []
        let latestLaunches = [
            logsURL.appendingPathComponent("last-launch.log"),
            logsURL.appendingPathComponent("last-launch.log.gz"),
        ]
        for latestLaunch in latestLaunches {
            if fileExistsOrSymlink(latestLaunch) {
                targets.append(latestLaunch)
            }
        }
        let activeSessionPath = sessionLogURL.standardizedFileURL.path
        var activeSessionByteCount: Int64 = 0
        if fileExistsOrSymlink(sessionLogURL) {
            activeSessionByteCount = Int64((try? sessionLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? logHandle?.synchronize()
            try? logHandle?.truncate(atOffset: 0)
            try? logHandle?.seek(toOffset: 0)
        }

        for directoryName in ["operations", "sessions"] {
            let directory = logsURL.appendingPathComponent(directoryName, isDirectory: true)
            if let files = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                targets.append(contentsOf: files.filter {
                    $0.standardizedFileURL.path != activeSessionPath
                })
            }
        }

        var seen = Set<String>()
        var fileCount = 0
        var byteCount: Int64 = 0
        if activeSessionByteCount > 0 {
            fileCount += 1
            byteCount += activeSessionByteCount
        }
        for target in targets where seen.insert(target.standardizedFileURL.path).inserted {
            guard fileExistsOrSymlink(target) else {
                continue
            }
            let values = try? target.resourceValues(forKeys: [.fileSizeKey])
            byteCount += Int64(values?.fileSize ?? 0)
            try manager.removeItem(at: target)
            fileCount += 1
        }
        return CyderLogCleanupSummary(fileCount: fileCount, byteCount: byteCount)
    }

    func tail(of url: URL, maxBytes: Int = 16_384) -> String {
        if url.pathExtension == "gz" {
            return decompressedTail(of: url, maxBytes: maxBytes)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        return redact(String(decoding: data, as: UTF8.self))
    }

    private func decompressedTail(of url: URL, maxBytes: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-cd", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            data.append(chunk)
            if data.count > maxBytes {
                data.removeFirst(data.count - maxBytes)
            }
        }
        process.waitUntilExit()
        return redact(String(decoding: data, as: UTF8.self))
    }

    func redact(_ text: String) -> String {
        guard !homePath.isEmpty else { return text }
        return text.replacingOccurrences(of: homePath, with: "~")
    }

    private func log(_ level: String, _ message: String) {
        let limited = bounded(message)
        enqueue { [self] in writeLog(level, limited) }
    }

    private func writeLog(_ level: String, _ message: String) {
        precondition(!Thread.isMainThread)
        let timestamp = timestampFormatter.string(from: Date())
        let line = "\(timestamp) [\(level)] [\(sessionID)] \(redact(message))\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try logHandle?.write(contentsOf: data)
            try logHandle?.synchronize()
        } catch {
            fputs(line, stderr)
        }
    }

    private func writeState(state: String, outcome: String?) {
        lock.lock()
        let currentStage = stage.rawValue
        lock.unlock()
        var payload: [String: Any] = [
            "sessionID": sessionID,
            "state": state,
            "stage": currentStage,
            "startedAt": startedAt,
            "logPath": sessionLogURL.path,
            "appVersion": appVersion,
        ]
        if let outcome {
            payload["outcome"] = outcome
        }
        writeJSON(payload, to: stateURL)
    }

    private func writeJSON(_ value: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            log("WARN", "unable to write diagnostic file path=\(url.path) error=\(error)")
        }
    }

    private func redirectStandardStreams() {
        guard let descriptor = logHandle?.fileDescriptor else { return }
        _ = dup2(descriptor, STDOUT_FILENO)
        _ = dup2(descriptor, STDERR_FILENO)
    }

    private func rotateLogs(in directory: URL, keeping limit: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = files.filter {
            ($0.pathExtension == "log" || $0.pathExtension == "gz")
                && $0.lastPathComponent != "last-wine-launch.log"
        }
        let sorted = logs.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(limit * 5) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func lastGameLogURL() -> URL? {
        let manager = FileManager.default
        let sessionsURL = logsURL.appendingPathComponent("sessions", isDirectory: true)
        let sessionFiles = (try? manager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "log" || $0.pathExtension == "gz" } ?? []

        let lastLaunches = [
            logsURL.appendingPathComponent("last-launch.log.gz"),
            logsURL.appendingPathComponent("last-launch.log"),
        ]
        for lastLaunch in lastLaunches where manager.fileExists(atPath: lastLaunch.path) {
            let resolved = lastLaunch.resolvingSymlinksInPath()
            if manager.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return sessionFiles
            .filter { $0.lastPathComponent.contains("-wine-launch.log") }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .first
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func fileExistsOrSymlink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func readPreviousSession(from url: URL) -> CyderPreviousSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["state"] as? String == "running"
        else { return nil }
        return CyderPreviousSession(
            sessionID: object["sessionID"] as? String ?? "unknown",
            stage: object["stage"] as? String ?? "unknown",
            startedAt: object["startedAt"] as? String ?? "unknown",
            logPath: object["logPath"] as? String ?? ""
        )
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
