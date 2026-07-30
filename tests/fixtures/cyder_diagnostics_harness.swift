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
        default:
            exit(12)
        }
    }
}
