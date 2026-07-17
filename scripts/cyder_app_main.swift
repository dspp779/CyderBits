// Cyder.app entry — phased setup UI, then launch Windows EXE directly with Wine.
import Cocoa
import Foundation
import UniformTypeIdentifiers

private enum CyderLaunchOutcome {
    case success
    case cancelled
    case environmentNotReady
    case failure(CyderFailure)
}

private enum CyderFailureAction: Equatable {
    case close
    case rebuild
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false
    private var documentLaunchRequested = false
    private var openLibraryOnLaunch = false
    private var setupPanel: CyderSetupPanel?
    private var terminateWhenSettingsClose = false
    private var openingGameLibrary = false
    private var environmentPreparationInProgress = false
    private var wineActivationWaiter: WineActivationWaiter?
    private var pendingGameSettings: CyderExecutableSettings?
    private lazy var settingsController: CyderSettingsWindowController = {
        let controller = CyderSettingsWindowController()
        controller.onImmediateSave = { [weak self] registrySetting in
            self?.applySettingsImmediately(registrySetting: registrySetting) ?? false
        }
        controller.onApplyAll = { [weak self] shouldStopAll in
            self?.prepareEnvironmentAfterSettings(stopAll: shouldStopAll)
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
        controller.onRebuild = { [weak self] in self?.rebuildEnvironment() }
        controller.onCreateProfile = { [weak self] executable in
            self?.createIndependentProfile(for: executable)
        }
        controller.onOpenGameLibrary = { [weak self] in
            self?.showGameLibrary()
        }
        controller.onClose = { [weak self] in
            guard let self, self.terminateWhenSettingsClose,
                  !self.environmentPreparationInProgress,
                  !self.openingGameLibrary,
                  self.gameLibraryController.window?.isVisible != true else { return }
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
        controller.onClose = { [weak self] in
            guard let self,
                  self.terminateWhenSettingsClose,
                  !self.environmentPreparationInProgress,
                  self.settingsController.window?.isVisible != true,
                  !self.gameLibraryController.isGameSettingsVisible else { return }
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
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let executableFiles = normalizeExePaths(filenames)
        CyderDiagnostics.shared.info(
            "open-files received=\(filenames.count) executable=\(executableFiles.count) bundle=\(Bundle.main.bundlePath)"
        )
        guard !executableFiles.isEmpty else {
            application.reply(toOpenOrPrint: .failure)
            return
        }
        if gameLibraryController.window?.isVisible == true {
            executableFiles.forEach {
                openGameInDetachedCyder(URL(fileURLWithPath: $0))
            }
            application.reply(toOpenOrPrint: .success)
            return
        }
        documentLaunchRequested = true
        terminateWhenSettingsClose = false
        NSApp.setActivationPolicy(.accessory)
        if settingsController.window?.isVisible == true {
            settingsController.close()
        }
        pendingFiles.append(contentsOf: executableFiles)
        application.reply(toOpenOrPrint: .success)
        if ProcessInfo.processInfo.environment["CYDER_OPEN_FILES_SELF_TEST"] == "1" {
            return
        }
        scheduleRun()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(wineAppWillActivate(_:)),
            name: Notification.Name("WineAppWillActivateNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        installMainMenu()
        didFinishLaunch = true
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
        var argumentIndex = 1
        while argumentIndex < CommandLine.arguments.count {
            let arg = CommandLine.arguments[argumentIndex]
            if arg.hasPrefix("-psn_") || arg == "--args" {
                argumentIndex += 1
                continue
            }
            if arg == "--game-library" {
                openLibraryOnLaunch = true
                argumentIndex += 1
                continue
            }
            if arg == "--cyder-test-settings",
               argumentIndex + 1 < CommandLine.arguments.count {
                let requestPath = CommandLine.arguments[argumentIndex + 1]
                if let data = try? Data(contentsOf: URL(fileURLWithPath: requestPath)),
                   let settings = try? JSONDecoder().decode(CyderExecutableSettings.self, from: data) {
                    pendingGameSettings = settings
                }
                try? FileManager.default.removeItem(atPath: requestPath)
                argumentIndex += 2
                continue
            }
            pendingFiles.append(arg)
            argumentIndex += 1
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
            detail: documentLaunchRequested ? "finder-exe" : "settings"
        )
        CyderDiagnostics.shared.info(
            "launch-context args=\(CommandLine.arguments.count - 1) pending=\(pendingFiles.count) bundle=\(Bundle.main.bundlePath)"
        )
        // LaunchServices can deliver application(_:openFiles:) just after
        // applicationDidFinishLaunching. Defer the settings-mode decision one
        // short turn so a document launch cannot start a competing health
        // check or expose the settings window behind an EXE launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.documentLaunchRequested || !self.pendingFiles.isEmpty {
                self.scheduleRun()
            } else {
                self.terminateWhenSettingsClose = true
                self.openLibraryOnLaunch = self.openLibraryOnLaunch || self.shouldOpenGameLibraryOnLaunch()
                activateCyderUI(dockVisible: true)
                self.prepareEnvironmentAndShowSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        CyderDiagnostics.shared.finish(outcome: "terminated")
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
        appMenu.addItem(withTitle: "結束 Cyder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        activateCyderUI(dockVisible: true)
        settingsController.prepareForDisplay()
        settingsController.showWindow(nil)
        settingsController.window?.makeKeyAndOrderFront(nil)
        settingsController.window?.orderFrontRegardless()
    }

    @objc private func showGameLibrary() {
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

    private func launchGameFromLibrary(_ executable: URL, settings: CyderExecutableSettings?) {
        openGameInDetachedCyder(executable, settings: settings)
    }

    private func openGameInDetachedCyder(_ executable: URL, settings: CyderExecutableSettings? = nil) {
        var arguments = [executable.path]
        if let settings {
            do {
                let requestDirectory = CyderPaths.support.appendingPathComponent("launch-requests", isDirectory: true)
                try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
                let request = requestDirectory.appendingPathComponent("test-\(UUID().uuidString).json")
                try JSONEncoder.pretty.encode(settings).write(to: request, options: .atomic)
                arguments += ["--cyder-test-settings", request.path]
            } catch {
                showAlert("無法啟動測試", "無法建立暫存的遊戲設定：\(error.localizedDescription)")
                return
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration,
            completionHandler: nil
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
        guard let resourcePath = Bundle.main.resourcePath else { return }
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

    private func prepareEnvironmentAfterSettings(stopAll: Bool) {
        guard terminateWhenSettingsClose,
              let resourcePath = Bundle.main.resourcePath else { return }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if stopAll {
                self.showSetup("正在關閉遊戲…")
                self.stopAllExes()
            }
            // The environment was already prepared and health-checked before
            // the settings window was shown. Re-running ensureEnvironment here
            // made Confirm unnecessarily repeat wine/cmd probes.
            self.showSetup("正在套用新設定…")
            let result = self.runLauncher(
                context: context,
                args: [context.launcher, "--apply-settings-only"],
                stage: .settingsApply,
                operation: "apply-settings",
                extraEnvironment: ["CYDER_FORCE_SETTINGS": "1"]
            )
            var settingsFailure: CyderFailure?
            if !result.succeeded {
                settingsFailure = self.failure(
                    code: "CYD-SET-002",
                    stage: .settingsApply,
                    summary: "套用設定時發生問題。",
                    result: result
                )
            }
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if settingsFailure == nil {
                    self.showAlert(
                        "設定完成",
                        "新設定已儲存，下次開啟遊戲時會自動使用。",
                        style: .informational
                    )
                    CyderDiagnostics.shared.finish(outcome: "settings-completed")
                } else if let settingsFailure {
                    self.presentFailure(settingsFailure)
                    CyderDiagnostics.shared.finish(outcome: "settings-failed")
                }
                NSApp.terminate(nil)
            }
        }
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
        NSApp.setActivationPolicy(.accessory)

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let outcome = self.runPhasedLaunch(context: context)
            DispatchQueue.main.async {
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
                case .failure(let failure):
                    self.presentFailure(failure)
                    CyderDiagnostics.shared.finish(outcome: "launch-failed")
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func environmentState(context: CyderLaunchContext) -> (needsEngine: Bool, needsBootstrap: Bool) {
        let engineWine = CyderPaths.engine.appendingPathComponent("bin/wine")

        let unsafeEnginePath = CyderPaths.engine.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let needsEngine = unsafeEnginePath
            || !FileManager.default.isExecutableFile(atPath: engineWine.path)
            || engineNeedsInstall(context: context, engineWine: engineWine)
        let pristineManifest = CyderPaths.support
            .appendingPathComponent("templates/pristine/manifest.json").path
        let goldenManifest = CyderPaths.support
            .appendingPathComponent("templates/golden/manifest.json").path
        let needsBootstrap = !FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path)
            || !FileManager.default.fileExists(atPath: pristineManifest)
            || !FileManager.default.fileExists(atPath: goldenManifest)
        return (needsEngine, needsBootstrap)
    }

    private func ensureEnvironment(context: CyderLaunchContext) -> CyderFailure? {
        let state = environmentState(context: context)

        if state.needsEngine {
            CyderDiagnostics.shared.enter(.engineExtraction)
            showSetup("正在準備遊戲執行元件…")
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
        let bootstrapNeeded = state.needsEngine
            || state.needsBootstrap
            || environmentState(context: context).needsBootstrap
            || !templatesReady && !state.needsEngine
        if bootstrapNeeded {
            CyderDiagnostics.shared.enter(.bootstrap)
            showSetup("正在準備遊戲環境…")
            let result = runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only"],
                stage: .bootstrap,
                operation: "bootstrap"
            )
            if !result.succeeded {
                return failure(
                    code: "CYD-BTS-001",
                    stage: .bootstrap,
                    summary: "準備遊戲環境時發生問題。",
                    result: result
                )
            }
        }
        // A marker only proves that bootstrap completed once.  Probe the
        // current prefix on every app launch so a damaged/incomplete Wine
        // environment cannot reach the game menu silently.
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
        return nil
    }

    private func prepareEnvironmentAndShowSettings() {
        guard let resourcePath = Bundle.main.resourcePath else {
            showSettings()
            return
        }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        showSetup("正在準備遊戲環境…")
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
        let exeURL = URL(fileURLWithPath: exePaths[0])
        let profileStore = CyderProfileStore(root: CyderPaths.support)
        var profileID: String?
        var prefix = CyderPaths.sharedBottle
        switch profileStore.resolve(executable: exeURL) {
        case .uncreated(let id):
            // The stable executable ID is also the key for settings when the
            // game uses the shared bottle. A profile bottle is optional.
            profileID = id
        case .damaged(let id, let reason):
            return .failure(CyderFailure(
                code: "CYD-PRO-002",
                stage: .exeValidation,
                summary: "這個遊戲的設定環境已損毀。",
                technicalDetails: "Profile \(id): \(reason)",
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        case .ready(let record):
            profileID = record.profileId
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
        let gameSettings = pendingGameSettings
            ?? profileID.flatMap { CyderSettingsStore.shared.value.perProfile[$0] }
        if let profileID, let gameSettings {
            showSetup("正在套用遊戲設定…")
            var launchSettings = CyderSettingsStore.shared.environment(
                profileID: profileID,
                legacyBasename: nil,
                override: gameSettings
            )
            launchSettings["WINEPREFIX"] = prefix.path
            let applied = runLauncher(
                context: context,
                args: [context.launcher, "--apply-settings-prefix", prefix.path],
                stage: .settingsApply,
                operation: "apply-game-settings",
                extraEnvironment: launchSettings
            )
            guard applied.succeeded else {
                return .failure(failure(
                    code: "CYD-GAM-002",
                    stage: .settingsApply,
                    summary: "套用遊戲個別設定時發生問題。",
                    result: applied
                ))
            }
        }
        return runDirectWine(
            context: context,
            wine: wine,
            exe: exeURL.path,
            profileID: profileID,
            prefix: prefix,
            gameSettings: gameSettings
        )
    }

    /// Launch Wine directly through Apple's architecture selector, then wait
    /// for CrossOver Wine to publish the actual foreground application PID in
    /// WineAppWillActivateNotification.  The wrapper Process PID is not used
    /// for activation. Wine continues independently after Cyder exits.
    private func runDirectWine(
        context: CyderLaunchContext,
        wine: URL,
        exe: String,
        profileID: String?,
        prefix: URL,
        gameSettings: CyderExecutableSettings?
    ) -> CyderLaunchOutcome {
        let support = CyderPaths.support
        let logDirectory = support.appendingPathComponent("Logs", isDirectory: true)
        let prefixPath = prefix.path
        let activationWaiter = WineActivationWaiter(prefix: prefixPath)
        onMainThread {
            wineActivationWaiter = activationWaiter
        }
        defer {
            onMainThread {
                if wineActivationWaiter === activationWaiter {
                    wineActivationWaiter = nil
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(CyderFailure(
                code: "CYD-LOG-001",
                stage: .wineSpawn,
                summary: "無法建立 Cyder 記錄資料夾。",
                technicalDetails: String(describing: error),
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        }

        CyderDiagnostics.shared.enter(.wineSpawn, detail: CyderDiagnostics.shared.redact(exe))
        let launchLog = CyderDiagnostics.shared.makeOperationLog("wine-launch")
        FileManager.default.createFile(atPath: launchLog.path, contents: nil)
        let legacyLog = logDirectory.appendingPathComponent("last-launch.log")
        try? FileManager.default.removeItem(at: legacyLog)
        try? FileManager.default.createSymbolicLink(at: legacyLog, withDestinationURL: launchLog)

        let process = Process()
        let environment = wineEnvironment(
            wine: wine,
            support: support,
            exe: exe,
            profileID: profileID,
            prefix: prefix,
            gameSettings: gameSettings
        )
        let gameArguments = CyderSettingsStore.shared.arguments(
            profileID: profileID,
            legacyBasename: nil,
            override: gameSettings
        )
        let powerMode = environment["CYDER_POWER_MODE"] ?? "normal"
        let taskpolicy = findExecutable(named: "taskpolicy", environment: environment)
        let hasTaskpolicy = taskpolicy != nil
        var commandDescription: String
        if powerMode == "background" {
            guard let taskpolicy else {
                return .failure(CyderFailure(
                    code: "CYD-PWR-001",
                    stage: .wineSpawn,
                    summary: "無法使用省電模式啟動遊戲。",
                    technicalDetails: "taskpolicy was not found in PATH. Select Standard energy mode and try again.",
                    logURL: launchLog
                ))
            }
            process.executableURL = taskpolicy
            process.arguments = ["-c", "background", "/usr/bin/arch", "-x86_64", wine.path, exe] + gameArguments
            commandDescription = "\(taskpolicy.path) \(process.arguments?.joined(separator: " ") ?? "")"
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            process.arguments = ["-x86_64", wine.path, exe] + gameArguments
            commandDescription = "arch -x86_64 \(wine.path) \(exe) \(gameArguments.joined(separator: " "))"
        }
        process.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        process.environment = environment

        guard let handle = FileHandle(forWritingAtPath: launchLog.path) else {
            return .failure(CyderFailure(
                code: "CYD-LOG-002",
                stage: .wineSpawn,
                summary: "無法建立 Wine 啟動記錄。",
                technicalDetails: "Unable to open \(launchLog.path) for writing.",
                logURL: CyderDiagnostics.shared.sessionLogURL
            ))
        }
        let command = CyderDiagnostics.shared.redact(
            "cmd=\(commandDescription)\nprofile_id=\(profileID ?? "shared")\npower_mode=\(powerMode)\ntaskpolicy_available=\(hasTaskpolicy)\nWINEPREFIX=\(prefixPath)\ncwd=\((exe as NSString).deletingLastPathComponent)\n\n"
        )
        try? handle.write(contentsOf: Data(command.utf8))
        process.standardOutput = handle
        process.standardError = handle

        let msync = environment["CYDER_MSYNC"] == "1" ? "1" : "0"
        let esync = environment["CYDER_ESYNC"] == "1" ? "1" : "0"
        CyderDiagnostics.shared.info(
            "game-launch effective-settings profile=\(profileID ?? "shared") "
                + "source=\(gameSettings == nil ? "saved" : "test-or-override") "
                + "msync=\(msync) esync=\(esync) power=\(powerMode)"
        )

        do {
            try process.run()
            CyderDiagnostics.shared.info("wine process started pid=\(process.processIdentifier) log=\(launchLog.path)")
        } catch {
            try? handle.close()
            return .failure(CyderFailure(
                code: "CYD-WIN-001",
                stage: .wineSpawn,
                summary: "無法啟動 Wine。",
                technicalDetails: String(describing: error),
                logURL: launchLog
            ))
        }

        // Race Wine activation against an early process exit.  A living Wine
        // process without an activation notification is only a warning because
        // some console-style EXEs intentionally create no regular Cocoa window.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if activationWaiter.semaphore.wait(timeout: .now() + 0.2) == .success {
                CyderDiagnostics.shared.enter(.wineActivation, detail: "notification-received")
                try? handle.close()
                return .success
            }
            if !process.isRunning {
                process.waitUntilExit()
                try? handle.close()
                let reason: String
                let code: String
                if process.terminationReason == .uncaughtSignal {
                    reason = "uncaught-signal \(process.terminationStatus)"
                    code = "CYD-WIN-003"
                } else {
                    reason = "exit \(process.terminationStatus)"
                    code = "CYD-WIN-002"
                }
                let tail = CyderDiagnostics.shared.tail(of: launchLog)
                return .failure(CyderFailure(
                    code: code,
                    stage: .wineSpawn,
                    summary: process.terminationReason == .uncaughtSignal
                        ? "Wine 因系統 signal 異常終止。"
                        : "Wine 啟動後在顯示遊戲視窗前結束。",
                    technicalDetails: tail.isEmpty ? "Wine terminated: \(reason)" : tail,
                    exitCode: process.terminationStatus,
                    terminationReason: reason,
                    logURL: launchLog
                ))
            }
        }
        try? handle.close()
        CyderDiagnostics.shared.warning("wine activation timed out after 30s pid=\(process.processIdentifier); process remains running")
        return .success
    }

    private func wineEnvironment(
        wine: URL,
        support: URL,
        exe: String,
        profileID: String?,
        prefix: URL,
        gameSettings: CyderExecutableSettings?
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in CyderSettingsStore.shared.environment(
            profileID: profileID,
            legacyBasename: nil,
            override: gameSettings
        ) {
            environment[key] = value
        }

        let engineRoot = wine.deletingLastPathComponent().deletingLastPathComponent()
        environment["WINEPREFIX"] = prefix.path
        environment["WINESERVER"] = engineRoot.appendingPathComponent("bin/wineserver").path
        environment["PATH"] = engineRoot.appendingPathComponent("bin").path
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")

        if environment["CYDER_MSYNC"] == "1" {
            environment["WINEMSYNC"] = "1"
            environment.removeValue(forKey: "WINEESYNC")
        } else if environment["CYDER_ESYNC"] == "1" {
            environment["WINEESYNC"] = "1"
            environment.removeValue(forKey: "WINEMSYNC")
        } else {
            environment.removeValue(forKey: "WINEMSYNC")
            environment.removeValue(forKey: "WINEESYNC")
        }

        let locale = resolvedWineLocale(environment: environment)
        environment["LANG"] = locale
        environment["LC_ALL"] = locale
        return environment
    }

    @objc private func wineAppWillActivate(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        let pid = (userInfo["ActivatingAppPID"] as? NSNumber)?.int32Value ?? 0
        let prefix = userInfo["ActivatingAppPrefix"] as? String ?? ""

        let handle = { [weak self] in
            guard let self,
                  let waiter = self.wineActivationWaiter,
                  pid > 0,
                  !prefix.isEmpty,
                  (prefix as NSString).standardizingPath == waiter.prefix,
                  let application = NSRunningApplication(processIdentifier: pid),
                  application.activationPolicy == .regular
            else {
                return
            }

            // The notification comes from the Wine Cocoa process that is
            // ready to become foreground. Cooperatively hand activation to it
            // on macOS 14+, without PID searches or activation polling.
            self.wineActivationWaiter = nil
            if #available(macOS 14.0, *) {
                let source = NSRunningApplication.current
                NSApp.yieldActivation(to: application)
                _ = application.activate(from: source, options: [.activateAllWindows])
            } else {
                _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            waiter.semaphore.signal()
        }
        if Thread.isMainThread {
            handle()
        } else {
            DispatchQueue.main.async(execute: handle)
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
        return installed != bundled
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
            alert.addButton(withTitle: "開啟記錄資料夾")
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
        FileManager.default.createFile(atPath: operationLog.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: operationLog.path) else {
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: "Unable to create operation log at \(operationLog.path)"
            )
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
        do {
            try process.run()
            process.waitUntilExit()
            try? handle.close()
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
            try? handle.close()
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
}

@main
struct CyderMain {
    static func main() {
        _ = CyderDiagnostics.shared
        let app = NSApplication.shared
        let delegate = CyderAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
