// Cyder.app entry — phased setup UI, then launch Windows EXE directly with Wine.
import Cocoa
import Darwin
import Foundation
import UniformTypeIdentifiers

private enum CyderLaunchOutcome {
    case success
    case cancelled
    case environmentNotReady
    case graphicsNotReady
    case failure(CyderFailure)
}

private enum CyderPrefixResolution {
    case success(URL)
    case failure(CyderFailure)
}

private enum CyderFailureAction: Equatable {
    case close
    case rebuild
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var pendingURLs: [String] = []
    // nil means a regular Finder/library launch and therefore uses the saved
    // per-game arguments. A non-nil value came from the new application's argv
    // and replaces the saved arguments for this launch only.
    private var pendingLaunchArguments: [String]?
    private struct QueuedLaunch {
        let executable: String
        let arguments: [String]?
        var isURI = false
    }

    private var queuedLaunches: [QueuedLaunch] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false
    private var libraryLaunchInProgress = false
    private var documentLaunchRequested = false
    private var openLibraryOnLaunch = false
    private var setupPanel: CyderSetupPanel?
    private var terminateWhenSettingsClose = false
    private var openingGameLibrary = false
    private var environmentPreparationInProgress = false
    private var wineActivationWaiter: WineActivationWaiter?
    private var quitWhenSessionsEnd = false
    private var isPrimaryInstance = true
    private var secondaryForwardScheduled = false
    private var secondaryRequestSent = false
    private var deferredInstanceRequests: [CyderInstanceRequest] = []
    private lazy var instanceCoordinator: CyderInstanceCoordinator = {
        let coordinator = CyderInstanceCoordinator()
        return coordinator
    }()
    private lazy var statusItemController: CyderStatusItemController = {
        let controller = CyderStatusItemController()
        controller.onOpenPreferences = { [weak self] in self?.showSettings() }
        controller.onOpenGameLibrary = { [weak self] in self?.showGameLibrary() }
        controller.onOpenTaskManager = { [weak self] prefix in
            self?.runPrefixAction("--taskmgr-prefix", prefix: prefix, operation: "task-manager")
        }
        controller.onStopPrefixes = { [weak self] prefixes in
            self?.requestQuitAndStop(prefixes: prefixes)
        }
        controller.onAllSessionsEnded = { [weak self] in
            guard let self else { return }
            if self.quitWhenSessionsEnd || (
                self.settingsController.window?.isVisible != true
                    && self.gameLibraryController.window?.isVisible != true
            ) {
                NSApp.terminate(nil)
            }
        }
        if #available(macOS 11.0, *) {
            controller.onSessionEnded = { [weak self] prefix in
                self?.handleWineSessionEnded(prefix: prefix)
            }
        }
        return controller
    }()
    private lazy var settingsController: CyderSettingsWindowController = {
        let controller = CyderSettingsWindowController()
        controller.onImmediateSave = { [weak self] registrySetting in
            self?.applySettingsImmediately(registrySetting: registrySetting) ?? false
        }
        controller.onApplyWhileRunning = { [weak self] draftEnvironment in
            self?.applySettingsWhileRunning(draftEnvironment: draftEnvironment) ?? false
        }
        controller.onSaveStarted = { [weak self] in
            self?.environmentPreparationInProgress = true
            self?.showSetup("正在儲存設定…")
        }
        controller.onSaveFailed = { [weak self] in
            self?.hideSetup()
            self?.environmentPreparationInProgress = false
        }
        controller.hasRunningExes = { [weak self] in self?.hasRunningExes() ?? false }
        controller.onStopAllWine = { [weak self] in
            self?.stopAllExesWaiting() ?? false
        }
        controller.onRebuild = { [weak self] in self?.rebuildEnvironment() }
        controller.onCreateProfile = { [weak self] executable in
            self?.createIndependentProfile(for: executable)
        }
        controller.onOpenGameLibrary = { [weak self] in
            self?.showGameLibrary()
        }
        controller.onOpenWinetricks = { [weak self] verbs in
            self?.installWinetricks(verbs)
        }
        controller.onExportLastGameLog = { [weak self] in
            self?.exportLastGameLog()
        }
        controller.onCleanDebugLogs = { [weak self] in
            self?.cleanDebugLogs()
        }
        if #available(macOS 11.0, *) {
            controller.onScanURIHandlers = { [weak self] completion in
                self?.scanURIHandlersForSettings(completion: completion)
            }
            controller.onEnableURIHandler = { [weak self] record in
                self?.enableURIHandlerFromSettings(record: record) ?? false
            }
            controller.onDisableURIHandler = { [weak self] in
                self?.disableURIHandlerFromSettings() ?? false
            }
            controller.onIsCyderURIHandlerDefault = {
                CyderURIHandlerManager.shared.isCyderDefaultHandler()
            }
        }
        controller.onClose = { [weak self] in
            guard let self,
                  !self.environmentPreparationInProgress,
                  !self.openingGameLibrary,
                  self.gameLibraryController.window?.isVisible != true else { return }
            self.statusItemController.setUIVisible(false)
            if self.statusItemController.hasActiveSessions || self.libraryLaunchInProgress {
                NSApp.setActivationPolicy(.accessory)
                return
            }
            guard self.terminateWhenSettingsClose else { return }
            NSApp.terminate(nil)
        }
        return controller
    }()

    private lazy var gameLibraryController: CyderGameLibraryWindowController = {
        let controller = CyderGameLibraryWindowController()
        controller.onLaunch = { [weak self] executable, settings in
            self?.launchGameFromLibrary(executable, settings: settings)
        }
        controller.onRemoveProfile = { [weak self] executable, completion in
            guard let self else { completion(false); return }
            self.removeIndependentProfile(for: executable, completion: completion)
        }
        controller.onOpenPreferences = { [weak self] in
            self?.showSettings()
        }
        controller.onClose = { [weak self] in
            guard let self,
                  !self.environmentPreparationInProgress,
                  self.settingsController.window?.isVisible != true,
                  !self.gameLibraryController.isGameSettingsVisible else { return }
            self.statusItemController.setUIVisible(false)
            if self.statusItemController.hasActiveSessions || self.libraryLaunchInProgress {
                NSApp.setActivationPolicy(.accessory)
                return
            }
            guard self.terminateWhenSettingsClose else { return }
            NSApp.terminate(nil)
        }
        return controller
    }()

    private func createIndependentProfile(for executable: URL, returnToLibrary: Bool = false) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        environmentPreparationInProgress = true
        settingsController.close()
        gameLibraryController.close()
        let context = CyderLaunchContext(resourcePath: resourcePath)
        showSetup("正在建立獨立遊戲環境…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, "--profile-create", executable.path, "golden"],
                stage: .bootstrap,
                operation: "profile-create"
            )
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if result.succeeded {
                    if returnToLibrary {
                        self.showGameLibrary()
                    } else {
                        self.showSettings()
                    }
                    self.showAlert("獨立遊戲環境已建立", executable.lastPathComponent, style: .informational)
                } else {
                    self.presentFailure(self.failure(
                        code: "CYD-PRO-001",
                        stage: .bootstrap,
                        summary: "無法建立這個遊戲的獨立 Windows 環境。",
                        result: result
                    ))
                    if returnToLibrary {
                        self.showGameLibrary()
                    } else {
                        self.showSettings()
                    }
                }
            }
        }
    }

    private func removeIndependentProfile(for executable: URL, completion: @escaping (Bool) -> Void) {
        guard let resourcePath = Bundle.main.resourcePath else {
            completion(false)
            return
        }
        environmentPreparationInProgress = true
        let context = CyderLaunchContext(resourcePath: resourcePath)
        showSetup("正在移除獨立遊戲環境…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, "--profile-remove", executable.path],
                stage: .bootstrap,
                operation: "profile-remove"
            )
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                guard result.succeeded else {
                    completion(false)
                    _ = self.presentFailure(self.failure(
                        code: result.status == 75 ? "CYD-PRO-003" : "CYD-PRO-004",
                        stage: .bootstrap,
                        summary: result.status == 75
                            ? "遊戲仍在執行中，無法移除獨立設定。"
                            : "無法移除這個遊戲的獨立設定。",
                        result: result
                    ))
                    return
                }
                do {
                    let profileID = try CyderProfileStore(root: CyderPaths.support).profileID(for: executable)
                    try CyderSettingsStore.shared.update { $0.perProfile.removeValue(forKey: profileID) }
                    completion(true)
                } catch {
                    completion(false)
                    self.showAlert("設定未完成", "prefix 已移除，但無法更新設定檔：\(error.localizedDescription)")
                }
            }
        }
    }

    private func rebuildEnvironment(completion: (() -> Void)? = nil) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        environmentPreparationInProgress = true
        let context = CyderLaunchContext(resourcePath: resourcePath)
        showSetup("正在重建 Windows 遊戲環境…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--rebuild-prefix"],
                stage: .bootstrap,
                operation: "rebuild-prefix"
            )
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if result.succeeded {
                    if let completion {
                        completion()
                    } else {
                        self.showSettings()
                    }
                } else {
                    let rebuildFailure = self.failure(
                        code: "CYD-REBUILD-001",
                        stage: .bootstrap,
                        summary: "重建 Windows 遊戲環境失敗。",
                        result: result
                    )
                    let action = self.presentFailure(rebuildFailure, allowsRebuild: true)
                    if action == .rebuild {
                        self.rebuildEnvironment(completion: completion)
                    } else if completion == nil {
                        NSApp.terminate(nil)
                    } else {
                        CyderDiagnostics.shared.finish(outcome: "rebuild-failed")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Finder document URLs are delivered through openFiles, not argv, so
        // launch hidden until the post-launch mode decision. Settings mode is
        // promoted below; an EXE launch stays out of the Dock unless it needs
        // to ask the user a question or show an error.
        NSApp.setActivationPolicy(.accessory)
        switch instanceCoordinator.start(onRequest: { [weak self] request in
            self?.receiveInstanceRequest(request)
        }) {
        case .primary:
            isPrimaryInstance = true
            instanceCoordinator.sentinel.onLaunchEnded = { [weak self] id in
                self?.statusItemController.noteHelperDisconnected(id: id)
            }
        case .secondary:
            isPrimaryInstance = false
        case .unavailable:
            // A read-only or otherwise unavailable support directory should
            // not make the app unusable. Continue as primary, while accepting
            // that the OS cannot enforce single-instance ownership here.
            isPrimaryInstance = true
            CyderDiagnostics.shared.warning("native instance lock unavailable; continuing without coordination")
        }
    }

    @available(macOS 11.0, *)
    func application(_ application: NSApplication, open urls: [URL]) {
        let fileExecutables = urls.filter(\.isFileURL).flatMap {
            normalizeExePaths([$0.path])
        }
        let uriStrings = CyderURIHandlerManager.shared.filterHandledURLs(urls)
        CyderDiagnostics.shared.info(
            "open-urls received=\(urls.count) gamaniagames=\(uriStrings.count) file-exe=\(fileExecutables.count)"
        )
        if !fileExecutables.isEmpty {
            deliverExecutableFiles(fileExecutables)
        }
        guard !uriStrings.isEmpty else { return }
        if !isPrimaryInstance {
            pendingURLs.append(contentsOf: uriStrings)
            scheduleSecondaryForward()
            return
        }
        if settingsController.window?.isVisible == true {
            settingsController.close()
        }
        enqueueOrLaunchURIs(uriStrings)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let executableFiles = normalizeExePaths(filenames)
        CyderDiagnostics.shared.info(
            "open-files received=\(filenames.count) executable=\(executableFiles.count) bundle=\(Bundle.main.bundlePath)"
        )
        if executableFiles.isEmpty, let raw = filenames.first, !raw.isEmpty {
            CyderDiagnostics.shared.info("open-files rejected raw=\(raw)")
        }
        guard deliverExecutableFiles(executableFiles, replyToOpen: application) else {
            application.reply(toOpenOrPrint: .failure)
            return
        }
        application.reply(toOpenOrPrint: .success)
    }

    @discardableResult
    private func deliverExecutableFiles(
        _ executableFiles: [String],
        replyToOpen application: NSApplication? = nil
    ) -> Bool {
        guard !executableFiles.isEmpty else { return false }
        if !isPrimaryInstance {
            pendingFiles.append(contentsOf: executableFiles)
            scheduleSecondaryForward()
            return true
        }
        if gameLibraryController.window?.isVisible == true {
            presentExternalLaunchStarting()
            enqueueOrLaunch(executableFiles)
            return true
        }
        if didRunLauncher {
            presentExternalLaunchStarting()
            enqueueOrLaunch(executableFiles)
            return true
        }
        presentExternalLaunchStarting()
        pendingFiles.append(contentsOf: executableFiles)
        if ProcessInfo.processInfo.environment["CYDER_OPEN_FILES_SELF_TEST"] == "1"
            || ProcessInfo.processInfo.environment["CYDER_INVOCATION_SELF_TEST_OUTPUT"]?.isEmpty == false {
            return true
        }
        scheduleRun()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isPrimaryInstance {
            captureInvocationArguments()
            scheduleSecondaryForward()
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(wineAppWillActivate(_:)),
            name: Notification.Name("WineAppWillActivateNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(wineWorkspaceDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(wineWorkspaceDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        installMainMenu()
        didFinishLaunch = true
        if #available(macOS 11.0, *) {
            configureURIHandler()
        }
        if ProcessInfo.processInfo.environment["CYDER_OPEN_FILES_SELF_TEST"] == "1" {
            CyderDiagnostics.shared.enter(.appStart, detail: "open-files-self-test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                CyderDiagnostics.shared.finish(outcome: "open-files-self-test")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["CYDER_DIAGNOSTICS_SELF_TEST"] == "1" {
            CyderDiagnostics.shared.enter(.resourceValidation, detail: "self-test")
            CyderDiagnostics.shared.finish(outcome: "diagnostics-self-test")
            NSApp.terminate(nil)
            return
        }
        let environment = ProcessInfo.processInfo.environment
        openLibraryOnLaunch = environment["CYDER_OPEN_GAME_LIBRARY"] == "1"
        // A test launch request is consumed by cyder_launcher.sh. Keeping the
        // file intact here makes Bash the sole owner of effective launch
        // settings and Wine environment construction.

        captureInvocationArguments()
        if let outputPath = environment["CYDER_INVOCATION_SELF_TEST_OUTPUT"], !outputPath.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let result: [String: Any] = [
                    "executables": normalizeExePaths(self.pendingFiles),
                    "arguments": self.pendingLaunchArguments ?? [],
                    "hasDynamicArguments": self.pendingLaunchArguments != nil
                ]
                if let data = try? PropertyListSerialization.data(
                    fromPropertyList: result,
                    format: .xml,
                    options: 0
                ) {
                    try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                }
                CyderDiagnostics.shared.finish(outcome: "invocation-self-test")
                NSApp.terminate(nil)
            }
            return
        }
        pendingFiles = normalizeExePaths(pendingFiles)
        if !pendingFiles.isEmpty { documentLaunchRequested = true }
        // A test launch creates a second Cyder process while the library app
        // remains alive. Its session-state file is therefore expected to be
        // "running", not evidence of a crash. Only settings-mode launches
        // should surface a previous-session warning.
        if !documentLaunchRequested {
            showPreviousCrashIfNeeded()
        }
        CyderDiagnostics.shared.enter(
            .appStart,
            detail: launchModeDetail()
        )
        CyderDiagnostics.shared.info(
            "launch-context args=\(CommandLine.arguments.count - 1) pending=\(pendingFiles.count) bundle=\(Bundle.main.bundlePath)"
        )
        // LaunchServices can deliver application(_:openFiles:) just after
        // applicationDidFinishLaunching. Defer the settings-mode decision one
        // short turn so a document or URI launch cannot start a competing
        // health check or expose the settings window behind Wine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.documentLaunchRequested || !self.pendingFiles.isEmpty {
                // URI launches are already queued; scheduleRun() is EXE-only
                // and would otherwise prompt for a file when pendingFiles is empty.
                if !self.pendingFiles.isEmpty {
                    self.scheduleRun()
                }
            } else {
                self.terminateWhenSettingsClose = true
                self.openLibraryOnLaunch = self.openLibraryOnLaunch || self.shouldOpenGameLibraryOnLaunch()
                activateCyderUI(dockVisible: true)
                self.prepareEnvironmentAndShowSettings()
            }
        }
        if !deferredInstanceRequests.isEmpty {
            let requests = deferredInstanceRequests
            deferredInstanceRequests.removeAll()
            requests.forEach { receiveInstanceRequest($0) }
        }
    }

    private func captureInvocationArguments() {
        // Public argv contract: `Cyder [game.exe] [game argument ...]`.
        // Normally LaunchServices sends game.exe through openFiles and argv
        // contains only values following `open ... --args`. Cyder owns no
        // command-line options; even values beginning with '-' belong to the
        // Windows executable. The legacy -psn token is system-generated.
        var applicationArguments = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-psn_")
        }
        if let first = applicationArguments.first,
           let executable = normalizeExePaths([first]).first {
            // Also accept direct invocation: `Cyder game.exe ARG...`.
            pendingFiles.append(executable)
            documentLaunchRequested = true
            applicationArguments.removeFirst()
            // Empty means "no dynamic argv", not "wipe saved/test arguments".
            pendingLaunchArguments = applicationArguments.isEmpty
                ? nil
                : Array(applicationArguments)
        } else if !applicationArguments.isEmpty {
            // Association launch: EXE will arrive separately in openFiles.
            pendingLaunchArguments = Array(applicationArguments)
        }
    }

    private func scheduleSecondaryForward() {
        guard !isPrimaryInstance, !secondaryForwardScheduled else { return }
        secondaryForwardScheduled = true
        // LaunchServices can deliver openFiles shortly after didFinishLaunching.
        // Keep the secondary alive for one short turn so its argv and document
        // event are forwarded as a single request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.forwardSecondaryInstance()
        }
    }

    private func forwardSecondaryInstance() {
        guard !secondaryRequestSent else { return }
        secondaryRequestSent = true
        let files = normalizeExePaths(pendingFiles)
        let urls = pendingURLs
        let arguments = pendingLaunchArguments
        let showUI = files.isEmpty && arguments == nil && urls.isEmpty
        instanceCoordinator.forward(files: files, arguments: arguments, urls: urls, showUI: showUI)
        NSApp.terminate(nil)
    }

    private func receiveInstanceRequest(_ request: CyderInstanceRequest) {
        guard isPrimaryInstance else { return }
        guard didFinishLaunch else {
            deferredInstanceRequests.append(request)
            return
        }
        let files = normalizeExePaths(request.files)
        if !request.urls.isEmpty {
            enqueueOrLaunchURIs(request.urls)
            return
        }
        if !files.isEmpty {
            documentLaunchRequested = true
            terminateWhenSettingsClose = false
            if settingsController.window?.isVisible == true {
                settingsController.close()
            }
            if didRunLauncher {
                enqueueOrLaunch(files, arguments: request.arguments)
            } else {
                pendingFiles.append(contentsOf: files)
                if request.arguments != nil {
                    pendingLaunchArguments = request.arguments
                }
                scheduleRun()
            }
            return
        }
        guard request.showUI else { return }
        terminateWhenSettingsClose = true
        openLibraryOnLaunch = shouldOpenGameLibraryOnLaunch()
        if openLibraryOnLaunch {
            showGameLibrary()
        } else {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinator.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        CyderDiagnostics.shared.finish(outcome: "terminated")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isPrimaryInstance else { return .terminateNow }
        let prefixes = statusItemController.monitoredPrefixes
        guard !prefixes.isEmpty else { return .terminateNow }
        if !quitWhenSessionsEnd {
            requestQuitAndStop(prefixes: prefixes)
        }
        return .terminateCancel
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Cyder")
        menu.addItem(withTitle: "遊戲庫…", action: #selector(showGameLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "選擇 Windows 執行檔…", action: #selector(chooseExecutableFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "進階設定…", action: #selector(showSettings), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Cyder")
        let settings = appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let library = appMenu.addItem(withTitle: "遊戲庫…", action: #selector(showGameLibrary), keyEquivalent: "")
        library.target = self
        appMenu.addItem(NSMenuItem.separator())
        let quit = appMenu.addItem(withTitle: "結束 Cyder", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        statusItemController.setUIVisible(true)
        activateCyderUI(dockVisible: true)
        settingsController.prepareForDisplay()
        settingsController.showWindow(nil)
        settingsController.window?.makeKeyAndOrderFront(nil)
        settingsController.window?.orderFrontRegardless()
    }

    private func exportLastGameLog() {
        let panel = NSSavePanel()
        panel.title = "匯出上次遊戲記錄"
        panel.message = "選擇要複製上次遊戲 Wine log 的位置。"
        panel.nameFieldStringValue = "Cyder-last-game.log"
        panel.canCreateDirectories = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        environmentPreparationInProgress = true
        showSetup("正在匯出上次遊戲記錄…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try CyderDiagnostics.shared.exportLastGameLog(to: destination)
                DispatchQueue.main.async {
                    self.hideSetup()
                    self.environmentPreparationInProgress = false
                    self.showAlert(
                        "上次遊戲記錄已匯出",
                        destination.path,
                        style: .informational
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.hideSetup()
                    self.environmentPreparationInProgress = false
                    self.showAlert(
                        "無法匯出上次遊戲記錄",
                        error.localizedDescription,
                        style: .critical
                    )
                }
            }
        }
    }

    private func cleanDebugLogs() {
        guard !hasRunningExes() else {
            showAlert("無法清理除錯記錄", "請先關閉所有遊戲，再清理目前的 Wine launch/debug log。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "清理除錯記錄？"
        alert.informativeText = "這會移除 Wine launch/debug log，以及 Logs/operations 和 Logs/sessions 內的紀錄，但不會刪除遊戲、Windows 環境或偏好設定。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清理")
        alert.addButton(withTitle: "取消")
        guard runFrontmostAlert(alert, dockVisible: true, anchorWindow: settingsController.window)
            == .alertFirstButtonReturn else { return }

        do {
            let summary = try CyderDiagnostics.shared.cleanupDebugLogs()
            let bytes = ByteCountFormatter.string(
                fromByteCount: summary.byteCount,
                countStyle: .file
            )
            showAlert(
                "除錯記錄已清理",
                summary.fileCount == 0
                    ? "目前沒有可清理的除錯記錄。"
                    : "已移除 \(summary.fileCount) 個檔案，共 \(bytes)。",
                style: .informational
            )
        } catch {
            showAlert("無法清理除錯記錄", error.localizedDescription, style: .critical)
        }
    }

    @objc private func showGameLibrary() {
        statusItemController.setUIVisible(true)
        openingGameLibrary = true
        let settingsWasVisible = settingsController.window?.isVisible == true
        activateCyderUI(dockVisible: true)
        gameLibraryController.prepareForDisplay()
        gameLibraryController.showWindow(nil)
        gameLibraryController.window?.makeKeyAndOrderFront(nil)
        gameLibraryController.window?.orderFrontRegardless()
        // Keep a visible key window throughout the transition. In particular,
        // accessibility clients can briefly collapse a hidden scroll view to
        // zero width when the settings window is ordered out first.
        if settingsWasVisible {
            settingsController.window?.orderOut(nil)
        }
        openingGameLibrary = false
    }

    private func shouldOpenGameLibraryOnLaunch() -> Bool {
        let library = CyderGameLibraryStore.shared
        library.reload()
        if !library.games.isEmpty { return true }
        return !CyderProfileStore(root: CyderPaths.support).listRecords().isEmpty
    }

    private func launchGameFromLibrary(
        _ executable: URL,
        settings: CyderExecutableSettings?,
        launchArguments: [String]? = nil
    ) {
        guard !libraryLaunchInProgress else {
            showAlert("正在啟動另一個遊戲", "請等待目前的遊戲顯示視窗後再試一次。")
            return
        }
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("無法啟動遊戲", "Cyder 缺少必要的 Resources 目錄。")
            return
        }
        var launchEnvironment: [String: String] = [:]
        var request: URL?
        if let settings {
            do {
                let requestDirectory = CyderPaths.support.appendingPathComponent("launch-requests", isDirectory: true)
                try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
                let requestURL = requestDirectory.appendingPathComponent("test-\(UUID().uuidString).json")
                try JSONEncoder.pretty.encode(settings).write(to: requestURL, options: .atomic)
                request = requestURL
                launchEnvironment["CYDER_TEST_SETTINGS_REQUEST"] = requestURL.path
                // Test launches always capture Wine output so the command line and
                // effective sync/env settings are inspectable under Logs/.
                launchEnvironment["CYDER_CAPTURE_WINE_LOG"] = "1"
                launchEnvironment["CYDER_LAUNCH_KIND"] = "test"
            } catch {
                showAlert("無法啟動測試", "無法建立暫存的遊戲設定：\(error.localizedDescription)")
                return
            }
        }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        presentExternalLaunchStarting()
        libraryLaunchInProgress = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { if let request { try? FileManager.default.removeItem(at: request) } }
            let outcome: CyderLaunchOutcome
            switch self.prefixForExecutable(executable) {
            case .success(let prefix):
                outcome = self.runWineThroughLauncher(
                    context: context,
                    exe: executable.path,
                    prefix: prefix,
                    launchArguments: launchArguments,
                    launchEnvironment: launchEnvironment
                )
            case .failure(let failure):
                outcome = .failure(failure)
            }
            DispatchQueue.main.async {
                self.libraryLaunchInProgress = false
                self.hideSetup()
                switch outcome {
                case .success, .cancelled:
                    break
                case .environmentNotReady:
                    self.showAlert(
                        "遊戲尚未準備完成",
                        "請先完成 Cyder 的環境準備，再重新啟動遊戲。"
                    )
                case .graphicsNotReady:
                    self.showAlert(
                        "圖形元件尚未準備完成",
                        "請先重新開啟 Cyder.app 準備圖形元件，再重新啟動遊戲。"
                    )
                case .failure(let failure):
                    self.presentFailure(failure)
                }
                self.launchNextQueuedExecutableIfReady()
            }
        }
    }

    private func enqueueOrLaunch(_ executableFiles: [String], arguments: [String]? = nil) {
        queuedLaunches.append(contentsOf: executableFiles.map {
            QueuedLaunch(executable: $0, arguments: arguments)
        })
        launchNextQueuedExecutableIfReady()
    }

    private func launchNextQueuedExecutableIfReady() {
        guard !libraryLaunchInProgress,
              wineActivationWaiter == nil,
              !queuedLaunches.isEmpty else { return }
        let launch = queuedLaunches.removeFirst()
        if #available(macOS 11.0, *), launch.isURI {
            launchURI(launch.executable)
            return
        }
        launchGameFromLibrary(
            URL(fileURLWithPath: launch.executable),
            settings: nil,
            launchArguments: launch.arguments
        )
    }

    @objc private func showSettingsModal() {
        showSettings()
        if let window = settingsController.window {
            NSApp.runModal(for: window)
        }
    }

    @objc private func closeSettingsModal() {
        NSApp.stopModal()
        settingsController.close()
    }

    @objc private func chooseExecutableFromMenu() {
        guard let chosen = chooseExeOnMainThread() else { return }
        pendingFiles = [chosen]
        didRunLauncher = false
        scheduleRun()
    }

    private func stopAllExes() {
        _ = stopAllExesWaiting()
    }

    @discardableResult
    private func stopAllExesWaiting() -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        let result = runLauncher(
            context: context,
            args: [context.launcher, "--stop-all"],
            stage: .settingsApply,
            operation: "stop-all"
        )
        if !result.succeeded {
            showAlert("有些遊戲未能關閉", "請先手動關閉遊戲，再重新套用設定。")
        }
        return result.succeeded
    }

    private func hasRunningExes() -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        return runLauncher(
            context: context,
            args: [context.launcher, "--has-running-exes"],
            stage: .engineValidation,
            operation: "has-running-exes"
        ).status == 0
    }

    private func applySettingsImmediately(registrySetting: String) -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        return runLauncher(
            context: context,
            args: [context.launcher, "--apply-settings-only"],
            stage: .settingsApply,
            operation: "apply-settings-fast",
            extraEnvironment: ["CYDER_FAST_SETTING": registrySetting]
        ).succeeded
    }

    private func applySettingsWhileRunning(draftEnvironment: [String: String]) -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        var env = draftEnvironment
        env["CYDER_FORCE_SETTINGS"] = "1"
        return runLauncher(
            context: context,
            args: [context.launcher, "--apply-settings-only"],
            stage: .settingsApply,
            operation: "apply-settings-running",
            extraEnvironment: env
        ).succeeded
    }

    private func scheduleRun() {
        DispatchQueue.main.async { [weak self] in
            self?.runLauncherIfReady()
        }
    }

    private func runLauncherIfReady() {
        guard didFinishLaunch, !didRunLauncher else {
            return
        }
        didRunLauncher = true
        presentExternalLaunchStarting()

        guard let resourcePath = Bundle.main.resourcePath else {
            let failure = CyderFailure(
                code: "CYD-APP-001",
                stage: .resourceValidation,
                summary: "Cyder 缺少必要的 Resources 目錄。",
                technicalDetails: "Bundle.main.resourcePath returned nil.",
                logURL: CyderDiagnostics.shared.sessionLogURL
            )
            presentFailure(failure)
            CyderDiagnostics.shared.finish(outcome: "resource-validation-failed")
            NSApp.terminate(nil)
            return
        }

        let context = CyderLaunchContext(resourcePath: resourcePath)

        libraryLaunchInProgress = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let outcome = self.runPhasedLaunch(context: context)
            DispatchQueue.main.async {
                self.libraryLaunchInProgress = false
                self.hideSetup()
                switch outcome {
                case .success:
                    CyderDiagnostics.shared.finish(outcome: "wine-launched")
                case .cancelled:
                    CyderDiagnostics.shared.finish(outcome: "cancelled")
                case .environmentNotReady:
                    self.showAlert(
                        "遊戲尚未準備完成",
                        "請先單獨開啟 Cyder.app 完成首次準備，再重新開啟遊戲。"
                    )
                    CyderDiagnostics.shared.finish(outcome: "environment-not-ready")
                case .graphicsNotReady:
                    self.showAlert(
                        "圖形元件尚未準備完成",
                        "請先單獨開啟 Cyder.app 準備圖形元件，再重新開啟遊戲。"
                    )
                    CyderDiagnostics.shared.finish(outcome: "graphics-not-ready")
                case .failure(let failure):
                    self.presentFailure(failure)
                    CyderDiagnostics.shared.finish(outcome: "launch-failed")
                }
                self.launchNextQueuedExecutableIfReady()
                if !self.statusItemController.hasActiveSessions,
                   !self.libraryLaunchInProgress,
                   self.queuedLaunches.isEmpty {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func environmentState(context: CyderLaunchContext) -> (needsEngine: Bool, needsBootstrap: Bool) {
        let engineWine = CyderPaths.engine.appendingPathComponent("bin/wine")

        let unsafeEnginePath = CyderPaths.engine.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let needsEngine = unsafeEnginePath
            || !FileManager.default.isExecutableFile(atPath: engineWine.path)
            || engineNeedsInstall(context: context, engineWine: engineWine)
        let sharedSystemReg = CyderPaths.sharedBottle.appendingPathComponent("system.reg").path
        let sharedBaseline = CyderPaths.sharedBottle.appendingPathComponent(".cyder-golden-baseline-v2").path
        var needsBootstrap = !FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path)
            || !FileManager.default.fileExists(atPath: sharedSystemReg)
            || !FileManager.default.fileExists(atPath: sharedBaseline)
        // CrossOver / MapleStory OEM engines need cxbottle.conf; a half-built
        // bottle without it must go through a full replace, not an in-place patch.
        if !needsBootstrap {
            let engineBottleTemplate = CyderPaths.engine
                .appendingPathComponent("share/crossover/bottle_data/cxbottle.conf").path
            if FileManager.default.fileExists(atPath: engineBottleTemplate) {
                let bottleConf = CyderPaths.sharedBottle.appendingPathComponent("cxbottle.conf").path
                if !FileManager.default.isReadableFile(atPath: bottleConf) {
                    needsBootstrap = true
                }
            }
        }
        return (needsEngine, needsBootstrap)
    }

    private func ensureEnvironment(context: CyderLaunchContext) -> CyderFailure? {
        let state = environmentState(context: context)
        let engineWine = CyderPaths.engine.appendingPathComponent("bin/wine")
        let enginePresent = FileManager.default.isExecutableFile(atPath: engineWine.path)

        // Always run ensure-engine-only when an engine tree exists (or needs
        // install). The shell also compares the artifact fingerprint so an
        // updated same-label test engine is refreshed before launch.
        if state.needsEngine || enginePresent {
            CyderDiagnostics.shared.enter(.engineExtraction)
            if state.needsEngine {
                showSetup("正在準備遊戲執行元件…")
            }
            let result = runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--ensure-engine-only"],
                stage: .engineExtraction,
                operation: "engine-install"
            )
            if !result.succeeded {
                return failure(
                    code: "CYD-ENG-003",
                    stage: .engineExtraction,
                    summary: "準備遊戲執行元件時發生問題。",
                    result: result
                )
            }
        }

        CyderDiagnostics.shared.enter(.engineExtraction)
        showSetup("正在準備圖形元件…")
        let graphics = runLauncher(
            context: context,
            args: [context.launcher, "--ensure-graphics-only"],
            stage: .engineExtraction,
            operation: "graphics-install"
        )
        if !graphics.succeeded {
            return failure(
                code: "CYD-GFX-001",
                stage: .engineExtraction,
                summary: "準備圖形元件時發生問題。",
                result: graphics
            )
        }

        // Engine installation can create/replace the engine tree. Recompute
        // the marker decision after that operation so first-run setup cannot
        // be deferred to the next Cyder launch.
        var templatesReady = false
        if !state.needsEngine && !state.needsBootstrap {
            let probe = runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--templates-ready"],
                stage: .bootstrap,
                operation: "templates-ready"
            )
            templatesReady = probe.succeeded
        }
        var bootstrapNeeded = state.needsEngine
            || state.needsBootstrap
            || environmentState(context: context).needsBootstrap
            || !templatesReady && !state.needsEngine
        var bootstrapHealthChecked = false
        if bootstrapNeeded,
           let helper = ProcessInfo.processInfo.environment["CYDER_OEM_BOOTSTRAP_HELPER"],
           !helper.isEmpty {
            CyderDiagnostics.shared.enter(.bootstrap)
            showSetup("正在準備 MapleStory 遊戲環境…")
            let result = runLauncher(
                context: context,
                args: [helper, "--prepare-only"],
                stage: .bootstrap,
                operation: "oem-prepare",
                expectsMachineResult: true
            )
            if !result.succeeded {
                return failure(
                    code: "CYD-BTS-001",
                    stage: .bootstrap,
                    summary: "準備遊戲環境時發生問題。",
                    result: result
                )
            }
            bootstrapHealthChecked = result.machineResult["healthChecked"] == "1"
            bootstrapNeeded = environmentState(context: context).needsBootstrap
        }
        if bootstrapNeeded {
            CyderDiagnostics.shared.enter(.bootstrap)
            showSetup("正在準備遊戲環境…")
            let result = runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only"],
                stage: .bootstrap,
                operation: "bootstrap",
                expectsMachineResult: true
            )
            if !result.succeeded {
                return failure(
                    code: "CYD-BTS-001",
                    stage: .bootstrap,
                    summary: "準備遊戲環境時發生問題。",
                    result: result
                )
            }
            bootstrapHealthChecked = result.machineResult["healthChecked"] == "1"
        }
        // A marker only proves that bootstrap completed once. Probe the
        // current prefix on normal app launches, but reuse the machine-readable
        // result when this same bootstrap operation already completed a probe.
        if !bootstrapHealthChecked {
            CyderDiagnostics.shared.enter(.engineValidation)
            showSetup("正在檢查遊戲環境…")
            let health = runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--health-check"],
                stage: .engineValidation,
                operation: "health-check"
            )
            guard health.succeeded else {
                return failure(
                    code: "CYD-HLT-001",
                    stage: .engineValidation,
                    summary: "Windows 遊戲環境檢查失敗。",
                    result: health
                )
            }
        }
        return nil
    }

    private func prepareEnvironmentAndShowSettings() {
        statusItemController.setUIVisible(true)
        guard let resourcePath = Bundle.main.resourcePath else {
            showSettings()
            return
        }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        let state = environmentState(context: context)
        // Already-initialized installs still probe engine fingerprint + health;
        // avoid implying a full bootstrap when markers are already present.
        if state.needsEngine || state.needsBootstrap {
            showSetup("正在準備遊戲環境…")
        } else {
            showSetup("正在檢查遊戲環境…")
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let preparationFailure = self.ensureEnvironment(context: context)
            DispatchQueue.main.async {
                if self.documentLaunchRequested {
                    self.hideSetup()
                    return
                }
                self.hideSetup()
                if let preparationFailure {
                    if preparationFailure.code == "CYD-GFX-001" {
                        // Graphics payload install must not block settings / Cyder residency.
                        self.showAlert(
                            "圖形元件尚未準備完成",
                            "仍可開啟設定。請確認 Cyder.app 已打包 Resources/graphics，或稍後重新開啟 Cyder 再試一次。"
                        )
                        CyderDiagnostics.shared.finish(outcome: "graphics-ensure-soft-failed")
                    } else {
                        let action = self.presentFailure(
                            preparationFailure,
                            allowsRebuild: preparationFailure.code == "CYD-HLT-001"
                                || preparationFailure.code == "CYD-BTS-001"
                        )
                        if action == .rebuild {
                            self.rebuildEnvironment {
                                self.showSettings()
                            }
                        } else {
                            CyderDiagnostics.shared.finish(outcome: "environment-check-failed")
                            NSApp.terminate(nil)
                        }
                        return
                    }
                }
                if self.openLibraryOnLaunch {
                    self.showGameLibrary()
                } else {
                    self.showSettings()
                }
            }
        }
    }

    private func runPhasedLaunch(context: CyderLaunchContext) -> CyderLaunchOutcome {
        var exePaths = normalizeExePaths(pendingFiles)
        if exePaths.isEmpty {
            hideSetup()
            guard let chosen = chooseExeOnMainThread() else {
                return .cancelled
            }
            exePaths = [chosen]
        }

        // Opening an EXE is a launch-only path. It must never create or repair
        // a prefix invisibly; the user can open Cyder.app to see setup progress
        // and recovery errors.
        let state = environmentState(context: context)
        guard !state.needsEngine, !state.needsBootstrap else {
            return .environmentNotReady
        }

        let wine = CyderPaths.engine.appendingPathComponent("bin/wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            return .environmentNotReady
        }
        if !graphicsPayloadsPresent() {
            // Do not hard-block Finder EXE launches when DXVK/DXMT payloads are
            // absent. Fall back to the available Wine stack and hint the user to
            // open Cyder.app so ensure-graphics can install the payloads.
            showAlert(
                "圖形元件尚未準備完成",
                "仍會嘗試啟動遊戲。若需要 DXVK/DXMT，請先單獨開啟 Cyder.app 準備圖形元件。"
            )
            CyderDiagnostics.shared.info("graphics payloads missing; Finder EXE continuing with fallback")
        }
        let exeURL = URL(fileURLWithPath: exePaths[0])
        switch prefixForExecutable(exeURL) {
        case .success(let prefix):
            return runWineThroughLauncher(
                context: context,
                exe: exeURL.path,
                prefix: prefix,
                launchArguments: pendingLaunchArguments
            )
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func prefixForExecutable(_ executable: URL) -> CyderPrefixResolution {
        let profileStore = CyderProfileStore(root: CyderPaths.support)
        var prefix = CyderPaths.sharedBottle
        switch profileStore.resolve(executable: executable) {
        case .uncreated:
            break
        case .damaged(let id, let reason):
            return .failure(CyderFailure(
                code: "CYD-PRO-002",
                stage: .exeValidation,
                summary: "這個遊戲的設定環境已損毀。",
                technicalDetails: "Profile \(id): \(reason)",
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        case .ready(let record):
            prefix = CyderPaths.support
                .appendingPathComponent("bottles", isDirectory: true)
                .appendingPathComponent(record.profileId, isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: prefix.path) else {
            return .failure(CyderFailure(
                code: "CYD-PRO-003",
                stage: .exeValidation,
                summary: "找不到這個遊戲的 Windows 環境。",
                technicalDetails: prefix.path,
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        }
        return .success(prefix)
    }

    private func graphicsPayloadsPresent() -> Bool {
        let capabilities = CyderGraphicsCapabilities.current(engineRoot: CyderPaths.engine)
        return capabilities.hasDxvk || capabilities.hasDxmt
    }

    private func installWinetricks(_ verbs: [String]) {
        let warning = NSAlert()
        warning.messageText = "安裝 Winetricks 元件？"
        warning.informativeText = "即將安裝：\n\(verbs.joined(separator: ", "))\n\n這會直接修改 Cyder 的 shared prefix。已安裝的元件、DLL override 與 registry 設定可能影響所有共用此環境的遊戲。請先關閉所有遊戲。"
        warning.alertStyle = .warning
        warning.addButton(withTitle: "安裝元件")
        warning.addButton(withTitle: "取消")
        guard runFrontmostAlert(warning, dockVisible: true, anchorWindow: settingsController.window) == .alertFirstButtonReturn else {
            return
        }

        if hasRunningExes() {
            showAlert("無法安裝 Winetricks 元件", "shared prefix 目前仍有遊戲或 Wine 程序執行中。請關閉遊戲後再試。")
            return
        }
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("無法安裝 Winetricks 元件", "Cyder 缺少必要的 Resources 目錄。")
            return
        }

        let context = CyderLaunchContext(resourcePath: resourcePath)
        environmentPreparationInProgress = true
        showSetup("正在安裝 Winetricks 元件…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, "--install-winetricks"] + verbs,
                stage: .settingsApply,
                operation: "install-winetricks"
            )
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if result.succeeded {
                    self.showAlert("Winetricks 元件安裝完成", verbs.joined(separator: ", "), style: .informational)
                } else {
                    self.presentFailure(self.failure(
                        code: "CYD-WT-001",
                        stage: .settingsApply,
                        summary: "無法安裝 Winetricks 元件。",
                        result: result
                    ))
                }
            }
        }
    }

    /// Relay a document-open request to the Bash launch backend. Bash owns
    /// profile selection, saved/test settings, Wine environment construction,
    /// logging, session guards, and the final Wine process spawn.
    private func runWineThroughLauncher(
        context: CyderLaunchContext,
        exe: String,
        prefix: URL,
        launchArguments: [String]? = nil,
        launchEnvironment: [String: String] = [:]
    ) -> CyderLaunchOutcome {
        let activationWaiter = WineActivationWaiter(prefix: prefix.path)
        onMainThread { wineActivationWaiter = activationWaiter }
        defer {
            onMainThread {
                if wineActivationWaiter === activationWaiter {
                    wineActivationWaiter = nil
                }
            }
        }

        let requestDirectory = CyderPaths.support.appendingPathComponent(
            "launch-requests",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: requestDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .failure(CyderFailure(
                code: "CYD-WIN-001",
                stage: .wineSpawn,
                summary: "無法建立 Wine 啟動工作目錄。",
                technicalDetails: String(describing: error),
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        }

        let launchID = UUID().uuidString
        let executableName = URL(fileURLWithPath: exe).deletingPathExtension().lastPathComponent
        onMainThread {
            statusItemController.beginLaunch(
                id: launchID,
                prefix: prefix,
                executableName: executableName,
                pid: 0
            )
        }
        let pidURL = requestDirectory.appendingPathComponent("wine-\(launchID).pid")
        let exitResultURL = requestDirectory.appendingPathComponent("wine-\(launchID).result")
        let activatedURL = requestDirectory.appendingPathComponent("wine-\(launchID).activated")
        let lifecycleURL = requestDirectory.appendingPathComponent("wine-\(launchID).lifecycle")
        var launchActivated = false
        var winePID: Int32 = 0
        var cleanPrimaryExitObserved = false
        defer {
            try? FileManager.default.removeItem(at: pidURL)
            if !launchActivated {
                try? FileManager.default.removeItem(at: exitResultURL)
                try? FileManager.default.removeItem(at: activatedURL)
                try? FileManager.default.removeItem(at: lifecycleURL)
                onMainThread {
                    statusItemController.endLaunch(id: launchID)
                }
            }
        }
        var args = [context.launcher, "--engine-src", context.engineSrc, "--launch-exe", exe]
        if let launchArguments, !launchArguments.isEmpty {
            args.append("--")
            args.append(contentsOf: launchArguments)
        }
        var wineLaunchEnvironment = launchEnvironment
        // Internal transport and lifecycle keys always win over per-game
        // environment values.
        wineLaunchEnvironment.merge([
            "CYDER_WINE_DETACH": "1",
            "CYDER_WINE_PID_FILE": pidURL.path,
            "CYDER_WINE_RESULT_FILE": exitResultURL.path,
            "CYDER_WINE_ACTIVATED_FILE": activatedURL.path,
            "CYDER_WINE_LIFECYCLE_FILE": lifecycleURL.path,
            "CYDER_SESSION_GUARD": "1",
            // Always retain the quiet startup stream for optional manual
            // diagnosis. UI classification uses the per-launch wait result
            // below and does not depend on Wine log text.
            "CYDER_CAPTURE_WINE_LOG": "1",
        ]) { _, internalValue in internalValue }
        let result = runLauncher(
            context: context,
            args: args,
            stage: .wineSpawn,
            operation: "wine-launch",
            extraEnvironment: wineLaunchEnvironment
        )
        guard result.succeeded else {
            return .failure(failure(
                code: "CYD-WIN-001",
                stage: .wineSpawn,
                summary: "Bash 無法啟動 Wine。",
                result: result
            ))
        }

        winePID = {
            guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
                  let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  value > 0 else { return 0 }
            return value
        }()
        if winePID > 0 {
            onMainThread {
                statusItemController.attachRootPID(id: launchID, pid: winePID)
                if #available(macOS 11.0, *),
                   let resourcePath = Bundle.main.resourcePath {
                    let context = CyderLaunchContext(resourcePath: resourcePath)
                    CyderURIHandlerManager.shared.beginWineSession(
                        prefix: prefix,
                        launcher: context.launcher
                    )
                }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if activationWaiter.semaphore.wait(timeout: .now() + 0.5) == .success {
                launchActivated = true
                FileManager.default.createFile(atPath: activatedURL.path, contents: Data())
                CyderDiagnostics.shared.enter(.wineActivation, detail: "notification-received")
                onMainThread { statusItemController.markActivated(pid: winePID) }
                return .success
            }
            if let exitStatus = detachedWineExitStatus(at: exitResultURL) {
                if exitStatus == 0 {
                    if !cleanPrimaryExitObserved {
                        cleanPrimaryExitObserved = true
                        CyderDiagnostics.shared.info(
                            "wine primary exited cleanly before activation pid=\(winePID); waiting for handoff or lifecycle completion"
                        )
                    }
                    if detachedWineLifecycleState(at: lifecycleURL) == "stopped" {
                        CyderDiagnostics.shared.info(
                            "wine launch completed without activation pid=\(winePID)"
                        )
                        return .success
                    }
                } else {
                    return earlyWineExitFailure(
                        executablePath: exe,
                        winePID: winePID,
                        exitStatus: exitStatus,
                        fallbackLogURL: result.logURL
                    )
                }
            }
            if winePID > 0, kill(winePID, 0) != 0 {
                // The supervisor publishes the wait status immediately after
                // reaping Wine. Allow a short scheduling window before falling
                // back to the generic early-exit failure.
                for _ in 0..<5 {
                    if let exitStatus = detachedWineExitStatus(at: exitResultURL) {
                        if exitStatus == 0 {
                            cleanPrimaryExitObserved = true
                            break
                        }
                        return earlyWineExitFailure(
                            executablePath: exe,
                            winePID: winePID,
                            exitStatus: exitStatus,
                            fallbackLogURL: result.logURL
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if detachedWineLifecycleState(at: lifecycleURL) == "stopped",
                   detachedWineExitStatus(at: lifecycleURL) == 0 {
                    CyderDiagnostics.shared.info(
                        "wine launch completed without activation pid=\(winePID)"
                    )
                    return .success
                }
                if detachedWineExitStatus(at: lifecycleURL) == 0 {
                    cleanPrimaryExitObserved = true
                }
                if !cleanPrimaryExitObserved {
                    return earlyWineExitFailure(
                        executablePath: exe,
                        winePID: winePID,
                        exitStatus: detachedWineExitStatus(at: lifecycleURL),
                        fallbackLogURL: result.logURL
                    )
                }
            }
        }
        CyderDiagnostics.shared.warning(
            "wine activation timed out after 30s pid=\(winePID); process remains detached"
        )
        // Observation stops after the compatibility timeout; let the Bash
        // supervisor consume the eventual sidecar just like an activation.
        launchActivated = true
        FileManager.default.createFile(atPath: activatedURL.path, contents: Data())
        onMainThread { statusItemController.markActivated(pid: winePID) }
        return .success
    }

    private func runPrefixAction(_ action: String, prefix: URL, operation: String) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, action, prefix.path],
                stage: .wineSpawn,
                operation: operation
            )
            if !result.succeeded {
                DispatchQueue.main.async {
                    if action == "--stop-prefix" {
                        self.statusItemController.markStopFailed(prefix: prefix)
                        self.quitWhenSessionsEnd = false
                    }
                    self.showAlert("操作未完成", "無法對這個 Windows 環境執行操作。")
                }
            } else if action == "--stop-prefix" {
                DispatchQueue.main.async {
                    self.statusItemController.markPrefixStopped(prefix: prefix)
                }
            }
        }
    }

    @objc private func quitFromMenu() {
        let prefixes = statusItemController.monitoredPrefixes
        if prefixes.isEmpty {
            NSApp.terminate(nil)
        } else {
            requestQuitAndStop(prefixes: prefixes)
        }
    }

    private func requestQuitAndStop(prefixes: [URL]) {
        let alert = NSAlert()
        alert.messageText = "結束所有 Cyder 程序？"
        alert.informativeText = prefixes.count == 1
            ? "這會關閉目前 Windows 環境中的遊戲與背景程序。未儲存的內容可能遺失。"
            : "這會關閉目前 \(prefixes.count) 個 Windows 環境中的遊戲與背景程序。未儲存的內容可能遺失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "結束程序")
        alert.addButton(withTitle: "取消")
        guard runFrontmostAlert(alert, dockVisible: false) == .alertFirstButtonReturn else { return }
        quitWhenSessionsEnd = true
        settingsController.window?.orderOut(nil)
        gameLibraryController.window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        statusItemController.markStopping(prefixes: prefixes)
        for prefix in prefixes {
            runPrefixAction("--stop-prefix", prefix: prefix, operation: "stop-prefix")
        }
    }

    private func detachedWineExitStatus(at resultURL: URL) -> Int32? {
        guard let value = detachedWineSidecarValue("exit_status", at: resultURL) else {
            return nil
        }
        return Int32(value)
    }

    private func detachedWineLifecycleState(at lifecycleURL: URL) -> String? {
        detachedWineSidecarValue("state", at: lifecycleURL)
    }

    private func detachedWineSidecarValue(_ key: String, at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let prefix = "\(key)="
        return text.split(whereSeparator: { $0.isNewline })
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func earlyWineExitFailure(
        executablePath: String,
        winePID: Int32,
        exitStatus: Int32?,
        fallbackLogURL: URL
    ) -> CyderLaunchOutcome {
        let executable = URL(fileURLWithPath: executablePath)
        if exitStatus == 53,
           let protectedLocation = protectedGameLocation(for: executable) {
            let launchLog = CyderPaths.support
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("last-launch.log")
            return .failure(CyderFailure(
                code: "CYD-WIN-003",
                stage: .wineSpawn,
                summary: "遊戲位於 macOS 可能限制存取的「\(protectedLocation)」。請將整個遊戲資料夾移到 ~/Games 後再試。",
                technicalDetails: "Wine exited before activation with status 53, which is consistent with truncated Windows status 0xC0000135. Executable: \(executable.path)",
                logURL: FileManager.default.fileExists(atPath: launchLog.path) ? launchLog : fallbackLogURL
            ))
        }
        let statusDetail = exitStatus.map(String.init) ?? "unavailable"
        return .failure(CyderFailure(
            code: "CYD-WIN-002",
            stage: .wineSpawn,
            summary: "Wine 啟動後在顯示遊戲視窗前結束。",
            technicalDetails: "Detached Wine PID \(winePID) exited before activation (status: \(statusDetail)).",
            logURL: fallbackLogURL
        ))
    }

    private func protectedGameLocation(for executable: URL) -> String? {
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations: [(String, URL)] = [
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true)),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)),
            ("Cloud Storage", home.appendingPathComponent("Library/CloudStorage", isDirectory: true)),
        ]
        for (name, directory) in locations {
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == root || resolved.hasPrefix(root + "/") {
                return name
            }
        }
        if resolved == "/Volumes" || resolved.hasPrefix("/Volumes/") {
            return "外接或網路磁碟"
        }
        return nil
    }

    @objc private func wineAppWillActivate(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        let pid = (userInfo["ActivatingAppPID"] as? NSNumber)?.int32Value ?? 0
        let prefix = userInfo["ActivatingAppPrefix"] as? String ?? ""

        let handle = { [weak self] in
            guard let self, pid > 0, !prefix.isEmpty else { return }

            let standardizedPrefix = (prefix as NSString).standardizingPath
            let waiter = self.wineActivationWaiter
            let matchesLaunchWaiter = waiter?.prefix == standardizedPrefix
            let belongsToMonitoredSession = self.statusItemController.isMonitoring(prefix: standardizedPrefix)
            guard matchesLaunchWaiter || belongsToMonitoredSession else { return }

            // Dismiss starting UI as soon as Wine reports an activating
            // process. Some Win32 dialogs never become a Dock/.regular app.
            if matchesLaunchWaiter {
                self.wineActivationWaiter = nil
                waiter?.semaphore.signal()
            }
            self.hideSetup()

            // Attach the visible Wine process to the existing session so a
            // launcher like GGMWebStart can exit without looking like "background
            // cleanup" while MapleStory (or another windowed EXE) is running.
            self.statusItemController.adoptWindowedProcess(
                pid: pid,
                prefix: standardizedPrefix,
                name: NSRunningApplication(processIdentifier: pid)?.localizedName
            )

            // The notification comes from the Wine Cocoa process that is
            // ready to become foreground. Cooperatively hand activation to it
            // on macOS 14+, without PID searches or activation polling. Keep
            // doing this for monitored sessions after the initial launch so a
            // background Cyder instance can forward later focus requests.
            guard let application = NSRunningApplication(processIdentifier: pid) else { return }
            if application.activationPolicy != .regular {
                return
            }
            if #available(macOS 14.0, *) {
                let source = NSRunningApplication.current
                NSApp.yieldActivation(to: application)
                _ = application.activate(from: source, options: [.activateAllWindows])
            } else {
                _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            if !matchesLaunchWaiter {
                CyderDiagnostics.shared.info(
                    "forwarded Wine activation pid=\(pid) prefix=\(standardizedPrefix)"
                )
            }
        }
        if Thread.isMainThread {
            handle()
        } else {
            DispatchQueue.main.async(execute: handle)
        }
    }

    @objc private func wineWorkspaceDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isWineMacApplication(application) else { return }
        let pid = application.processIdentifier
        let handle = { [weak self] in
            guard let self, pid > 0 else { return }
            let prefix = winePrefix(forProcess: pid) ?? self.wineActivationWaiter?.prefix ?? ""
            guard !prefix.isEmpty else { return }
            let standardizedPrefix = (prefix as NSString).standardizingPath
            let waiter = self.wineActivationWaiter
            let matchesLaunchWaiter = waiter?.prefix == standardizedPrefix
            let belongsToMonitoredSession = self.statusItemController.isMonitoring(prefix: standardizedPrefix)
            guard matchesLaunchWaiter || belongsToMonitoredSession else { return }

            if matchesLaunchWaiter {
                self.wineActivationWaiter = nil
                waiter?.semaphore.signal()
            }
            self.statusItemController.adoptWindowedProcess(
                pid: pid,
                prefix: standardizedPrefix,
                name: application.localizedName
            )
            self.hideSetup()
        }
        if Thread.isMainThread {
            handle()
        } else {
            DispatchQueue.main.async(execute: handle)
        }
    }

    @objc private func wineWorkspaceDidTerminate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isWineMacApplication(application) else { return }
        let pid = application.processIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.statusItemController.noteProcessExited(pid)
        }
    }

    private func engineNeedsInstall(context: CyderLaunchContext, engineWine: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: context.engineVersionFile) else {
            return false
        }
        guard let bundled = try? String(contentsOfFile: context.engineVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundled.isEmpty
        else {
            return false
        }
        let installedFile = engineWine
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("version")
        guard let installed = try? String(contentsOfFile: installedFile.path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !installed.isEmpty
        else {
            return true
        }
        if !engineVersionsEqual(installed, bundled) {
            return true
        }
        let resources = URL(fileURLWithPath: context.engineVersionFile).deletingLastPathComponent()
        let bundledFingerprintFile = resources.appendingPathComponent("engine-artifact-sha256.txt")
        guard let bundledFingerprint = try? String(contentsOf: bundledFingerprintFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundledFingerprint.isEmpty
        else {
            return false
        }
        let installedFingerprintFile = installedFile.deletingLastPathComponent()
            .appendingPathComponent(".cyder-engine-artifact-sha256")
        let installedFingerprint = try? String(contentsOf: installedFingerprintFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedFingerprint != bundledFingerprint
    }

    /// Packaging metadata historically used either a display label
    /// (`wine crossover 26.2.0 (wine 11.0)`) or its filesystem-safe slug
    /// (`crossover-26.2.0-wine-11.0`). Both identify the same engine.
    private func engineVersionsEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        return engineVersionSlug(lhs) == engineVersionSlug(rhs)
    }

    private func engineVersionSlug(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "wine crossover "
        if value.hasPrefix(prefix),
           let wineMarker = value.range(of: " (wine ", options: .backwards),
           value.hasSuffix(")") {
            let crossover = value[value.index(value.startIndex, offsetBy: prefix.count)..<wineMarker.lowerBound]
            let wineStart = wineMarker.upperBound
            let wineEnd = value.index(before: value.endIndex)
            let wine = value[wineStart..<wineEnd]
            return "crossover-\(crossover)-wine-\(wine)"
                .replacingOccurrences(of: " ", with: "-")
        }
        return value
    }

    private func onMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func showSetup(_ message: String) {
        onMainThread {
            if setupPanel == nil {
                setupPanel = CyderSetupPanel()
                setupPanel?.show()
            }
            setupPanel?.setMessage(message)
        }
    }

    private func hideSetup() {
        onMainThread {
            setupPanel?.close()
            setupPanel = nil
        }
    }

    private func showAlert(
        _ title: String,
        _ message: String,
        style: NSAlert.Style = .warning
    ) {
        onMainThread {
            // Finder launches begin as an accessory app. Promote Cyder before
            // presenting any modal alert so warnings cannot appear invisibly.
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            _ = runFrontmostAlert(
                alert,
                dockVisible: terminateWhenSettingsClose && !documentLaunchRequested,
                anchorWindow: terminateWhenSettingsClose && !documentLaunchRequested
                    ? settingsController.window
                    : nil
            )
        }
    }

    private func showPreviousCrashIfNeeded() {
        guard let previous = CyderDiagnostics.shared.previousUnexpectedSession else { return }
        onMainThread {
            let alert = NSAlert()
            alert.messageText = "Cyder 上次未正常結束"
            alert.informativeText = "上次執行在「\(previous.stage)」階段中斷。已保留診斷記錄，您可以繼續使用 Cyder。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "繼續")
            alert.addButton(withTitle: "開啟上次記錄")
            let response = runFrontmostAlert(alert, dockVisible: true)
            if response == .alertSecondButtonReturn, !previous.logPath.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: previous.logPath)])
            }
        }
    }

    @discardableResult
    private func presentFailure(
        _ failure: CyderFailure,
        allowsRebuild: Bool = false
    ) -> CyderFailureAction {
        CyderDiagnostics.shared.record(failure)
        if failure.code == "CYD-WIN-003" {
            presentProtectedGameFolderFailure(failure)
            return .close
        }
        var action: CyderFailureAction = .close
        onMainThread {
            let alert = NSAlert()
            alert.messageText = "Cyder 發生錯誤"
            var message = "\(failure.summary)\n\n錯誤代碼：\(failure.code)\n階段：\(failure.stage.rawValue)"
            if let exitCode = failure.exitCode {
                message += "\n結束狀態：\(exitCode)"
            }
            alert.informativeText = message
            alert.alertStyle = .critical
            if !failure.technicalDetails.isEmpty {
                let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 150))
                scrollView.hasVerticalScroller = true
                scrollView.borderType = .bezelBorder
                let textView = NSTextView(frame: scrollView.bounds)
                textView.isEditable = false
                textView.isSelectable = true
                textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                textView.string = CyderDiagnostics.shared.redact(failure.technicalDetails)
                scrollView.documentView = textView
                alert.accessoryView = scrollView
            }
            alert.addButton(withTitle: "關閉")
            alert.addButton(withTitle: "複製診斷資訊")
            alert.addButton(withTitle: "開啟相關記錄")
            if allowsRebuild {
                alert.addButton(withTitle: "重建 Windows 遊戲環境")
            }
            let response = runFrontmostAlert(
                alert,
                dockVisible: terminateWhenSettingsClose && !documentLaunchRequested
            )
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    CyderDiagnostics.shared.redact(failure.diagnosticText),
                    forType: .string
                )
            } else if response == .alertThirdButtonReturn {
                let selected = failure.logURL ?? CyderDiagnostics.shared.sessionLogURL
                NSWorkspace.shared.activateFileViewerSelecting([selected])
            } else if allowsRebuild,
                      response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1 {
                action = .rebuild
            }
        }
        return action
    }

    private func presentProtectedGameFolderFailure(_ failure: CyderFailure) {
        onMainThread {
            let alert = NSAlert()
            alert.messageText = "無法讀取完整的遊戲資料夾"
            alert.informativeText = failure.summary
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打開 Games 資料夾")
            alert.addButton(withTitle: "關閉")
            alert.addButton(withTitle: "開啟相關記錄")
            let response = runFrontmostAlert(
                alert,
                dockVisible: terminateWhenSettingsClose && !documentLaunchRequested
            )
            if response == .alertFirstButtonReturn {
                openRecommendedGamesDirectory()
            } else if response == .alertThirdButtonReturn {
                let selected = failure.logURL ?? CyderDiagnostics.shared.sessionLogURL
                NSWorkspace.shared.activateFileViewerSelecting([selected])
            }
        }
    }

    private func openRecommendedGamesDirectory() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "CyderRecommendedGamesDirectory") as? String
        let configuredPath = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "~/Games"
        let relative = configuredPath
            .replacingOccurrences(of: "~/", with: "")
        let games = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
            NSWorkspace.shared.open(games)
        } catch {
            showAlert("無法建立 Games 資料夾", error.localizedDescription, style: .critical)
        }
    }

    private func chooseExeOnMainThread() -> String? {
        var result: String?
        onMainThread {
            let panel = NSOpenPanel()
            panel.title = "Cyder"
            panel.message = "選擇 Windows 遊戲執行檔 (.exe)"
            panel.prompt = "開啟"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            let settingsButton = NSButton(title: "進階設定…", target: self, action: #selector(showSettingsModal))
            settingsButton.bezelStyle = .rounded
            panel.accessoryView = settingsButton
            if #available(macOS 11.0, *) {
                var types: [UTType] = [.executable, .data]
                if let exeType = UTType(filenameExtension: "exe") {
                    types.insert(exeType, at: 0)
                }
                panel.allowedContentTypes = types
            }
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            result = url.path
        }
        return result
    }

    private func runLauncher(
        context: CyderLaunchContext,
        args: [String],
        stage: CyderStage,
        operation: String,
        extraEnvironment: [String: String] = [:],
        expectsMachineResult: Bool = false
    ) -> CyderProcessResult {
        CyderDiagnostics.shared.enter(stage, detail: operation)
        let operationLog = CyderDiagnostics.shared.makeOperationLog(operation)
        do {
            try CyderDiagnostics.shared.prepareOperationLog(at: operationLog)
        } catch {
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: "Unable to prepare operation log at \(operationLog.path): \(error)"
            )
        }
        guard let handle = FileHandle(forWritingAtPath: operationLog.path) else {
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: "Unable to create operation log at \(operationLog.path)"
            )
        }
        if operationLog.lastPathComponent == "settings-apply.log" {
            _ = try? handle.seekToEnd()
            let separator = "\n===== Cyder settings apply \(ISO8601DateFormatter().string(from: Date())) =====\n"
            try? handle.write(contentsOf: Data(separator.utf8))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = args
        var environment = context.environment
        for (key, value) in CyderSettingsStore.shared.environment {
            environment[key] = value
        }
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        let resultURL = operationLog
            .deletingPathExtension()
            .appendingPathExtension("result.plist")
        if expectsMachineResult {
            try? FileManager.default.removeItem(at: resultURL)
            environment["CYDER_RESULT_FILE"] = resultURL.path
        }
        let trackProgress = args.contains("--bootstrap-only")
            || args.contains("--rebuild-prefix")
            || args.contains("--profile-create")
        let progressURL = operationLog
            .deletingPathExtension()
            .appendingPathExtension("progress.txt")
        if trackProgress {
            try? FileManager.default.removeItem(at: progressURL)
            environment["CYDER_PROGRESS_FILE"] = progressURL.path
        }
        environment["CYDER_DIAGNOSTIC_SESSION_ID"] = CyderDiagnostics.shared.sessionID
        environment["CYDER_DIAGNOSTIC_STAGE"] = stage.rawValue
        environment["CYDER_DIAGNOSTIC_LOG"] = operationLog.path
        process.environment = environment
        let command = CyderDiagnostics.shared.redact(
            "cmd=/bin/bash \(args.joined(separator: " "))\nstage=\(stage.rawValue)\n\n"
        )
        try? handle.write(contentsOf: Data(command.utf8))
        process.standardOutput = handle
        process.standardError = handle

        var progressTimer: DispatchSourceTimer?
        var lastProgress = ""
        if trackProgress {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard let data = try? Data(contentsOf: progressURL),
                      let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      text != lastProgress
                else {
                    return
                }
                lastProgress = text
                self.showSetup(text)
            }
            progressTimer = timer
            timer.resume()
        }

        do {
            try process.run()
            process.waitUntilExit()
            progressTimer?.cancel()
            progressTimer = nil
            try? handle.close()
            CyderDiagnostics.shared.trimRollingOperationLog(at: operationLog)
            try? FileManager.default.removeItem(at: progressURL)
            let tail = CyderDiagnostics.shared.tail(of: operationLog)
            var machineResult: [String: String] = [:]
            if expectsMachineResult,
               let data = try? Data(contentsOf: resultURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let dictionary = plist as? [String: Any] {
                for (key, value) in dictionary where key != "schemaVersion" {
                    if let value = value as? String { machineResult[key] = value }
                }
            }
            try? FileManager.default.removeItem(at: resultURL)
            CyderDiagnostics.shared.info(
                "operation=\(operation) status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) log=\(operationLog.path)"
            )
            return CyderProcessResult(
                status: process.terminationStatus,
                terminationReason: process.terminationReason,
                logURL: operationLog,
                outputTail: tail,
                machineResult: machineResult
            )
        } catch {
            progressTimer?.cancel()
            try? handle.close()
            try? FileManager.default.removeItem(at: progressURL)
            let message = "Failed to run launcher: \(error)"
            CyderDiagnostics.shared.warning(message)
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: message
            )
        }
    }

    private func failure(
        code: String,
        stage: CyderStage,
        summary: String,
        result: CyderProcessResult
    ) -> CyderFailure {
        var details = result.outputTail
        let relatedLogName: String?
        switch stage {
        case .bootstrap:
            relatedLogName = "bootstrap-error.log"
        case .engineExtraction:
            relatedLogName = "engine-install.log"
        default:
            relatedLogName = nil
        }
        if let relatedLogName {
            let relatedLog = CyderPaths.support
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(relatedLogName)
            let relatedTail = CyderDiagnostics.shared.tail(of: relatedLog)
            if !relatedTail.isEmpty {
                details += "\n\n--- \(relatedLogName) ---\n\(relatedTail)"
            }
        }
        return CyderFailure(
            code: code,
            stage: stage,
            summary: summary,
            technicalDetails: details,
            exitCode: result.status,
            terminationReason: result.terminationDescription,
            logURL: result.logURL
        )
    }

    @available(macOS 11.0, *)
    private func configureURIHandler() {
        CyderURIHandlerManager.shared.setConsentHandler { [weak self] handler, completion in
            DispatchQueue.main.async {
                self?.presentURIHandlerConsent(handler: handler, completion: completion)
            }
        }
    }

    @available(macOS 11.0, *)
    private func handleWineSessionEnded(prefix: URL) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        CyderURIHandlerManager.shared.wineSessionEnded(prefix: prefix, launcher: context.launcher)
    }

    @available(macOS 11.0, *)
    private func presentURIHandlerConsent(
        handler: CyderURIHandlerRecord,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "是否讓 Cyder 接收 gamaniagames:// ？"
        alert.informativeText =
            "Cyder 偵測到 gamania Games Manager 已註冊 gamaniagames://。\n是否讓 Cyder 接收此網址，並使用 \(handler.executableName) 啟動遊戲？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "允許並設為預設")
        alert.addButton(withTitle: "不要")
        let accepted = runFrontmostAlert(alert, dockVisible: true) == .alertFirstButtonReturn
        completion(accepted)
    }

    @available(macOS 11.0, *)
    private func enqueueOrLaunchURIs(_ uris: [String]) {
        guard !uris.isEmpty else { return }
        presentExternalLaunchStarting()
        for uri in uris {
            queuedLaunches.append(QueuedLaunch(executable: uri, arguments: nil, isURI: true))
        }
        launchNextQueuedExecutableIfReady()
    }

    private func presentExternalLaunchStarting() {
        documentLaunchRequested = true
        terminateWhenSettingsClose = false
        NSApp.setActivationPolicy(.accessory)
        statusItemController.markLaunchStarted()
        showSetup("正在啟動程式…")
        if settingsController.window?.isVisible == true {
            settingsController.close()
        }
    }

    private func launchModeDetail() -> String {
        if !pendingFiles.isEmpty { return "finder-exe" }
        if documentLaunchRequested { return "uri" }
        return "settings"
    }

    @available(macOS 11.0, *)
    private func launchURI(_ uri: String) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        let prefix = CyderPaths.sharedBottle
        switch CyderURIHandlerManager.shared.validateLaunch(prefix: prefix, launcher: context.launcher) {
        case .failure(let error):
            hideSetup()
            showAlert("無法開啟 gamaniagames://", error.localizedDescription)
            launchNextQueuedExecutableIfReady()
            return
        case .success(let handler):
            CyderDiagnostics.shared.info(
                "uri-launch scheme=gamaniagames length=\(uri.count) exe=\(handler.executableName)"
            )
            libraryLaunchInProgress = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let outcome = self.runWineThroughLauncher(
                    context: context,
                    exe: handler.resolvedExecutable,
                    prefix: prefix,
                    launchArguments: [uri]
                )
                DispatchQueue.main.async {
                    self.libraryLaunchInProgress = false
                    self.hideSetup()
                    if case .failure(let failure) = outcome {
                        self.presentFailure(failure)
                    }
                    self.launchNextQueuedExecutableIfReady()
                }
            }
        }
    }

    @available(macOS 11.0, *)
    private func scanURIHandlersForSettings(
        completion: @escaping (CyderURIHandlerRecord?, Bool) -> Void
    ) {
        guard let resourcePath = Bundle.main.resourcePath else {
            completion(nil, false)
            return
        }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        CyderURIHandlerManager.shared.scanAsync(
            prefix: CyderPaths.sharedBottle,
            launcher: context.launcher
        ) { record in
            completion(record, CyderURIHandlerManager.shared.isCyderDefaultHandler())
        }
    }

    @available(macOS 11.0, *)
    private func enableURIHandlerFromSettings(record: CyderURIHandlerRecord) -> Bool {
        guard record.isValid else { return false }
        let ok = CyderURIHandlerManager.shared.enableCyderHandler(for: record)
        if !ok {
            showAlert("無法啟用 URI 協定", "macOS 未能將 Cyder 設為 gamaniagames:// 的預設處理程式。")
        }
        return ok
    }

    @available(macOS 11.0, *)
    private func disableURIHandlerFromSettings() -> Bool {
        CyderURIHandlerManager.shared.disableCyderHandler()
    }
}

@main
struct CyderMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--sentinel-connect") {
            exit(CyderSentinelConnect.run(arguments: CommandLine.arguments))
        }
        _ = CyderDiagnostics.shared
        let app = NSApplication.shared
        let delegate = CyderAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
