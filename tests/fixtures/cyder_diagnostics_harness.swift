import Foundation

@main
struct CyderDiagnosticsHarness {
    static func main() {
        let diagnostics = CyderDiagnostics.shared
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        switch mode {
        case "leave-running":
            diagnostics.enter(.wineSpawn, detail: "fault-injection")
            exit(0)
        case "timing":
            diagnostics.enter(.engineValidation, detail: "timing")
            Thread.sleep(forTimeInterval: 0.05)
            diagnostics.enter(.wineSpawn, detail: "timing")
            diagnostics.noteElapsed(operation: "timing-probe", milliseconds: 12, extra: "status=0")
            diagnostics.finish(outcome: "timing")
            let log = try! String(contentsOf: diagnostics.sessionLogURL, encoding: .utf8)
            guard log.contains("previous_ms="),
                  log.contains("session_ms="),
                  log.contains("elapsed_ms=12") else {
                exit(18)
            }
        case "recover":
            guard diagnostics.previousUnexpectedSession?.stage == CyderStage.wineSpawn.rawValue else {
                exit(11)
            }
            diagnostics.finish(outcome: "recovered")
        case "record-failure":
            diagnostics.record(CyderFailure(
                code: "CYD-TEST-001",
                stage: .bootstrap,
                summary: "Injected failure",
                technicalDetails: FileManager.default.homeDirectoryForCurrentUser.path + "/secret/game.exe"
            ))
            diagnostics.finish(outcome: "test-failure-recorded")
        case "export":
            let manager = FileManager.default
            let sessions = diagnostics.logsURL.appendingPathComponent("sessions", isDirectory: true)
            let priorID = "11111111-1111-1111-1111-111111111111"
            let sessionLog = sessions.appendingPathComponent("\(priorID).log")
            let launchLog = sessions.appendingPathComponent("\(priorID)-001-wine-launch.log")
            try! "session".write(to: sessionLog, atomically: true, encoding: .utf8)
            try! "Wine diagnostics: errors\n".write(to: launchLog, atomically: true, encoding: .utf8)
            let lastLaunch = diagnostics.logsURL.appendingPathComponent("last-launch.log")
            try? manager.removeItem(at: lastLaunch)
            try! manager.createSymbolicLink(
                at: lastLaunch,
                withDestinationURL: launchLog
            )
            let exported = diagnostics.supportURL.appendingPathComponent("exported-game.log")
            try! diagnostics.exportLastGameLog(to: exported)
            guard manager.fileExists(atPath: exported.path),
                  (try? String(contentsOf: exported, encoding: .utf8)) == "Wine diagnostics: errors\n"
            else { exit(13) }
            diagnostics.finish(outcome: "exported")
        case "cleanup":
            let manager = FileManager.default
            let sessions = diagnostics.logsURL.appendingPathComponent("sessions", isDirectory: true)
            let operations = diagnostics.logsURL.appendingPathComponent("operations", isDirectory: true)
            try! manager.createDirectory(at: operations, withIntermediateDirectories: true)
            let oldSession = sessions.appendingPathComponent("old-session.log")
            try! "old session".write(to: oldSession, atomically: true, encoding: .utf8)
            let operation = operations.appendingPathComponent("old-operation.log")
            try! "old operation".write(to: operation, atomically: true, encoding: .utf8)
            let launchLog = sessions.appendingPathComponent("22222222-2222-2222-2222-222222222222-001-wine-launch.log")
            try! "debug".write(to: launchLog, atomically: true, encoding: .utf8)
            let lastLaunch = diagnostics.logsURL.appendingPathComponent("last-launch.log")
            try? manager.removeItem(at: lastLaunch)
            try! manager.createSymbolicLink(atPath: lastLaunch.path, withDestinationPath: launchLog.path)
            let summary = try! diagnostics.cleanupDebugLogs()
            guard summary.fileCount >= 5,
                  !manager.fileExists(atPath: launchLog.path),
                  !manager.fileExists(atPath: lastLaunch.path),
                  !manager.fileExists(atPath: oldSession.path),
                  !manager.fileExists(atPath: operation.path) else {
                exit(14)
            }
            diagnostics.finish(outcome: "cleaned")
        case "rolling":
            let fast = diagnostics.makeOperationLog("apply-settings-fast")
            let running = diagnostics.makeOperationLog("apply-settings-running")
            guard fast.path == running.path,
                  fast.lastPathComponent == "settings-apply.log",
                  fast.path.contains("/operations/") else {
                exit(15)
            }
            try! diagnostics.prepareOperationLog(at: fast)
            let oversized = String(repeating: "old settings output\n", count: 100_000)
            try! oversized.write(to: fast, atomically: true, encoding: .utf8)
            diagnostics.trimRollingOperationLog(at: fast, maxBytes: 512)
            let bounded = try! Data(contentsOf: fast)
            guard bounded.count <= 512,
                  String(decoding: bounded, as: UTF8.self).contains("truncated") else {
                exit(16)
            }
            try! diagnostics.prepareOperationLog(at: running)
            let appendHandle = try! FileHandle(forWritingTo: running)
            try! appendHandle.seekToEnd()
            try! appendHandle.write(contentsOf: Data("new settings output\n".utf8))
            try! appendHandle.close()
            let retained = try! String(contentsOf: fast, encoding: .utf8)
            guard retained.contains("truncated"),
                  retained.contains("new settings output") else {
                exit(17)
            }
            diagnostics.finish(outcome: "rolling")
        default:
            exit(12)
        }
    }
}
