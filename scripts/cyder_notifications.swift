import AppKit
import UserNotifications

/// Program-control notices as macOS notifications (design: docs/superpowers/
/// specs/2026-11-20-program-control-design.md, phase 2). App-only: the
/// notification centre aborts outside an app bundle, so the status item only
/// emits `ProgramNotice` and this posts it.
final class CyderNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CyderNotifications()
    static let unexpectedCategory = "local.cyder.program.unexpected-end"
    static let sharedCategory = "local.cyder.program.shared-running"
    static let showLogAction = "show-log"
    static let endSharedAction = "end-shared"

    /// 結束 the shared program of an environment (goes through the confirmed path).
    var onEndShared: ((_ prefix: String, _ shared: String) -> Void)?
    private var posting = 0
    private var afterPosting: [() -> Void] = []
    var isPosting: Bool { precondition(Thread.isMainThread); return posting > 0 }

    /// Set at launch, before a click can relaunch Cyder and deliver an action.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.unexpectedCategory,
                actions: [UNNotificationAction(identifier: Self.showLogAction, title: "查看紀錄", options: [.foreground])],
                intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.sharedCategory,
                actions: [UNNotificationAction(identifier: Self.endSharedAction, title: "結束…", options: [.foreground])],
                intentIdentifiers: []),
        ])
    }

    static func content(for notice: CyderStatusItemController.ProgramNotice, logPath: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch notice {
        case .unexpectedEnd(let name):
            content.title = "\(name) 意外結束"
            content.body = "程式在執行中當掉。可以在紀錄中查看原因。"
            content.categoryIdentifier = unexpectedCategory
            content.userInfo = ["logPath": logPath]
        case .sharedStillRunning(let shared, _, let prefix):
            content.title = "\(shared) 仍在背景執行"
            content.body = "遊戲已結束。不需要時可以結束 \(shared)。"
            content.categoryIdentifier = sharedCategory
            content.userInfo = ["prefix": prefix, "shared": shared]
        }
        return content
    }

    func post(_ notice: CyderStatusItemController.ProgramNotice, logPath: String) {
        precondition(Thread.isMainThread)
        let content = Self.content(for: notice, logPath: logPath)
        let center = UNUserNotificationCenter.current()
        posting += 1
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                CyderDiagnostics.shared.info("program control: notification not shown (not allowed): \(content.title)")
                DispatchQueue.main.async { self.finishPosting() }
                return
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { CyderDiagnostics.shared.warning("program control: notification failed: \(error.localizedDescription)") }
                else { CyderDiagnostics.shared.info("program control: notification shown category=\(content.categoryIdentifier)") }
                DispatchQueue.main.async { self.finishPosting() }
            }
        }
    }
    /// Run `work` once no notification is being handed to the system (Cyder
    /// quits itself when idle; quitting mid-post can drop the notification).
    func whenIdle(_ work: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        if posting == 0 { work() } else { afterPosting.append(work) }
    }
    private func finishPosting() {
        posting -= 1
        guard posting == 0 else { return }
        let pending = afterPosting; afterPosting = []
        pending.forEach { $0() }
    }

    // Show banners even while Cyder is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case Self.showLogAction:
                if let path = info["logPath"] as? String, FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            case Self.endSharedAction:
                if let prefix = info["prefix"] as? String, let shared = info["shared"] as? String { self.onEndShared?(prefix, shared) }
            default: break
            }
            completionHandler()
        }
    }
}
