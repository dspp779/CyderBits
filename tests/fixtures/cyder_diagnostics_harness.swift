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
        default:
            exit(12)
        }
    }
}
