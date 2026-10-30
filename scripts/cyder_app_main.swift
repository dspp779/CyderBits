// Cyder.app entry — phased setup UI, then launch Windows EXE directly with Wine.
import Carbon.HIToolbox
import Cocoa
import Darwin
import Foundation
import UniformTypeIdentifiers

private enum CyderLaunchOutcome {
    case success
    case cancelled
    case unconfirmed
    case environmentNotReady
    case graphicsNotReady
    case failure(CyderFailure)
    var requestFailed: Bool {
        switch self { case .failure, .environmentNotReady, .graphicsNotReady: return true; default: return false }
    }
    var isUnconfirmed: Bool { if case .unconfirmed = self { return true }; return false }

}

private enum CyderPrefixResolution {
    case success(URL)
    case failure(CyderFailure)
}

private enum CyderFailureAction: Equatable {
    case close
    case rebuild
}

private enum CyderLaunchIntent: Equatable {
    case undetermined
    case appOnly
    case documentLaunchExpected
    case urlLaunchExpected
    case cliLaunch
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var componentDiagnosticsController: CyderComponentDiagnosticsController?
    private let operationGate = CyderOperationGate()
    private let launchPreparation = CyderLaunchPreparation<CyderOperationGate.Scope?>()
    private var diagnosticsOperationInProgress = false
    private var diagnosticsPresentation: UUID?
    private var requestRecords: [CyderRequestJournal.Record] = []
    private var outboxNotices: [CyderOutboxNotice] = []
    private weak var existingSettingsController: CyderSettingsWindowController?
    private weak var existingLibraryController: CyderGameLibraryWindowController?
    private weak var existingRequestController: CyderRequestWindowController?
    private var cancelledRequestIDs = Set<String>()
    private var pendingRequestAcquisitions: [String: UUID] = [:]
    private var pendingPreparation: [String: UUID] = [:]
    private let processRunner = CyderProcessRunner(delivery: DispatchQueue(label: "local.cyder.process-delivery", qos: .utility))
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
        var authorization: CyderRequestJournal.Record? = nil
        var lease: CyderOperationGate.Lease? = nil
    }

    private var queuedLaunches: [QueuedLaunch] = [] {
        didSet { statusItemController.setIngressPending(libraryLaunchInProgress || !queuedLaunches.isEmpty || activeProcessOperations > 0 || !pendingLaunchAcquisitions.isEmpty) }
    }
    private var didFinishLaunch = false
    private var libraryLaunchInProgress = false {
        didSet { statusItemController.setIngressPending(libraryLaunchInProgress || !queuedLaunches.isEmpty || activeProcessOperations > 0 || !pendingLaunchAcquisitions.isEmpty) }
    }
    private var activeProcessOperations = 0 {
        didSet { statusItemController.setIngressPending(libraryLaunchInProgress || !queuedLaunches.isEmpty || activeProcessOperations > 0 || !pendingLaunchAcquisitions.isEmpty) }
    }
    private var pendingLaunchAcquisitions = Set<String>() {
        didSet { statusItemController.setIngressPending(libraryLaunchInProgress || !queuedLaunches.isEmpty || activeProcessOperations > 0 || !pendingLaunchAcquisitions.isEmpty) }
    }
    private var documentLaunchRequested = false
    private var setupPanel: CyderSetupPanel?
    private let setupProgress = CyderSetupProgress()
    private var terminateWhenSettingsClose = false
    private var openingGameLibrary = false
    private var openingGamesDirectory = false
    private var gamesDirectoryPresentation: UUID?
    private var environmentPreparationInProgress = false
    private var wineActivationWaiter: WineActivationWaiter?
    private var wineLaunchObserver: CyderLaunchObserver?
    private var readOnlyMode = false
    private var readOnlyReason = CyderUnavailableWindowController.Reason.ownershipUnavailable
    private weak var existingUnavailableController: CyderUnavailableWindowController?
    private lazy var unavailableController: CyderUnavailableWindowController = {
        let controller = CyderUnavailableWindowController()
        existingUnavailableController = controller
        controller.onLibrary = { [weak self] in self?.showGameLibrary() }
        controller.onDiagnostics = { NSWorkspace.shared.open(CyderPaths.support.appendingPathComponent("Logs")) }
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onClose = { [weak self] in
            if self?.existingLibraryController?.window?.isVisible != true { NSApp.terminate(nil) }
        }
        return controller
    }()
    private var isPrimaryInstance = false
    private var instanceReady = false
    private var delayedLaunchNotification: Notification?
    private var quitTransaction = false
    private var pendingOpenReplies = 0
    private var requestRemaining: [String: Int] = [:]
    private var secondaryForwardScheduled = false
    private var secondaryRequestSent = false
    private var launchIntent: CyderLaunchIntent = .undetermined
    private var deferredInstanceRequests: [CyderInstanceRequest] = []
    private lazy var instanceCoordinator: CyderInstanceCoordinator = {
        let coordinator = CyderInstanceCoordinator(normalizeSettings: CyderSettingsStore.acceptedSnapshot)
        coordinator.onRecoveryChanged = { [weak self] records in
            guard let self, !self.quitTransaction else { return }
            self.requestRecords = records
            let history = records.compactMap { CyderRecoveryObserver.Record($0) }
            for record in history { if let proof = record.root { self.wineLaunchObserver?.receive(proof) } }
            self.statusItemController.receiveHistory(history)
            self.existingLibraryController?.updateRequestSummary(CyderRequestRow.summary(records, outbox: self.outboxNotices))
            self.existingRequestController?.update(records, outbox: self.outboxNotices)
        }
        coordinator.onOutboxChanged = { [weak self] notices in
            guard let self, !self.quitTransaction else { return }
            self.outboxNotices = notices
            self.existingLibraryController?.updateRequestSummary(CyderRequestRow.summary(self.requestRecords, outbox: notices))
            self.existingRequestController?.update(self.requestRecords, outbox: notices)
        }
        coordinator.onRequestCancelled = { [weak self] id in self?.cancelQueuedRequest(id) }
        return coordinator
    }()
    private lazy var requestController: CyderRequestWindowController = {
        let controller = CyderRequestWindowController()
        existingRequestController = controller
        controller.onResume = { [weak self] id, done in self?.instanceCoordinator.resumeRequest(id: id, completion: done) }
        controller.onCancel = { [weak self] id, done in self?.instanceCoordinator.cancelRequest(id: id, completion: done) }
        controller.onResend = { [weak self] id, done in self?.instanceCoordinator.recoverOutbox(id: id, cancel: false, completion: done) }
        controller.onWithdraw = { [weak self] id, done in self?.instanceCoordinator.recoverOutbox(id: id, cancel: true, completion: done) }
        controller.onRefresh = { [weak self] in self?.instanceCoordinator.refreshRequests() }
        controller.onOpenDiagnostics = { NSWorkspace.shared.open(CyderPaths.support.appendingPathComponent("Logs")) }
        controller.onClose = { [weak self] in
            guard let self, self.existingSettingsController?.window?.isVisible != true,
                  self.existingLibraryController?.window?.isVisible != true else { return }
            self.statusItemController.setUIVisible(false)
        }
        return controller
    }()
    private lazy var bottleRecovery = CyderBottleRecovery(support: CyderPaths.support,
        engine: CyderPaths.engine.appendingPathComponent("bin/wineserver")) { [weak self] identity, owner, observedAt in
            self?.environmentMonitor.recoverVerified(identity, owner: owner, observedAt: observedAt)
        }
    private lazy var environmentMonitor: CyderEnvironmentMonitor = CyderEnvironmentMonitor(
        epoch: statusItemController.lifecycleEpoch, directory: CyderPaths.support,
        expectedEngine: CyderPaths.engine.appendingPathComponent("bin/wineserver"),
        event: { [weak self] event in self?.statusItemController.receiveLifecycleEvent(event) }
    )
    private lazy var statusItemController: CyderStatusItemController = {
        let controller = CyderStatusItemController()
        controller.onWindowConfirmed = { [weak self] launchID in
            guard let self, !self.quitTransaction, let waiter = self.wineActivationWaiter,
                  waiter.launchID == launchID else { return }
            waiter.signal()
        }
        controller.onOpenPreferences = { [weak self] in self?.showSettings() }
        controller.onOpenGameLibrary = { [weak self] in self?.showGameLibrary() }
        controller.onOpenTaskManager = { [weak self] prefix in
            self?.runPrefixAction("--taskmgr-prefix", prefix: prefix, operation: "task-manager")
        }
        controller.onStopPrefixes = { [weak self] prefixes in
            self?.requestStopEnvironment(prefixes: prefixes)
        }
        controller.onManageEnvironment = { [weak self] prefix, completion in
            guard let self else { completion(nil); return }
            self.environmentMonitor.track(prefix: prefix, engine: CyderPaths.engine.appendingPathComponent("bin/wineserver"), completion: completion)
        }
        controller.onRecheckEnvironments = { [weak self] in
            guard let self, self.isPrimaryInstance, !self.quitTransaction else { return }
            self.environmentMonitor.recheck()
            self.bottleRecovery.refresh()
        }
        controller.onReconcileEnvironment = { [weak self] stamp in self?.environmentMonitor.reconcile(stamp) }
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onExecuteStop = { [weak self] prefix, stamp, operation in
            self?.runStopEnvironment(prefix: prefix, stamp: stamp, operation: operation)
        }
        controller.onLifecycleIdle = { [weak self] in
            guard let self, self.isPrimaryInstance, !self.readOnlyMode, self.didFinishLaunch, self.instanceReady,
                  !self.openingGameLibrary, !self.libraryLaunchInProgress, self.queuedLaunches.isEmpty, self.activeProcessOperations == 0, self.pendingLaunchAcquisitions.isEmpty,
                  !self.environmentPreparationInProgress,
                  self.existingSettingsController?.window?.isVisible != true,
                  self.existingRequestController?.window?.isVisible != true,
                  self.existingUnavailableController?.window?.isVisible != true,
                  self.existingLibraryController?.window?.isVisible != true else { return }
            NSApp.terminate(nil)
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
        controller.maintenanceGate = operationGate
        existingSettingsController = controller
        controller.onImmediateSave = { [weak self] registrySetting in
            await self?.applySettingsImmediately(registrySetting: registrySetting) ?? false
        }
        controller.onApplyWhileRunning = { [weak self] draftEnvironment in
            await self?.applySettingsWhileRunning(draftEnvironment: draftEnvironment) ?? false
        }
        controller.onSaveStarted = { [weak self] in
            self?.environmentPreparationInProgress = true
            self?.showSetup("正在儲存設定…")
        }
        controller.onSaveFailed = { [weak self] in
            self?.hideSetup()
            self?.environmentPreparationInProgress = false
        }
        controller.hasRunningExes = { [weak self] in await self?.hasRunningExes() ?? true }
        controller.onStopAllWine = { [weak self] in
            await self?.stopAllExesWaiting() ?? false
        }
        controller.onRebuild = { [weak self] in self?.rebuildEnvironment() }
        controller.onCreateProfile = { [weak self] executable in
            self?.createIndependentProfile(for: executable)
        }
        controller.onOpenWinetricks = { [weak self] verbs in
            self?.installWinetricks(verbs)
        }
        controller.onExportLastGameLog = { [weak self] in
            self?.exportLastGameLog()
        }
        controller.onInspectComponents = { [weak self] in self?.showComponentDiagnostics() }
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
            guard let self else { return }
            if self.diagnosticsPresentation != nil {
                self.diagnosticsPresentation = nil
                self.environmentPreparationInProgress = false
                self.hideSetup()
            }
            guard !self.environmentPreparationInProgress,
                  !self.openingGameLibrary,
                  self.existingRequestController?.window?.isVisible != true,
                  self.existingLibraryController?.window?.isVisible != true else { return }
            self.statusItemController.setUIVisible(false)
            NSApp.setActivationPolicy(.accessory)
            // The lifecycle snapshot settles after pending entry events; closing
            // a Cyder window cannot infer that an external environment ended.
        }
        return controller
    }()

    private lazy var gameLibraryController: CyderGameLibraryWindowController = {
        let controller = CyderGameLibraryWindowController(readOnly: readOnlyMode)
        existingLibraryController = controller
        controller.onOpenRequests = { [weak self] in self?.showRequests() }
        controller.onPrepareEnvironment = { [weak self] in self?.prepareEnvironmentFromLibrary() }
        controller.updateRequestSummary(CyderRequestRow.summary(requestRecords, outbox: outboxNotices))
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
            if self?.readOnlyMode == true {
                if self?.existingUnavailableController?.window?.isVisible != true { NSApp.terminate(nil) }
                return
            }
            guard let self,
                  !self.environmentPreparationInProgress,
                  self.existingSettingsController?.window?.isVisible != true,
                  self.existingRequestController?.window?.isVisible != true,
                  !self.gameLibraryController.isGameSettingsVisible else { return }
            self.statusItemController.setUIVisible(false)
            NSApp.setActivationPolicy(.accessory)
            // The lifecycle snapshot settles after pending entry events; closing
            // a Cyder window cannot infer that an external environment ended.
        }
        return controller
    }()

    private func createIndependentProfile(for executable: URL, returnToLibrary: Bool = false) {
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("無法建立獨立環境", "Cyder 缺少必要的 Resources 目錄。")
            return
        }
        environmentPreparationInProgress = true
        settingsController.close()
        gameLibraryController.close()
        let progressPresentation = showSetup("正在建立獨立遊戲環境…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let result = await self.runLauncher(
                context: context,
                args: [context.launcher, "--profile-create", executable.path, "golden"],
                stage: .bootstrap,
                operation: "profile-create",
                progressPresentation: progressPresentation
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
        showSetup("正在移除獨立遊戲環境…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let result = await self.runLauncher(
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
                var replied = false
                CyderSettingsAccess.shared.perform({ store in
                    let profileID = try CyderProfileStore(root: CyderPaths.support).profileID(for: executable)
                    try store.update { $0.perProfile.removeValue(forKey: profileID) }
                }) { update in
                    guard !replied else { return }
                    replied = true
                    switch update {
                    case .ready: completion(true)
                    default:
                        completion(false)
                        guard !self.quitTransaction else { return }
                        self.showAlert("設定尚未確認", "prefix 已移除，但設定檔更新尚未確認；請稍後重新開啟選項檢查。")
                    }
                }
            }
        }
    }

    private func rebuildEnvironment(completion: (() -> Void)? = nil) {
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("無法重建環境", "Cyder 缺少必要的 Resources 目錄。")
            return
        }
        environmentPreparationInProgress = true
        let progressPresentation = showSetup("正在重建 Windows 遊戲環境…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let result = await self.runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--rebuild-prefix"],
                stage: .bootstrap,
                operation: "rebuild-prefix",
                progressPresentation: progressPresentation
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
        // launch hidden until the post-launch mode decision. Game library and
        // Preferences promote to the Dock via activateCyderUI; EXE/URI launches
        // stay accessory unless they need a question or error.
        NSApp.setActivationPolicy(.accessory)
        statusItemController.beginRecovery()
        instanceCoordinator.start(onRequest: { [weak self] request in
            self?.receiveInstanceRequest(request)
        }) { [weak self] role in
            guard let self else { return }
            self.instanceReady = true
            switch role {
            case .primary:
                self.isPrimaryInstance = true
                self.environmentMonitor.restore { [weak self] in
                    guard let self, !self.quitTransaction else { return }
                    self.bottleRecovery.refresh { [weak self] in
                        self?.environmentMonitor.finishRecovery { [weak self] in
                            guard let self, !self.quitTransaction else { return }
                            self.statusItemController.receiveLifecycleEvent(.restoring(false))
                        }
                    }
                }
                self.instanceCoordinator.sentinel.onLaunchEnded = { [weak self] id in
                    self?.statusItemController.noteHelperDisconnected(id: id)
                }
            case .secondary:
                self.isPrimaryInstance = false
                self.statusItemController.receiveLifecycleEvent(.restoring(false))
            case .unavailable:
                self.statusItemController.receiveLifecycleEvent(.restoring(false))
                // No ownership means no executor. Keep UI available for the
                // actionable error; never continue as an uncoordinated primary.
                self.isPrimaryInstance = false
                self.enterReadOnly(.ownershipUnavailable)
                return
            }
            if let notification = self.delayedLaunchNotification {
                self.delayedLaunchNotification = nil
                self.applicationDidFinishLaunching(notification)
            }
        }
    }

    @available(macOS 11.0, *)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !readOnlyMode else { showReadOnlyStatus(); return }
        let fileExecutables = urls.filter(\.isFileURL).flatMap {
            normalizeExePaths([$0.path])
        }
        let uriStrings = CyderURIHandlerManager.shared.filterHandledURLs(urls)
        if !uriStrings.isEmpty {
            launchIntent = .urlLaunchExpected
        } else if !fileExecutables.isEmpty && launchIntent != .cliLaunch {
            launchIntent = .documentLaunchExpected
        }
        CyderDiagnostics.shared.info(
            "open-urls received=\(urls.count) gamaniagames=\(uriStrings.count) file-doc=\(fileExecutables.count)"
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
        if existingSettingsController?.window?.isVisible == true {
            settingsController.close()
        }
        enqueueOrLaunchURIs(uriStrings)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard !readOnlyMode else { application.reply(toOpenOrPrint: .failure); showReadOnlyStatus(); return }
        let executableFiles = normalizeExePaths(filenames)
        if !executableFiles.isEmpty && launchIntent != .cliLaunch {
            launchIntent = .documentLaunchExpected
        }
        CyderDiagnostics.shared.info(
            "open-files received=\(filenames.count) executable=\(executableFiles.count) bundle=\(Bundle.main.bundlePath)"
        )
        if executableFiles.isEmpty, !filenames.isEmpty {
            // LaunchServices may report trailing login arguments as document
            // candidates. Do not persist their contents in diagnostic logs.
            CyderDiagnostics.shared.info("open-files rejected non-executable count=\(filenames.count)")
        }
        guard !executableFiles.isEmpty else { application.reply(toOpenOrPrint: .failure); return }
        if !instanceReady || !isPrimaryInstance {
            pendingOpenReplies += 1
            _ = deliverExecutableFiles(executableFiles)
            return
        }
        presentExternalLaunchStarting()
        instanceCoordinator.submit(.init(files: executableFiles, arguments: pendingLaunchArguments, urls: [], showUI: false)) { [weak self] accepted in
            application.reply(toOpenOrPrint: accepted ? .success : .failure)
            if !accepted { self?.presentLaunchAcceptanceFailure() }
        }
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
        if !didFinishLaunch {
            pendingFiles.append(contentsOf: executableFiles)
            return true
        }
        presentExternalLaunchStarting()
        enqueueOrLaunch(executableFiles)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !readOnlyMode else { return }
        guard instanceReady else { delayedLaunchNotification = notification; return }
        if !isPrimaryInstance {
            captureInvocationArguments()
            determineInitialLaunchIntent()
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
        determineInitialLaunchIntent()
        // A test launch creates a second Cyder process while the library app
        // remains alive. Its session-state file is therefore expected to be
        // "running", not evidence of a crash. Only settings-mode launches
        // should surface a previous-session warning.
        if launchIntent == .appOnly && !documentLaunchRequested {
            showPreviousCrashIfNeeded()
        }
        CyderDiagnostics.shared.enter(
            .appStart,
            detail: launchModeDetail()
        )
        CyderDiagnostics.shared.info(
            "launch-context args=\(CommandLine.arguments.count - 1) pending=\(pendingFiles.count) intent=\(String(describing: launchIntent)) bundle=\(Bundle.main.bundlePath)"
        )
        if #available(macOS 11.0, *), !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs.removeAll()
            documentLaunchRequested = true
            enqueueOrLaunchURIs(urls)
        }
        if launchIntent == .appOnly {
            finalizePostLaunchModeDecision()
        } else {
            // launch Apple Event already says this is a document / URL launch.
            // One main-queue turn lets AppKit finish delivering openFiles/open
            // callbacks if they were queued just behind didFinishLaunching.
            DispatchQueue.main.async { [weak self] in
                self?.finalizePostLaunchModeDecision()
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
            launchIntent = .cliLaunch
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

    private func detectLaunchIntentFromAppleEvent() -> CyderLaunchIntent {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return .undetermined
        }
        let eventClass = event.eventClass
        let eventID = event.eventID
        if eventClass == kInternetEventClass && eventID == AEEventID(kAEGetURL) {
            return .urlLaunchExpected
        }
        if eventClass == kCoreEventClass {
            switch eventID {
            case AEEventID(kAEOpenApplication), AEEventID(kAEReopenApplication):
                return .appOnly
            case AEEventID(kAEOpenDocuments):
                return .documentLaunchExpected
            default:
                break
            }
        }
        return .undetermined
    }

    private func refreshLaunchIntentFromState() {
        if !pendingURLs.isEmpty || queuedLaunches.contains(where: \.isURI) {
            launchIntent = .urlLaunchExpected
            return
        }
        if !pendingFiles.isEmpty || documentLaunchRequested {
            if launchIntent != .cliLaunch {
                launchIntent = .documentLaunchExpected
            }
            return
        }
        if pendingLaunchArguments != nil && launchIntent == .undetermined {
            launchIntent = .documentLaunchExpected
        }
    }

    private func determineInitialLaunchIntent() {
        let appleEventIntent = detectLaunchIntentFromAppleEvent()
        launchIntent = appleEventIntent
        if !pendingFiles.isEmpty {
            launchIntent = .cliLaunch
        } else if launchIntent == .undetermined, pendingLaunchArguments != nil {
            // `open ... --args` and direct invocation carry payload in argv
            // before AppKit has a document event to deliver.
            launchIntent = .documentLaunchExpected
        } else if launchIntent == .undetermined && pendingURLs.isEmpty {
            launchIntent = .appOnly
        }
        refreshLaunchIntentFromState()
    }

    private func finalizePostLaunchModeDecision() {
        refreshLaunchIntentFromState()
        if documentLaunchRequested || !pendingFiles.isEmpty {
            // URI children are already queued; persist any remaining document batch.
            if !pendingFiles.isEmpty {
                let files = pendingFiles
                pendingFiles.removeAll()
                presentExternalLaunchStarting()
                instanceCoordinator.submit(.init(files: files, arguments: pendingLaunchArguments, urls: [], showUI: false)) { [weak self] accepted in
                    guard let self else { return }
                    while self.pendingOpenReplies > 0 {
                        NSApp.reply(toOpenOrPrint: accepted ? .success : .failure)
                        self.pendingOpenReplies -= 1
                    }
                    if !accepted { self.presentLaunchAcceptanceFailure() }
                }
            }
            return
        }
        terminateWhenSettingsClose = true
        // Browsing the library never waits for or starts Wine preparation.
        showGameLibrary()
    }

    private func scheduleSecondaryForward() {
        guard instanceReady, !readOnlyMode, !isPrimaryInstance, !secondaryForwardScheduled else { return }
        secondaryForwardScheduled = true
        // Keep the secondary alive for one main-queue turn so argv and any
        // queued openFiles/open-URL callbacks are forwarded as a single request.
        DispatchQueue.main.async { [weak self] in
            self?.forwardSecondaryInstance()
        }
    }

    private func forwardSecondaryInstance() {
        guard !secondaryRequestSent else { return }
        secondaryRequestSent = true
        refreshLaunchIntentFromState()
        let files = normalizeExePaths(pendingFiles)
        let urls = pendingURLs
        let arguments = pendingLaunchArguments
        let showUI = launchIntent == .appOnly && files.isEmpty && arguments == nil && urls.isEmpty
        instanceCoordinator.forward(files: files, arguments: arguments, urls: urls, showUI: showUI) { [weak self] accepted in
            guard let self else { return }
            while self.pendingOpenReplies > 0 {
                NSApp.reply(toOpenOrPrint: accepted ? .success : .failure)
                self.pendingOpenReplies -= 1
            }
            guard !self.quitTransaction else { return }
            if accepted { NSApp.terminate(nil) }
            else { self.enterReadOnly(.forwardUnconfirmed) }
        }
    }

    private func enterReadOnly(_ reason: CyderUnavailableWindowController.Reason) {
        guard !quitTransaction else { return }
        readOnlyMode = true; readOnlyReason = reason
        delayedLaunchNotification = nil; didFinishLaunch = true
        while pendingOpenReplies > 0 { NSApp.reply(toOpenOrPrint: .failure); pendingOpenReplies -= 1 }
        installMainMenu()
        showReadOnlyStatus()
    }

    private func showReadOnlyStatus() {
        guard !quitTransaction else { return }
        unavailableController.update(readOnlyReason)
        activateCyderUI(dockVisible: true)
        unavailableController.showWindow(nil)
        unavailableController.window?.makeKeyAndOrderFront(nil)
    }

    private func receiveInstanceRequest(_ request: CyderInstanceRequest) {
        guard isPrimaryInstance else { return }
        guard didFinishLaunch else {
            deferredInstanceRequests.append(request)
            return
        }
        guard !quitTransaction else { return }
        let files = normalizeExePaths(request.files)
        requestRemaining[request.record.id] = files.count + request.urls.count
        if !files.isEmpty { enqueueOrLaunch(files, arguments: request.arguments, authorization: request.record) }
        if #available(macOS 11.0, *), !request.urls.isEmpty {
            enqueueOrLaunchURIs(request.urls, authorization: request.record)
        }
        if request.showUI { presentResidentCyderUI() }
        if files.isEmpty && request.urls.isEmpty {
            let presentedUI = request.showUI
            instanceCoordinator.authorize(request.record) { [weak self] record in
                if let record { self?.instanceCoordinator.finish(record,
                    outcome: presentedUI ? "ui-presented" : "invalid-document", failed: !presentedUI) }
            }
        }
    }

    private func finishRequestPart(_ record: CyderRequestJournal.Record?, failed: Bool = false, uncertain: Bool = false) {
        guard let record else { return }
        let remaining = max(0, (requestRemaining[record.id] ?? 1) - 1)
        requestRemaining[record.id] = remaining
        if remaining == 0 {
            requestRemaining.removeValue(forKey: record.id)
            instanceCoordinator.finish(record, outcome: uncertain ? "unconfirmed" : (failed ? "failed" : "observation-finished"), failed: failed, uncertain: uncertain)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if readOnlyMode { showReadOnlyStatus(); return false }
        // LSUIElement + accessory: Finder / Launchpad clicks reuse this process
        // and send reopen. AppKit's default does nothing when no Cyder window is
        // visible (the common case after closing the library while a game runs).
        guard isPrimaryInstance, didFinishLaunch else { return false }
        CyderDiagnostics.shared.info("reopen requested hasVisibleWindows=\(flag)")
        presentResidentCyderUI()
        return false
    }

    /// Bring the game library forward. Shared by Finder reopen and a secondary
    /// process that forwarded an empty `showUI` request.
    private func presentResidentCyderUI() {
        terminateWhenSettingsClose = true
        showGameLibrary()
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinator.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        CyderDiagnostics.shared.finish(outcome: "terminated")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitTransaction else { return .terminateLater }
        quitTransaction = true
        diagnosticsPresentation = nil
        setupProgress.invalidate()
        componentDiagnosticsController?.close()
        existingLibraryController?.quiesce()
        CyderGameIconStore.shared.quiesce()
        if isPrimaryInstance {
            statusItemController.quiesce()
            bottleRecovery.stop()
            environmentMonitor.stop()
            processRunner.quiesce()
            operationGate.quiesce()
            launchPreparation.quiesce()
            CyderSettingsAccess.shared.quiesce()
            wineLaunchObserver?.cancel()
        }
        CyderDiagnostics.shared.finish(outcome: "terminated")
        var replied = false
        var quitDeadline: Timer?
        func finishQuit() {
            guard !replied else { return }
            replied = true
            quitDeadline?.invalidate()
            quitDeadline = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        // Every accepted request is already durable. The deadline may skip
        // disposable cleanup; reopening conservatively reclassifies queued and
        // dispatching records without replay. Neither branch stops Wine.
        // terminateLater runs a nested modal loop. If termination originated
        // inside a main dispatch block, that queue cannot reenter to run its
        // own deadline/completions. A modal-mode timer still delivers the
        // bounded reply without waiting for the outer dispatch block to return.
        let timer = Timer(timeInterval: 3, repeats: false) { _ in finishQuit() }
        quitDeadline = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        func flushDiagnostics() {
            CyderDiagnostics.shared.flush {
                DispatchQueue.main.async { finishQuit() }
            }
        }
        if isPrimaryInstance {
            instanceCoordinator.quiesce { [weak self] saved in
                guard let self else { flushDiagnostics(); return }
                if !saved { CyderDiagnostics.shared.warning("quit: retaining durable journal for conservative recovery") }
                self.instanceCoordinator.stop { flushDiagnostics() }
            }
        } else { flushDiagnostics() }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Cyder")
        menu.autoenablesItems = false
        menu.addItem(withTitle: "遊戲庫…", action: #selector(showGameLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "選擇 Windows 執行檔…", action: #selector(chooseExecutableFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "進階設定…", action: #selector(showSettings), keyEquivalent: "")
        for item in menu.items { item.target = self }
        if readOnlyMode { menu.items.dropFirst().forEach { $0.isEnabled = false } }
        return menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Cyder")
        appMenu.autoenablesItems = false
        let settings = appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = !readOnlyMode
        let requests = appMenu.addItem(withTitle: "啟動要求…", action: #selector(showRequests), keyEquivalent: "")
        requests.target = self
        requests.isEnabled = !readOnlyMode
        let library = appMenu.addItem(withTitle: "遊戲庫…", action: #selector(showGameLibrary), keyEquivalent: "")
        library.target = self
        appMenu.addItem(NSMenuItem.separator())
        let quit = appMenu.addItem(withTitle: "退出 Cyder", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "視窗")
        let close = windowMenu.addItem(
            withTitle: "關閉視窗",
            action: #selector(closeKeyWindowFromMenu(_:)),
            keyEquivalent: "w"
        )
        close.target = self
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func closeKeyWindowFromMenu(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc private func showSettings() {
        guard !readOnlyMode else { showReadOnlyStatus(); return }
        guard !quitTransaction else { return }
        statusItemController.setUIVisible(true)
        activateCyderUI(dockVisible: true)
        settingsController.prepareForDisplay()
        settingsController.showWindow(nil)
        settingsController.window?.makeKeyAndOrderFront(nil)
        settingsController.window?.orderFrontRegardless()
    }

    @objc private func showRequests() {
        guard !readOnlyMode else { showReadOnlyStatus(); return }
        guard !quitTransaction else { return }
        statusItemController.setUIVisible(true)
        requestController.update(requestRecords, outbox: outboxNotices)
        activateCyderUI(dockVisible: true)
        requestController.showWindow(nil)
        requestController.window?.makeKeyAndOrderFront(nil)
    }

    private func cancelQueuedRequest(_ id: String) {
        cancelledRequestIDs.insert(id)
        pendingLaunchAcquisitions.remove(id)
        if let preparation = pendingPreparation.removeValue(forKey: id) { launchPreparation.cancel(preparation) }
        if let acquisition = pendingRequestAcquisitions.removeValue(forKey: id) { operationGate.cancel(acquisition) }
        for launch in queuedLaunches where launch.authorization?.id == id {
            if let lease = launch.lease { operationGate.release(lease) }
        }
        queuedLaunches.removeAll { $0.authorization?.id == id }
        requestRemaining.removeValue(forKey: id)
        launchNextQueuedExecutableIfReady()
        settleLaunchIngressIfIdle()
    }

    private func settleLaunchIngressIfIdle() {
        guard !libraryLaunchInProgress, pendingLaunchAcquisitions.isEmpty, queuedLaunches.isEmpty else { return }
        statusItemController.finishLaunchIngress()
        if !environmentPreparationInProgress && activeProcessOperations == 0 { hideSetup() }
    }

    private func exportLastGameLog() {
        guard !quitTransaction, !diagnosticsOperationInProgress else { return }
        let panel = NSSavePanel()
        panel.title = "匯出上次遊戲記錄"
        panel.message = "選擇要複製上次遊戲 Wine log 的位置。"
        panel.nameFieldStringValue = "Cyder-last-game.log"
        panel.canCreateDirectories = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        runDiagnosticsIO(message: "正在匯出上次遊戲記錄…", work: {
            try CyderDiagnostics.shared.exportLastGameLog(to: destination)
        }) { [weak self] result in
            switch result {
            case .success: self?.showAlert("上次遊戲記錄已匯出", destination.path, style: .informational)
            case .failure(let error): self?.showAlert("無法匯出上次遊戲記錄", error.localizedDescription, style: .critical)
            }
        }
    }

    /// One physical diagnostics maintenance job survives its UI deadline. A
    /// late filesystem result cannot re-open a dialog after close/quit/timeout.
    private func runDiagnosticsIO<Value>(message: String, work: @escaping () throws -> Value,
                                         completion: @escaping (Result<Value, Error>) -> Void) {
        guard !quitTransaction, !diagnosticsOperationInProgress else { return }
        diagnosticsOperationInProgress = true
        let presentation = UUID()
        diagnosticsPresentation = presentation
        environmentPreparationInProgress = true
        showSetup(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.diagnosticsPresentation == presentation, !self.quitTransaction else { return }
            self.diagnosticsPresentation = nil
            self.environmentPreparationInProgress = false
            self.hideSetup()
            if self.existingSettingsController?.window?.isVisible == true {
                self.showAlert("記錄作業尚未確認", "檔案處理時間較長。您可以繼續使用或退出 Cyder，稍後再檢查結果。")
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.diagnosticsOperationInProgress = false
                guard self.diagnosticsPresentation == presentation, !self.quitTransaction else { return }
                self.diagnosticsPresentation = nil
                self.environmentPreparationInProgress = false
                self.hideSetup()
                guard self.existingSettingsController?.window?.isVisible == true else { return }
                completion(result)
            }
        }
    }

    private func showComponentDiagnostics() {
        if componentDiagnosticsController == nil {
            let controller = CyderComponentDiagnosticsController()
            controller.onClose = { [weak self] in self?.componentDiagnosticsController = nil }
            componentDiagnosticsController = controller
        }
        componentDiagnosticsController?.showWindow(nil)
        componentDiagnosticsController?.window?.makeKeyAndOrderFront(nil)
        componentDiagnosticsController?.runScan()
    }

    private func cleanDebugLogs() { Task { @MainActor in await cleanDebugLogsAsync() } }

    @MainActor private func cleanDebugLogsAsync() async {
        guard !quitTransaction, !diagnosticsOperationInProgress else { return }
        guard await !hasRunningExes() else {
            showAlert("無法清理除錯記錄", "請先關閉所有遊戲，再清理目前的 Wine launch/debug log。")
            return
        }
        guard !quitTransaction else { return }
        let alert = NSAlert()
        alert.messageText = "清理除錯記錄？"
        alert.informativeText = "這會移除 Wine launch/debug log，以及 Logs/operations 和 Logs/sessions 內的紀錄，但不會刪除遊戲、Windows 環境或偏好設定。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清理")
        alert.addButton(withTitle: "取消")
        guard runFrontmostAlert(alert, dockVisible: true, anchorWindow: settingsController.window)
            == .alertFirstButtonReturn else { return }

        runDiagnosticsIO(message: "正在清理除錯記錄…", work: {
            try CyderDiagnostics.shared.cleanupDebugLogs()
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let summary):
                let bytes = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
                self.showAlert("除錯記錄已清理", summary.fileCount == 0
                    ? "目前沒有可清理的除錯記錄。" : "已移除 \(summary.fileCount) 個檔案，共 \(bytes)。", style: .informational)
            case .failure(let error): self.showAlert("無法清理除錯記錄", error.localizedDescription, style: .critical)
            }
        }
    }

    @objc private func showGameLibrary() {
        guard !quitTransaction else { return }
        if !readOnlyMode { statusItemController.setUIVisible(true) }
        openingGameLibrary = true
        let settingsWasVisible = existingSettingsController?.window?.isVisible == true
        activateCyderUI(dockVisible: true)
        gameLibraryController.showWindow(nil)
        gameLibraryController.window?.makeKeyAndOrderFront(nil)
        gameLibraryController.window?.orderFrontRegardless()
        gameLibraryController.prepareForDisplay()
        // Keep a visible key window throughout the transition. In particular,
        // accessibility clients can briefly collapse a hidden scroll view to
        // zero width when the settings window is ordered out first.
        if settingsWasVisible {
            settingsController.window?.orderOut(nil)
        }
        openingGameLibrary = false
    }

    private func launchGameFromLibrary(
        _ executable: URL,
        settings: CyderExecutableSettings?,
        launchArguments: [String]? = nil,
        authorization: CyderRequestJournal.Record? = nil,
        lease: CyderOperationGate.Lease? = nil
    ) {
        guard !quitTransaction, !readOnlyMode, isPrimaryInstance else {
            if let lease { operationGate.release(lease) }
            return
        }
        if authorization == nil {
            var payload = CyderRequestPayload(files: [executable.path], arguments: launchArguments, urls: [], showUI: false)
            if let settings { payload.settings = try? JSONEncoder().encode(settings) }
            presentExternalLaunchStarting()
            instanceCoordinator.submit(payload) { [weak self] accepted in
                if !accepted { self?.hideSetup(); self?.showAlert("無法接受啟動要求", "請查看診斷資訊後重試。") }
            }
            return
        }
        guard !libraryLaunchInProgress else {
            if let lease { operationGate.release(lease) }
            finishRequestPart(authorization, failed: true)
            showAlert("正在啟動另一個遊戲", "請等待目前的遊戲顯示視窗後再試一次。")
            return
        }
        guard let resourcePath = Bundle.main.resourcePath else {
            if let lease { operationGate.release(lease) }
            finishRequestPart(authorization, failed: true)
            statusItemController.finishLaunchIngress()
            showAlert("無法啟動遊戲", "Cyder 缺少必要的 Resources 目錄。")
            launchNextQueuedExecutableIfReady()
            return
        }
        presentExternalLaunchStarting()
        libraryLaunchInProgress = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            var launchEnvironment: [String: String] = [:]
            var request: URL?
            var retainRequest = false
            defer { if !retainRequest, let request { try? FileManager.default.removeItem(at: request) } }
            let outcome: CyderLaunchOutcome
            do {
                if let settings {
                    let directory = CyderPaths.support.appendingPathComponent("launch-requests", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let url = directory.appendingPathComponent("test-\(UUID().uuidString).json")
                    try JSONEncoder.pretty.encode(settings).write(to: url, options: .atomic)
                    request = url
                    launchEnvironment["CYDER_TEST_SETTINGS_REQUEST"] = url.path
                    launchEnvironment["CYDER_CAPTURE_WINE_LOG"] = "1"
                    launchEnvironment["CYDER_LAUNCH_KIND"] = "test"
                }
                outcome = await self.runDocumentLaunch(context: context, executable: executable,
                    launchArguments: launchArguments, launchEnvironment: launchEnvironment,
                    authorization: authorization, lease: lease)
                retainRequest = outcome.isUnconfirmed
            } catch {
                outcome = .failure(CyderFailure(code: "CYD-REQ-001", stage: .resourceValidation,
                    summary: "無法建立啟動設定。", technicalDetails: error.localizedDescription))
            }
            DispatchQueue.main.async {
                if !outcome.isUnconfirmed, let lease { self.operationGate.release(lease) }
                self.libraryLaunchInProgress = false
                self.finishRequestPart(authorization, failed: outcome.requestFailed, uncertain: outcome.isUnconfirmed)
                self.statusItemController.finishLaunchIngress()
                guard !self.quitTransaction else { return }
                self.hideSetup()
                switch outcome {
                case .success, .cancelled, .unconfirmed:
                    break
                case .environmentNotReady:
                    self.showAlert(
                        "遊戲尚未準備完成",
                        "請在遊戲庫按「準備 Windows 環境」，完成後再重新啟動遊戲。"
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

    private func enqueueOrLaunch(_ executableFiles: [String], arguments: [String]? = nil,
                                 authorization: CyderRequestJournal.Record? = nil) {
        guard !quitTransaction else { return }
        guard let authorization else {
            instanceCoordinator.submit(.init(files: executableFiles, arguments: arguments, urls: [], showUI: false)) { [weak self] accepted in
                if !accepted { self?.presentLaunchAcceptanceFailure() }
            }
            return
        }
        for file in executableFiles {
            prepareQueuedLaunch(QueuedLaunch(executable: file, arguments: arguments, authorization: authorization))
        }
    }

    private func prepareQueuedLaunch(_ launch: QueuedLaunch) {
        guard let requestID = launch.authorization?.id else { return }
        pendingLaunchAcquisitions.insert(requestID)
        pendingPreparation[requestID] = launchPreparation.resolve(work: { [weak self] in
            guard let self else { return nil }
            let target = wineLaunchTarget(for: launch.executable)
            let scope: CyderOperationGate.Scope
            if launch.isURI || target == .msi || target == .reg {
                scope = .prefix(CyderPaths.sharedBottle)
            } else if case .success(let prefix) = self.prefixForExecutable(URL(fileURLWithPath: launch.executable)) {
                scope = .prefix(prefix)
            } else { return nil }
            guard let snapshot = launch.authorization?.settingsSnapshot,
                  let acceptedSettings = try? JSONDecoder().decode(CyderSettings.self, from: snapshot) else { return nil }
            return CyderGraphicsRuntime.needsGlobalScope || CyderGptk.launchNeedsGlobalScope() || acceptedSettings.moltenvkVariant.launchNeedsGlobalScope()
                ? .allEnvironments : scope
        }) { [weak self] outcome in
            guard let self else { return }
            self.pendingPreparation.removeValue(forKey: requestID)
            guard !self.quitTransaction, !self.cancelledRequestIDs.contains(requestID) else {
                self.pendingLaunchAcquisitions.remove(requestID); return
            }
            guard case .resolved(let optionalScope) = outcome, let scope = optionalScope else {
                self.instanceCoordinator.deferRequest(id: requestID, reason: "scope-unavailable") { saved in
                    self.pendingLaunchAcquisitions.remove(requestID)
                    guard !self.quitTransaction else { return }
                    if !self.libraryLaunchInProgress && self.pendingLaunchAcquisitions.isEmpty && self.queuedLaunches.isEmpty {
                        self.settleLaunchIngressIfIdle()
                        if self.existingLibraryController?.window?.isVisible != true { self.showRequests() }
                    }
                    if !saved { CyderDiagnostics.shared.warning("unable to persist launch preflight pause; accepted request retained") }
                }
                return
            }
            // Stay queued in the durable journal while a conflicting stop or
            // mutation owns this environment. Authorization follows the lease.
            self.pendingRequestAcquisitions[requestID] = self.operationGate.acquire(scope) { lease in
                self.pendingRequestAcquisitions.removeValue(forKey: requestID)
                self.pendingLaunchAcquisitions.remove(requestID)
                guard let lease else { return }
                guard !self.quitTransaction, !self.cancelledRequestIDs.contains(requestID) else { self.operationGate.release(lease); return }
                var ready = launch; ready.lease = lease
                self.queuedLaunches.append(ready)
                self.launchNextQueuedExecutableIfReady()
            }
        }
    }

    private func launchNextQueuedExecutableIfReady() {
        guard !quitTransaction, !libraryLaunchInProgress,
              wineActivationWaiter == nil, !queuedLaunches.isEmpty else { return }
        libraryLaunchInProgress = true
        let launch = queuedLaunches.removeFirst()
        guard let queued = launch.authorization else {
            if let lease = launch.lease { operationGate.release(lease) }
            libraryLaunchInProgress = false
            return
        }
        instanceCoordinator.authorize(queued) { [weak self] authorization in
            guard let self else { return }
            self.libraryLaunchInProgress = false
            guard !self.quitTransaction, let authorization else {
                if let lease = launch.lease { self.operationGate.release(lease) }
                self.launchNextQueuedExecutableIfReady(); return
            }
            if #available(macOS 11.0, *), launch.isURI {
                self.launchURI(launch.executable, authorization: authorization, lease: launch.lease)
                return
            }
            self.launchGameFromLibrary(
                URL(fileURLWithPath: launch.executable),
                settings: authorization.payload?.settings.flatMap { try? JSONDecoder().decode(CyderExecutableSettings.self, from: $0) },
                launchArguments: launch.arguments,
                authorization: authorization,
                lease: launch.lease
            )
        }
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
        guard !readOnlyMode else { showReadOnlyStatus(); return }
        guard let chosen = chooseExeOnMainThread() else { return }
        presentExternalLaunchStarting()
        enqueueOrLaunch([chosen])
    }

    @discardableResult
    private func stopAllExesWaiting() async -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = await CyderLaunchContext(resourcePath: resourcePath)
        let result = await runLauncher(
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

    private func hasRunningExes() async -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return true }
        let context = await CyderLaunchContext(resourcePath: resourcePath)
        let result = await runLauncher(
            context: context,
            args: [context.launcher, "--has-running-exes"],
            stage: .engineValidation,
            operation: "has-running-exes"
        )
        return !result.didStart || result.isUnconfirmed || result.terminationReason != .exit || result.status != 1
    }

    private func applySettingsImmediately(registrySetting: String) async -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = await CyderLaunchContext(resourcePath: resourcePath)
        return await runLauncher(
            context: context,
            args: [context.launcher, "--apply-settings-only"],
            stage: .settingsApply,
            operation: "apply-settings-fast",
            extraEnvironment: ["CYDER_FAST_SETTING": registrySetting]
        ).succeeded
    }

    private func applySettingsWhileRunning(draftEnvironment: [String: String]) async -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = await CyderLaunchContext(resourcePath: resourcePath)
        var env = draftEnvironment
        env["CYDER_FORCE_SETTINGS"] = "1"
        return await runLauncher(
            context: context,
            args: [context.launcher, "--apply-settings-only"],
            stage: .settingsApply,
            operation: "apply-settings-running",
            extraEnvironment: env
        ).succeeded
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
        // CrossOver engines need cxbottle.conf; a half-built
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

    private func ensureRosettaForEnvironment() -> CyderFailure? {
        guard CyderRosetta.isAppleSilicon else { return nil }
        if CyderRosetta.isInstalled { return nil }

        CyderDiagnostics.shared.enter(.rosettaCheck)
        var response: NSApplication.ModalResponse = .alertSecondButtonReturn
        onMainThread {
            let alert = NSAlert()
            alert.messageText = "需要安裝 Rosetta 2"
            alert.informativeText =
                "Rosetta 2 是 Apple 提供的官方元件，讓 Apple Silicon Mac 能執行 x86_64 程式。"
                + "Cyder 的遊戲執行元件需要它才能運作。"
                + "若繼續安裝，將代表你同意 Apple 的軟體授權條款。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "安裝")
            alert.addButton(withTitle: "取消")
            response = runFrontmostAlert(alert, dockVisible: false)
        }
        if response != .alertFirstButtonReturn {
            return CyderFailure(
                code: "CYD-ROS-001",
                stage: .rosettaCheck,
                summary: "使用者取消安裝 Rosetta 2。",
                technicalDetails: "user-cancelled-rosetta-install"
            )
        }

        showSetup("正在安裝 Rosetta 2…")
        let installResult: (ok: Bool, detail: String)
        if Thread.isMainThread {
            installResult = DispatchQueue.global(qos: .userInitiated).sync {
                CyderRosetta.installWithAgreedLicense()
            }
        } else {
            installResult = CyderRosetta.installWithAgreedLicense()
        }
        hideSetup()
        if !installResult.ok {
            return CyderFailure(
                code: "CYD-ROS-001",
                stage: .rosettaCheck,
                summary: "無法安裝或完成 Rosetta 2。請稍後再試，或在「終端機」手動安裝。",
                technicalDetails: installResult.detail
            )
        }
        return nil
    }

    private func ensureEnvironment(context: CyderLaunchContext) async -> CyderFailure? {
        if let rosettaFailure = ensureRosettaForEnvironment() {
            return rosettaFailure
        }
        let state = environmentState(context: context)

        // Sidecar version + artifact SHA (and the signed marker) already decide
        // needsEngine. Spawning bash --ensure-engine-only on a current tree is
        // the dominant cost of opening Preferences.
        if state.needsEngine {
            CyderDiagnostics.shared.enter(.engineExtraction)
            showSetup("正在準備遊戲執行元件…")
            let result = await runLauncher(
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

        let graphicsNeedsInstall = graphicsPayloadNeedsInstall(context: context)
        if graphicsNeedsInstall {
            CyderDiagnostics.shared.enter(.engineExtraction)
            showSetup("正在準備圖形元件…")
            let graphics = await runLauncher(
                context: context,
                args: [context.launcher, "--ensure-graphics-only"],
                stage: .engineExtraction,
                operation: "graphics-install"
            )
            if !graphics.succeeded {
                return failure(
                    code: "CYD-GFX-001",
                    stage: .engineExtraction,
                    summary: graphics.status == 75 ? "圖形元件更新已延後。請關閉 Windows 程序後重試；驗證不明時會保留既有元件。" : "準備圖形元件時發生問題。",
                    result: graphics
                )
            }
        }

        // Engine installation can create/replace the engine tree and invalidate
        // the bootstrap marker. Recompute from on-disk markers after ensure so a
        // false-positive needsEngine (label/slug mismatch) cannot force
        // bootstrap + wine health-check on every Preferences open.
        let bootstrapNeeded = environmentState(context: context).needsBootstrap
        var bootstrapHealthChecked = false
        if bootstrapNeeded {
            CyderDiagnostics.shared.enter(.bootstrap)
            let progressPresentation = showSetup("正在準備遊戲環境…")
            let result = await runLauncher(
                context: context,
                args: [context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only"],
                stage: .bootstrap,
                operation: "bootstrap",
                expectsMachineResult: true,
                progressPresentation: progressPresentation
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
        // Subsequent Preferences opens already proved markers + sidecar. Skip
        // wine cmd /c exit 0 unless this launch still needs bootstrap/repair.
        // In-use prefixes must not start a second wineserver (see
        // cyder_has_running_prefix).
        if !bootstrapHealthChecked && bootstrapNeeded {
            CyderDiagnostics.shared.enter(.engineValidation)
            showSetup("正在檢查遊戲環境…")
            let health = await runLauncher(
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

    private func prepareEnvironmentFromLibrary() {
        guard !quitTransaction, !readOnlyMode, isPrimaryInstance, !environmentPreparationInProgress else { return }
        guard let resourcePath = Bundle.main.resourcePath else {
            existingLibraryController?.updateEnvironmentStatus("缺少必要元件；請查看診斷記錄", busy: false)
            return
        }
        environmentPreparationInProgress = true
        existingLibraryController?.updateEnvironmentStatus("正在檢查 Windows 環境…", busy: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let failure = await self.ensureEnvironment(context: context)
            DispatchQueue.main.async {
                self.environmentPreparationInProgress = false
                guard !self.quitTransaction else { return }
                self.hideSetup()
                if let failure {
                    CyderDiagnostics.shared.record(failure)
                    self.existingLibraryController?.updateEnvironmentStatus("準備未完成；可重試或開啟設定查看記錄", busy: false)
                } else {
                    self.existingLibraryController?.updateEnvironmentStatus("Windows 環境已準備好", busy: false)
                    self.existingLibraryController?.retryMissingIcons()
                }
            }
        }
    }

    private func runDocumentLaunch(context: CyderLaunchContext, executable: URL,
                                   launchArguments: [String]?, launchEnvironment: [String: String],
                                   authorization: CyderRequestJournal.Record?, lease: CyderOperationGate.Lease?) async -> CyderLaunchOutcome {
        // Opening an EXE is a launch-only path. It must never create or repair
        // a prefix invisibly; the user can open Cyder.app to see setup progress
        // and recovery errors.
        let precheckStarted = CFAbsoluteTimeGetCurrent()
        CyderDiagnostics.shared.enter(.exeValidation, detail: "finder-precheck")
        let state = environmentState(context: context)
        let wineReady = FileManager.default.isExecutableFile(
            atPath: CyderPaths.engine.appendingPathComponent("bin/wine").path
        )
        let graphicsPresent = graphicsPayloadsPresent()
        CyderDiagnostics.shared.noteElapsed(
            operation: "exe-precheck",
            milliseconds: (CFAbsoluteTimeGetCurrent() - precheckStarted) * 1000,
            extra: "needsEngine=\(state.needsEngine) needsBootstrap=\(state.needsBootstrap) wineReady=\(wineReady) graphics=\(graphicsPresent)"
        )
        guard !state.needsEngine, !state.needsBootstrap else {
            return .environmentNotReady
        }

        guard wineReady else {
            return .environmentNotReady
        }
        if !graphicsPresent {
            // Do not hard-block Finder EXE launches when DXVK/DXMT payloads are
            // absent. Fall back to the available Wine stack and hint the user to
            // open Cyder.app so ensure-graphics can install the payloads.
            showAlert(
                "圖形元件尚未準備完成",
                "仍會嘗試啟動。若需要 DXVK/DXMT，請先單獨開啟 Cyder.app 準備圖形元件。"
            )
            CyderDiagnostics.shared.info("graphics payloads missing; Finder document launch continuing with fallback")
        }

        let documentPath = executable.path
        let target = wineLaunchTarget(for: documentPath)
        switch target {
        case .msi, .reg:
            return await runWineThroughLauncher(
                context: context,
                exe: documentPath,
                prefix: CyderPaths.sharedBottle,
                launchArguments: launchArguments,
                launchEnvironment: launchEnvironment,
                authorization: authorization,
                lease: lease,
                launchTarget: target
            )
        case .exe, .script, .link:
            let exeURL = URL(fileURLWithPath: documentPath)
            switch prefixForExecutable(exeURL) {
            case .success(let prefix):
                return await runWineThroughLauncher(
                    context: context,
                    exe: exeURL.path,
                    prefix: prefix,
                    launchArguments: launchArguments,
                launchEnvironment: launchEnvironment,
                authorization: authorization,
                    lease: lease,
                    launchTarget: target
                )
            case .failure(let failure):
                return .failure(failure)
            }
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

    private func graphicsPayloadNeedsInstall(context: CyderLaunchContext) -> Bool {
        CyderGraphicsRuntime.needsGlobalScope || graphicsVersionNeedsInstall(name: "dxvk", context: context)
            || graphicsVersionNeedsInstall(name: "dxmt", context: context)
    }

    private func graphicsVersionNeedsInstall(name: String, context: CyderLaunchContext) -> Bool {
        guard let bundled = bundledGraphicsVersion(name: name, context: context) else {
            return false
        }
        return installedGraphicsVersion(name: name) != bundled
    }

    private func bundledGraphicsVersion(name: String, context: CyderLaunchContext) -> String? {
        let resources = URL(fileURLWithPath: context.engineVersionFile).deletingLastPathComponent()
        let versionFile = resources.appendingPathComponent("graphics/\(name)-version.txt")
        return trimmedFileContents(versionFile)
    }

    private func installedGraphicsVersion(name: String) -> String? {
        let versionFile = CyderPaths.runtimeRoot
            .appendingPathComponent("graphics/current-\(name)/.cyder-graphics-version")
        return trimmedFileContents(versionFile)
    }

    private func installWinetricks(_ verbs: [String]) { Task { @MainActor in await installWinetricksAsync(verbs) } }

    @MainActor private func installWinetricksAsync(_ verbs: [String]) async {
        let warning = NSAlert()
        warning.messageText = "安裝 Winetricks 元件？"
        warning.informativeText = "即將安裝：\n\(verbs.joined(separator: ", "))\n\n這會直接修改 Cyder 的 shared prefix。已安裝的元件、DLL override 與 registry 設定可能影響所有共用此環境的遊戲。請先關閉所有遊戲。"
        warning.alertStyle = .warning
        warning.addButton(withTitle: "安裝元件")
        warning.addButton(withTitle: "取消")
        guard runFrontmostAlert(warning, dockVisible: true, anchorWindow: settingsController.window) == .alertFirstButtonReturn else {
            return
        }

        if await hasRunningExes() {
            showAlert("無法安裝 Winetricks 元件", "shared prefix 目前仍有遊戲或 Wine 程序執行中。請關閉遊戲後再試。")
            return
        }
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("無法安裝 Winetricks 元件", "Cyder 缺少必要的 Resources 目錄。")
            return
        }

        environmentPreparationInProgress = true
        showSetup("正在安裝 Winetricks 元件…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let result = await self.runLauncher(
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
        launchEnvironment: [String: String] = [:],
        authorization: CyderRequestJournal.Record? = nil,
        lease: CyderOperationGate.Lease? = nil,
        launchTarget: CyderWineLaunchTarget = .exe
    ) async -> CyderLaunchOutcome {
        let launchID = authorization?.launchID ?? UUID().uuidString
        let authority: CyderLaunchObserver.Authority? = authorization.flatMap { record in
            guard let launch = record.launchID, let epoch = record.executorEpoch else { return nil }
            return .init(request: record.id, launch: launch, digest: record.digest, epoch: epoch)
        }
        let activationWaiter = WineActivationWaiter(prefix: prefix.path, launchID: launchID)
        let observer = CyderLaunchObserver(authority: authority)
        onMainThread { wineActivationWaiter = activationWaiter; wineLaunchObserver = observer }
        defer {
            onMainThread {
                if wineActivationWaiter === activationWaiter {
                    wineActivationWaiter = nil
                }
                if wineLaunchObserver === observer { wineLaunchObserver = nil }
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

        // Accepted requests must never consult settings saved after acceptance.
        // The native launcher reads both settings layers before detaching Wine;
        // its actual exit (not the UI observation deadline) owns file cleanup.
        let snapshotURL = requestDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        let acceptedSettings: CyderSettings
        do {
            guard let snapshot = authorization?.settingsSnapshot else {
                throw CyderRequestJournal.Failure.invalid
            }
            acceptedSettings = try JSONDecoder().decode(CyderSettings.self, from: snapshot)
            var info = stat()
            guard lstat(requestDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), chmod(requestDirectory.path, 0o700) == 0 else {
                throw CyderRequestJournal.Failure.unavailable
            }
            try JSONEncoder().encode(acceptedSettings).write(to: snapshotURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: snapshotURL)
            return .failure(CyderFailure(code: "CYD-WIN-001", stage: .wineSpawn,
                summary: "無法讀取這筆啟動要求的設定，尚未啟動 Windows 程式。",
                technicalDetails: "Accepted settings snapshot unavailable or invalid"))
        }
        var snapshotOwnedByExecutor = false
        defer { if !snapshotOwnedByExecutor { try? FileManager.default.removeItem(at: snapshotURL) } }

        let executableName = URL(fileURLWithPath: exe).deletingPathExtension().lastPathComponent
        let pidURL = requestDirectory.appendingPathComponent("wine-\(launchID).pid")
        let exitResultURL = requestDirectory.appendingPathComponent("wine-\(launchID).result")
        let activatedURL = requestDirectory.appendingPathComponent("wine-\(launchID).activated")
        let lifecycleURL = requestDirectory.appendingPathComponent("wine-\(launchID).lifecycle")
        var launchActivated = false
        var retainTransport = false
        defer {
            if !retainTransport { try? FileManager.default.removeItem(at: pidURL) }
            let shouldRetainTransport = retainTransport
            let observedActivation = launchActivated
            DispatchQueue.main.async { [self] in
                statusItemController.finishLaunchObservation(id: launchID, activated: observedActivation) { keepGroup in
                    DispatchQueue.global(qos: .utility).async {
                        if shouldRetainTransport { return }
                        if keepGroup {
                            FileManager.default.createFile(atPath: activatedURL.path, contents: Data())
                        } else {
                            for url in [exitResultURL, activatedURL, lifecycleURL] {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }
                    }
                }
            }
        }
        var args = [context.launcher, "--engine-src", context.engineSrc]
        switch launchTarget {
        case .exe:
            args.append(contentsOf: ["--launch-exe", exe])
        case .msi:
            args.append(contentsOf: ["--launch-msi", exe])
        case .script:
            args.append(contentsOf: ["--launch-script", exe])
        case .link:
            args.append(contentsOf: ["--launch-lnk", exe])
        case .reg:
            args.append(contentsOf: ["--launch-reg", exe])
        }
        if let launchArguments, !launchArguments.isEmpty {
            args.append("--")
            args.append(contentsOf: launchArguments)
        }
        var wineLaunchEnvironment = CyderSettingsStore.environment(acceptedSettings)
        wineLaunchEnvironment.merge(launchEnvironment) { _, override in override }
        // Internal transport and lifecycle keys always win over per-game
        // environment values.
        wineLaunchEnvironment.merge([
            "CYDER_WINE_SETTINGS_SNAPSHOT": snapshotURL.path,
            "CYDER_WINE_DETACH": "1",
            "CYDER_WINE_PID_FILE": pidURL.path,
            "CYDER_WINE_RESULT_FILE": exitResultURL.path,
            "CYDER_WINE_ACTIVATED_FILE": activatedURL.path,
            "CYDER_WINE_LIFECYCLE_FILE": lifecycleURL.path,
            "CYDER_SESSION_GUARD": "1",
            "CYDER_ENVIRONMENT_MONITOR": "1",
            // Always retain the quiet startup stream for optional manual
            // diagnosis. UI classification uses the per-launch wait result
            // below and does not depend on Wine log text.
            "CYDER_CAPTURE_WINE_LOG": "1",
        ]) { _, internalValue in internalValue }
        let operation: String = {
            switch launchTarget {
            case .msi: return "msi-launch"
            case .script: return "script-launch"
            case .link: return "lnk-launch"
            case .reg: return "reg-launch"
            case .exe: return "wine-launch"
            }
        }()
        let monitor = onMainThread { environmentMonitor }
        guard let execution = await monitor.beginExecution(prefix: prefix, engine: CyderPaths.engine.appendingPathComponent("bin/wineserver"),
            drained: { [weak observer] scope in observer?.receiveEnvironmentEnded(prefixScope: scope) }) else {
            return .failure(CyderFailure(code: "CYD-WIN-001", stage: .wineSpawn,
                summary: "無法確認 Windows 環境；請重新檢查後再啟動。",
                technicalDetails: "Environment identity unavailable or monitor quiescing"))
        }
        observer.observeDrain { scope in monitor.confirmRootExit(execution, prefixScope: scope) }
        defer { monitor.cancelDrainObservation(execution) }
        guard let stamp = await monitor.executionStamp(execution), let authorization, let authority,
              authorization.phase == .dispatching else {
            monitor.endExecution(execution)
            return .unconfirmed
        }
        let lifecycleController = onMainThread { statusItemController }
        onMainThread {
            statusItemController.beginLaunch(id: launchID, prefix: prefix, executableName: executableName,
                authority: authority, stamp: stamp,
                committedRequest: .init(id: authorization.id, digest: authorization.digest, environment: stamp.environment,
                    phase: .dispatching, launch: launchID))
        }
        var lifecycleOutcome: CyderLifecycle.Outcome = .failed
        defer { lifecycleController.receiveLifecycleEvent(.observationFinished(stamp, launch: launchID, outcome: lifecycleOutcome)) }
        let result = await runLauncher(
            context: context,
            args: args,
            stage: .wineSpawn,
            operation: operation,
            authorization: authorization,
            extraEnvironment: wineLaunchEnvironment,
            lease: lease,
            operationScope: .prefix(prefix),
            onSpawn: { [weak self] receipt in
                guard let self else { return }
                let birth = CyderEnvironmentProbe.processIdentity(receipt.supervisorPID)
                self.instanceCoordinator.recordSpawn(authorization, pid: receipt.supervisorPID, boot: birth?.boot, started: birth?.started)
            },
            onRelease: { [weak self] in
                try? FileManager.default.removeItem(at: snapshotURL)
                monitor.endExecution(execution)
                guard let self else { return }
                DispatchQueue.main.async {
                    guard !self.quitTransaction else { return }
                    self.statusItemController.monitorEnvironment(prefix: prefix)
                }
            }
        )
        snapshotOwnedByExecutor = result.didStart
        if !result.didStart { monitor.endExecution(execution) }
        if result.isUnconfirmed { lifecycleOutcome = .unconfirmed; retainTransport = true; return .unconfirmed }
        guard result.succeeded else {
            if launchTarget == .msi && result.status == 75 {
                return .failure(CyderFailure(
                    code: "CYD-MSI-001",
                    stage: .wineSpawn,
                    summary: "請先關閉所有 Wine 程序，再安裝 MSI。",
                    technicalDetails: result.outputTail,
                    exitCode: result.status,
                    logURL: result.logURL
                ))
            }
            if launchTarget == .reg && result.status == 75 {
                return .failure(CyderFailure(
                    code: "CYD-REG-001",
                    stage: .wineSpawn,
                    summary: "請先關閉所有 Wine 程序，再匯入登錄檔。",
                    technicalDetails: result.outputTail,
                    exitCode: result.status,
                    logURL: result.logURL
                ))
            }
            let summary: String = {
                switch launchTarget {
                case .msi: return "Bash 無法啟動 MSI 安裝程式。"
                case .script: return "Bash 無法執行批次檔。"
                case .link: return "Bash 無法開啟捷徑。"
                case .reg: return "Bash 無法匯入登錄檔。"
                case .exe: return "Bash 無法啟動 Wine。"
                }
            }()
            return .failure(failure(
                code: "CYD-WIN-001",
                stage: .wineSpawn,
                summary: summary,
                result: result
            ))
        }

        onMainThread {
            if #available(macOS 11.0, *), let resourcePath = Bundle.main.resourcePath {
                CyderURIHandlerManager.shared.beginWineSession(prefix: prefix,
                    launcher: CyderLaunchContext.launcherPath(resourcePath: resourcePath))
            }
        }
        let observation = await observer.wait(duration: 30, signal: activationWaiter, onStarted: { deadline in
            lifecycleController.receiveLifecycleEvent(.observationStarted(stamp, launch: launchID, deadline: deadline))
        })
        switch observation {
        case .activated:
            lifecycleOutcome = .confirmedStarted
            launchActivated = true
            FileManager.default.createFile(atPath: activatedURL.path, contents: Data())
            CyderDiagnostics.shared.enter(.wineActivation, detail: "notification-received")
            onMainThread { statusItemController.markActivated(id: launchID) }
            return .success
        case .finishedWithoutWindow:
            lifecycleOutcome = .finishedWithoutWindow
            CyderDiagnostics.shared.info("wine launch completed without activation; root receipt ended")
            return .success
        case .rootFailed(let status):
            return earlyWineExitFailure(executablePath: exe, winePID: onMainThread { statusItemController.nativeRootPID(id: launchID) }, exitStatus: status, fallbackLogURL: result.logURL)
        case .unconfirmed:
            lifecycleOutcome = .unconfirmed
            retainTransport = true
            CyderDiagnostics.shared.warning("launch observation ended without confirmation; detached executor may remain")
            return .unconfirmed
        }
    }

    private func runPrefixAction(_ action: String, prefix: URL, operation: String) {
        guard let resourcePath = Bundle.main.resourcePath else {
            showAlert("操作未完成", "Cyder 缺少必要的 Resources 目錄。")
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            let result = await self.runLauncher(
                context: context,
                args: [context.launcher, action, prefix.path],
                stage: .wineSpawn,
                operation: operation
            )
            if !result.succeeded {
                DispatchQueue.main.async {
                    self.showAlert("操作未完成", "無法對這個 Windows 環境執行操作。")
                }
            }
        }
    }

    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    private func requestStopEnvironment(prefixes: [URL]) {
        guard !quitTransaction else { return }
        let current = Set(statusItemController.monitoredPrefixes)
        let targets = prefixes.filter { current.contains($0) }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "停止 Windows 環境？" : "停止所有 Windows 環境？"
        alert.informativeText = "這會停止以下環境內的所有遊戲與背景程序，包含未列出的程式。未儲存的內容可能遺失。\n" + targets.map(\.lastPathComponent).joined(separator: "、")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "停止環境")
        alert.addButton(withTitle: "取消")
        guard runFrontmostAlert(alert, dockVisible: false) == .alertFirstButtonReturn else { return }
        statusItemController.requestStop(prefixes: targets)
    }

    private func runStopEnvironment(prefix: URL, stamp: CyderLifecycle.Stamp, operation: UUID) {
        guard !quitTransaction, let resourcePath = Bundle.main.resourcePath else { return }
        // Prefix here comes from the monitor's canonical snapshot. Reserve the
        // effect's position now, before dispatching any background preparation.
        operationGate.acquire(.environment(prefix.path)) { [weak self] lease in
            guard let self, let lease else { return }
            guard !self.quitTransaction else { self.operationGate.release(lease); return }
            Task.detached(priority: .userInitiated) {
                let context = await CyderLaunchContext(resourcePath: resourcePath)
                let result = await self.runLauncher(context: context,
                    args: [context.launcher, "--stop-prefix", prefix.path], stage: .wineSpawn, operation: "stop-prefix",
                    lease: lease,
                    validateBeforeSpawn: {
                        guard let identity = CyderEnvironmentProbe.identify(prefix: prefix, engine: CyderPaths.engine.appendingPathComponent("bin/wineserver")),
                              identity.environment == stamp.environment else { return false }
                        return self.onMainThread { self.statusItemController.canExecuteStop(stamp: stamp, operation: operation) }
                    })
                DispatchQueue.main.async {
                    self.statusItemController.stopFinished(stamp: stamp, operation: operation, success: result.succeeded)
                }
            }
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
        guard pid > 0, !prefix.isEmpty else { return }
        // Distributed notifications are hints. The controller validates exact
        // process-tree ownership and a current visible window off AppKit.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.quitTransaction else { return }
            self.statusItemController.adoptWindowedProcess(pid: pid, prefix: prefix, name: nil)
        }
    }

    @objc private func wineWorkspaceDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = application.processIdentifier, name = application.localizedName
        let isWine = isWineMacApplication(application)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.quitTransaction, pid > 0 else { return }
            self.statusItemController.noteFrontmostApplication(pid)
            guard isWine else { return }
            // No WINEPREFIX read or fallback to whichever request is waiting.
            // The actual root/descendant birth is the ownership evidence.
            self.statusItemController.adoptWindowedProcess(pid: pid, prefix: "", name: name)
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
        guard let bundled = trimmedFileContents(URL(fileURLWithPath: context.engineVersionFile)),
            !bundled.isEmpty
        else {
            return false
        }
        let installedFile = engineWine
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("version")
        guard let installed = trimmedFileContents(installedFile),
            !installed.isEmpty
        else {
            return true
        }
        if !cyderEngineVersionsEqual(installed, bundled) {
            return true
        }
        let engineRoot = engineWine
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let signedMarker = engineRoot.appendingPathComponent(".cyder-engine-signed")
        if !FileManager.default.fileExists(atPath: signedMarker.path) {
            return true
        }
        let resources = URL(fileURLWithPath: context.engineVersionFile).deletingLastPathComponent()
        let bundledFingerprintFile = resources.appendingPathComponent("engine-artifact-sha256.txt")
        guard let bundledFingerprint = trimmedFileContents(bundledFingerprintFile),
            !bundledFingerprint.isEmpty
        else {
            return false
        }
        let installedFingerprintFile = installedFile.deletingLastPathComponent()
            .appendingPathComponent(".cyder-engine-artifact-sha256")
        let installedFingerprint = trimmedFileContents(installedFingerprintFile)
        return installedFingerprint != bundledFingerprint
    }

    private func trimmedFileContents(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func onMainThread<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        } else {
            return DispatchQueue.main.sync(execute: work)
        }
    }

    @discardableResult
    private func showSetup(_ message: String) -> UUID? {
        onMainThread {
            guard !quitTransaction else { return nil }
            let presentation = setupProgress.present()
            renderSetup(message)
            return presentation
        }
    }

    private func renderSetup(_ message: String) {
        precondition(Thread.isMainThread)
        guard !quitTransaction else { return }
        if environmentPreparationInProgress, let library = existingLibraryController, library.window?.isVisible == true {
            library.updateEnvironmentStatus(message, busy: true)
            return
        }
        if setupPanel == nil {
            setupPanel = CyderSetupPanel()
            setupPanel?.show()
        }
        setupPanel?.setMessage(message)
    }

    private func formattedSetupProgress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        var label = ""
        var elapsedMs = 0
        var sawStructured = false
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let piece = String(line)
            if piece.hasPrefix("label=") {
                label = String(piece.dropFirst("label=".count))
                sawStructured = true
            } else if piece.hasPrefix("elapsed_ms="),
                      let parsed = Int(piece.dropFirst("elapsed_ms=".count)) {
                elapsedMs = parsed
                sawStructured = true
            } else if piece.hasPrefix("stage=") {
                sawStructured = true
            }
        }
        guard sawStructured else { return trimmed }
        if elapsedMs > 0 {
            let seconds = Double(elapsedMs) / 1000.0
            let shown = seconds >= 10
                ? String(format: "%.0f", seconds)
                : String(format: "%.1f", seconds)
            return "\(label)（\(shown)s）"
        }
        return label
    }

    private func hideSetup() {
        onMainThread {
            setupProgress.invalidate()
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
        CyderDiagnostics.shared.loadPreviousSession { [weak self] previous in
            guard let self, previous != nil, !self.quitTransaction else { return }
            // No startup modal; a stalled diagnostic read never gates first UI.
            self.gameLibraryController.showRecoveryNotice()
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
        precondition(Thread.isMainThread)
        guard !quitTransaction, !openingGamesDirectory else { return }
        openingGamesDirectory = true
        let presentation = UUID()
        gamesDirectoryPresentation = presentation
        let configured = Bundle.main.object(forInfoDictionaryKey: "CyderRecommendedGamesDirectory") as? String
        let configuredPath = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "~/Games"
        let relative = configuredPath.replacingOccurrences(of: "~/", with: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.quitTransaction, self.gamesDirectoryPresentation == presentation else { return }
            self.gamesDirectoryPresentation = nil
            self.showAlert("資料夾尚未確認", "建立資料夾的時間較長。你可以稍後在 Finder 前往 \(configuredPath)；Cyder 不會在這個操作稍後完成時突然開啟 Finder。")
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<URL, Error> {
                let games = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(relative, isDirectory: true)
                try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
                return games
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Keep the physical reservation until the filesystem call
                // returns, even after the feedback deadline or during quit.
                self.openingGamesDirectory = false
                guard !self.quitTransaction, self.gamesDirectoryPresentation == presentation else { return }
                self.gamesDirectoryPresentation = nil
                switch result {
                case .success(let games): NSWorkspace.shared.open(games)
                case .failure(let error):
                    self.showAlert("無法建立 Games 資料夾", error.localizedDescription, style: .critical)
                }
            }
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
        authorization: CyderRequestJournal.Record? = nil,
        extraEnvironment: [String: String] = [:],
        lease: CyderOperationGate.Lease? = nil,
        operationScope: CyderOperationGate.Scope? = nil,
        expectsMachineResult: Bool = false,
        progressPresentation: UUID? = nil,
        validateBeforeSpawn: @escaping () -> Bool = { true },
        onSpawn: @escaping (CyderProcessRunner.Receipt) -> Void = { _ in },
        onRelease: @escaping () -> Void = {}
    ) async -> CyderProcessResult {
        CyderDiagnostics.shared.enter(stage, detail: operation)
        let operationLog = CyderDiagnostics.shared.makeOperationLog(operation)
        let isLaunch = args.contains(where: { $0.hasPrefix("--launch-") })
        let isObservation = args.contains("--has-running-exes")
        let settingsIndependent = isObservation || args.contains("--stop-prefix") || args.contains("--stop-all")
        var scope = operationScope ?? .allEnvironments
        if operationScope == nil,
           let index = args.firstIndex(where: { $0 == "--stop-prefix" || $0 == "--taskmgr-prefix" }),
           args.indices.contains(index + 1) { scope = .prefix(URL(fileURLWithPath: args[index + 1])) }
        let prefixScope = scope
        if isLaunch {
            let accepted = authorization?.settingsSnapshot.flatMap { try? JSONDecoder().decode(CyderSettings.self, from: $0) }
            if lease?.scope == .allEnvironments || (lease == nil &&
                (CyderGraphicsRuntime.needsGlobalScope || CyderGptk.launchNeedsGlobalScope() || (accepted?.moltenvkVariant.launchNeedsGlobalScope() ?? false))) {
                scope = .allEnvironments
            }
        }
        let acquired: CyderOperationGate.Lease?
        if isObservation { acquired = nil }
        else if let lease { acquired = lease }
        else { acquired = await operationGate.acquire(scope) }
        var transferredLease = false
        defer { if !transferredLease, let acquired { operationGate.release(acquired) } }
        guard (isObservation || (acquired != nil && acquired?.scope == scope)), validateBeforeSpawn() else {
            return CyderProcessResult(status: 125, terminationReason: .exit, logURL: operationLog,
                outputTail: "Environment operation cancelled or target changed before dispatch", didStart: false)
        }
        do {
            try CyderDiagnostics.shared.prepareOperationLog(at: operationLog)
        } catch {
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: "Unable to prepare operation log at \(operationLog.path): \(error)", didStart: false
            )
        }
        guard let handle = FileHandle(forWritingAtPath: operationLog.path) else {
            return CyderProcessResult(
                status: 1,
                terminationReason: .exit,
                logURL: operationLog,
                outputTail: "Unable to create operation log at \(operationLog.path)", didStart: false
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
        if !settingsIndependent, extraEnvironment["CYDER_WINE_SETTINGS_SNAPSHOT"] == nil {
            do {
                let saved = try CyderSettingsStore.readValidated(at: CyderPaths.support.appendingPathComponent("settings.json"))
                environment.merge(CyderSettingsStore.environment(saved)) { _, saved in saved }
            } catch {
                try? handle.close()
                return CyderProcessResult(status: 1, terminationReason: .exit, logURL: operationLog,
                    outputTail: "Unable to read saved settings; operation was not started", didStart: false)
            }
        }
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        // These helper paths are internal transport, never per-game overrides.
        environment["CYDER_ENVIRONMENT_HELPER"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CyderSwift").path
        environment["CYDER_ENVIRONMENT_SERVER"] = CyderPaths.engine.appendingPathComponent("bin/wineserver").path
        // Observation and explicit stop must remain usable with broken settings.
        environment["CYDER_WINE_SETTINGS_INDEPENDENT"] = settingsIndependent ? "1" : "0"
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
        var handoffCleanupURL: URL?
        if !isObservation {
            let ownerRoot = CyderPaths.support.appendingPathComponent("execution-owners")
            let prefix: String?
            switch prefixScope { case .allEnvironments: prefix = nil; case .environment(let path): prefix = path }
            do {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CyderSwift")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw CyderExecutionOwner.Failure.unavailable }
                let issuer = onMainThread { instanceCoordinator.executionEpoch }
                let correlation: CyderExecutionOwner.Correlation?
                if let authorization {
                    guard let launchID = authorization.launchID, authorization.executorEpoch == issuer else {
                        throw CyderExecutionOwner.Failure.revoked
                    }
                    correlation = .init(requestID: authorization.id, launchID: launchID, digest: authorization.digest)
                } else { correlation = nil }
                let handoff: CyderExecutionOwner.Handoff?
                if extraEnvironment["CYDER_WINE_DETACH"] == "1", let pidFile = extraEnvironment["CYDER_WINE_PID_FILE"] {
                    handoff = .init(executable: CyderPaths.engine.appendingPathComponent("bin/wine").resolvingSymlinksInPath().path,
                                    pidFile: pidFile)
                } else if args.contains("--taskmgr-prefix") {
                    // prepare creates and verifies this private owner directory;
                    // this per-operation transport is consumed by Bash only.
                    let pidURL = ownerRoot.appendingPathComponent("taskmgr-\(UUID().uuidString).pid")
                    handoffCleanupURL = pidURL
                    environment["CYDER_WINE_PID_FILE"] = pidURL.path
                    handoff = .init(executable: CyderPaths.engine.appendingPathComponent("bin/wine").resolvingSymlinksInPath().path,
                                    pidFile: pidURL.path)
                } else { handoff = nil }
                let ticket = try CyderExecutionOwner.prepare(root: ownerRoot, issuer: issuer, scope: prefix,
                                                            correlation: correlation, handoff: handoff,
                                                            requiresGlobalScope: scope == .allEnvironments)
                process.executableURL = helper
                process.arguments = ["--execution-owner", ownerRoot.path, ticket.uuidString, "--", "/bin/bash"] + args
                process.environment = environment
            } catch {
                try? handle.close()
                return CyderProcessResult(status: 75, terminationReason: .exit, logURL: operationLog,
                    outputTail: "Unable to reserve native executor ownership: \(error)", didStart: false)
            }
        }
        let command = CyderDiagnostics.shared.redact(
            "cmd=/bin/bash \(args.joined(separator: " "))\nstage=\(stage.rawValue)\n\n"
        )
        try? handle.write(contentsOf: Data(command.utf8))
        process.standardOutput = handle
        process.standardError = handle

        let progressWatch: UUID? = onMainThread {
            guard trackProgress, let progressPresentation, !quitTransaction else { return nil }
            return setupProgress.begin(presentation: progressPresentation, url: progressURL) { [weak self] text in
                guard let self else { return }
                self.renderSetup(self.formattedSetupProgress(text))
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        onMainThread { activeProcessOperations += 1 }
        transferredLease = true
        let gate = operationGate
        let transportToRemove = handoffCleanupURL
        let outcome = await processRunner.run(process: process,
            policy: isLaunch ? .launch : (isObservation ? .observation : .mutation),
            deadline: isLaunch ? 30 : (isObservation ? 5 : ((args.contains("--stop-prefix") || args.contains("--stop-all")) ? 15 : nil)), output: handle,
            onSpawn: onSpawn, onRelease: { [weak self] in
                if let transportToRemove { try? FileManager.default.removeItem(at: transportToRemove) }
                if let acquired { gate.release(acquired) }
                onRelease()
                guard let self else { return }
                DispatchQueue.main.async {
                    self.activeProcessOperations -= 1
                    self.instanceCoordinator.refreshExecutionReceipts()
                }
            })
        if let progressWatch { onMainThread { setupProgress.end(progressWatch) } }
        let status: Int32
        let reason: Process.TerminationReason
        var unconfirmed = false
        switch outcome {
        case .exited(let code, let signalled): status = code; reason = signalled ? .uncaughtSignal : .exit
        case .failedToStart(let message):
            return CyderProcessResult(status: 1, terminationReason: .exit, logURL: operationLog, outputTail: message, didStart: false)
        case .cancelledBeforeSpawn:
            return CyderProcessResult(status: 125, terminationReason: .exit, logURL: operationLog, outputTail: "Cancelled before subprocess spawn", didStart: false)
        case .unconfirmed:
            status = 75; reason = .exit; unconfirmed = true
        }
        // A timed-out process still owns its output file. Do not trim or remove
        // its transport files until actual process termination.
        if !unconfirmed {
            CyderDiagnostics.shared.trimRollingOperationLog(at: operationLog)
            try? FileManager.default.removeItem(at: progressURL)
        }
        let tail = CyderDiagnostics.shared.tail(of: operationLog)
        var machineResult: [String: String] = [:]
        if !unconfirmed, expectsMachineResult,
           let data = try? Data(contentsOf: resultURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            for (key, value) in dictionary where key != "schemaVersion" {
                if let value = value as? String { machineResult[key] = value }
            }
        }
        if !unconfirmed { try? FileManager.default.removeItem(at: resultURL) }
        CyderDiagnostics.shared.noteElapsed(operation: operation,
            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
            extra: "status=\(status) unconfirmed=\(unconfirmed) log=\(operationLog.path)")
        return CyderProcessResult(status: status, terminationReason: reason, logURL: operationLog,
                                  outputTail: tail, machineResult: machineResult, isUnconfirmed: unconfirmed)
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
        CyderURIHandlerManager.shared.wineSessionEnded(prefix: prefix,
            launcher: CyderLaunchContext.launcherPath(resourcePath: resourcePath))
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
    private func enqueueOrLaunchURIs(_ uris: [String], authorization: CyderRequestJournal.Record? = nil) {
        guard !uris.isEmpty, !quitTransaction else { return }
        guard let authorization else {
            instanceCoordinator.submit(.init(files: [], arguments: nil, urls: uris, showUI: false)) { [weak self] accepted in
                if !accepted { self?.presentLaunchAcceptanceFailure() }
            }
            return
        }
        presentExternalLaunchStarting()
        for uri in uris {
            prepareQueuedLaunch(QueuedLaunch(executable: uri, arguments: nil, isURI: true, authorization: authorization))
        }
    }

    private func presentLaunchAcceptanceFailure() {
        guard !quitTransaction else { return }
        hideSetup()
        statusItemController.finishLaunchIngress()
        CyderDiagnostics.shared.warning("launch request rejected before durable acceptance; no executable dispatched")
        showAlert("無法開始啟動", "Cyder 無法保存啟動要求或確認設定；程式尚未執行。請查看診斷記錄，再重新取得登入資訊後啟動。")
    }

    private func presentExternalLaunchStarting() {
        guard !quitTransaction else { return }
        documentLaunchRequested = true
        terminateWhenSettingsClose = false
        NSApp.setActivationPolicy(.accessory)
        statusItemController.markLaunchStarted()
        showSetup("正在啟動程式…")
        if existingSettingsController?.window?.isVisible == true {
            settingsController.close()
        }
    }

    private func launchModeDetail() -> String {
        if !pendingFiles.isEmpty { return "finder-exe" }
        if documentLaunchRequested { return "uri" }
        return "settings"
    }

    @available(macOS 11.0, *)
    private func launchURI(_ uri: String, authorization: CyderRequestJournal.Record? = nil,
                           lease: CyderOperationGate.Lease? = nil) {
        guard !quitTransaction else { if let lease { operationGate.release(lease) }; return }
        guard let resourcePath = Bundle.main.resourcePath else {
            if let lease { operationGate.release(lease) }
            hideSetup()
            finishRequestPart(authorization, failed: true)
            statusItemController.finishLaunchIngress()
            showAlert("無法開啟 gamaniagames://", "Cyder 缺少必要的 Resources 目錄。")
            launchNextQueuedExecutableIfReady()
            return
        }
        let prefix = CyderPaths.sharedBottle
        libraryLaunchInProgress = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let context = await CyderLaunchContext(resourcePath: resourcePath)
            CyderDiagnostics.shared.enter(.exeValidation, detail: "uri-precheck")
            let started = ProcessInfo.processInfo.systemUptime
            let validation = CyderURIHandlerManager.shared.validateLaunch(prefix: prefix, launcher: context.launcher)
            CyderDiagnostics.shared.noteElapsed(operation: "uri-precheck",
                milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            let outcome: CyderLaunchOutcome
            switch validation {
            case .failure(let error):
                outcome = .failure(CyderFailure(code: "CYD-URI-001", stage: .exeValidation,
                    summary: "無法開啟 gamaniagames://", technicalDetails: error.localizedDescription))
            case .success(let handler):
                outcome = await self.runWineThroughLauncher(context: context,
                    exe: handler.resolvedExecutable, prefix: prefix, launchArguments: [uri],
                    authorization: authorization, lease: lease)
            }
            DispatchQueue.main.async {
                if !outcome.isUnconfirmed, let lease { self.operationGate.release(lease) }
                self.libraryLaunchInProgress = false
                self.finishRequestPart(authorization, failed: outcome.requestFailed, uncertain: outcome.isUnconfirmed)
                self.statusItemController.finishLaunchIngress()
                guard !self.quitTransaction else { return }
                self.hideSetup()
                if case .failure(let failure) = outcome { self.presentFailure(failure) }
                self.launchNextQueuedExecutableIfReady()
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
        CyderURIHandlerManager.shared.scanAsync(
            prefix: CyderPaths.sharedBottle,
            launcher: CyderLaunchContext.launcherPath(resourcePath: resourcePath)
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
        if ["--graphics-runtime-state", "--graphics-update-guard"].contains(CommandLine.arguments.dropFirst().first ?? "") {
            DispatchQueue.global(qos: .utility).async { exit(CyderGraphicsRuntime.run(arguments: CommandLine.arguments)) }
            dispatchMain()
        }
        if CommandLine.arguments.dropFirst().first == "--environment-state" {
            DispatchQueue.global(qos: .utility).async {
                exit(CyderEnvironmentCommand.run(arguments: CommandLine.arguments))
            }
            dispatchMain()
        }
        if ["--execution-owner", "--execution-wine"].contains(CommandLine.arguments.dropFirst().first ?? "") {
            exit(CyderExecutionOwner.run(arguments: CommandLine.arguments))
        }
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
