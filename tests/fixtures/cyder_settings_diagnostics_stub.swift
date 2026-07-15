import Foundation

enum CyderStage { case settingsLoad, settingsSave }

final class CyderDiagnostics {
    static let shared = CyderDiagnostics()
    func enter(_ stage: CyderStage) {}
    func warning(_ message: String) {}
}
