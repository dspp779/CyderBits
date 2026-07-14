// Cyder.app entry — phased setup UI, then launch Windows EXE directly with Wine.
import Cocoa
import Foundation
import UniformTypeIdentifiers

private enum CyderPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home
        .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
    static let runtimeRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["CYDER_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".cyder/runtime", isDirectory: true)
    }()
    static let engine = runtimeRoot
        .appendingPathComponent("Engines/wine-x86_64", isDirectory: true)
    static let sharedBottle = support
        .appendingPathComponent("bottles/shared", isDirectory: true)
    static let bootstrapMarker = sharedBottle.appendingPathComponent(".cyder-bootstrap-v1")
}

private struct CyderSettings: Codable {
    var schemaVersion = 1
    var msync = false
    var esync: Bool? = false
    var retinaMode = true
    var dpi = 192
    var fontPreset = "songti"
    var fontSmoothing = "grayscale"

    static let defaults = CyderSettings()
}

private final class CyderSettingsStore {
    static let shared = CyderSettingsStore()
    private(set) var value: CyderSettings
    private let url: URL

    private init() {
        url = CyderPaths.support.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(CyderSettings.self, from: data),
           decoded.schemaVersion == 1 {
            value = decoded
        } else {
            value = .defaults
        }
    }

    func update(_ work: (inout CyderSettings) -> Void) throws {
        var next = value
        work(&next)
        next.dpi = min(480, max(72, next.dpi))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(next)
        try data.write(to: url, options: .atomic)
        value = next
    }

    func reset() throws {
        try update { $0 = .defaults }
    }

    var environment: [String: String] {
        [
            "CYDER_MSYNC": value.msync ? "1" : "0",
            "CYDER_ESYNC": (value.esync ?? false) ? "1" : "0",
            "CYDER_RETINA_MODE": value.retinaMode ? "1" : "0",
            "CYDER_DPI": String(value.dpi),
            "CYDER_FONT_PRESET": value.fontPreset,
            "CYDER_FONT_SMOOTHING": value.fontSmoothing,
        ]
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private final class CyderSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onCommit: ((Bool) -> Void)?
    var onSaveStarted: (() -> Void)?
    var onSaveFailed: (() -> Void)?
    var onClose: (() -> Void)?
    var hasRunningExes: (() -> Bool)?
    private let store = CyderSettingsStore.shared
    private let msync = NSSwitch()
    private let esync = NSSwitch()
    private let retina = NSSwitch()
    private let dpi = NSPopUpButton()
    private let font = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let status = NSTextField(labelWithString: "設定將於下次啟動遊戲時生效")
    private var isDirty = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Cyder 進階設定"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildUI()
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window {
            NSApp.stopModal()
        }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放棄尚未儲存的設定？"
        alert.informativeText = "按「繼續編輯」可返回設定視窗。"
        alert.addButton(withTitle: "放棄變更")
        alert.addButton(withTitle: "繼續編輯")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(makeGeneralTab())
        tabs.addTabViewItem(makeDisplayTab())
        tabs.addTabViewItem(makeFontsTab())

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "全部恢復預設值…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        let confirm = NSButton(title: "確認", target: self, action: #selector(confirmChanges))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        confirm.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(tabs)
        content.addSubview(status)
        content.addSubview(reset)
        content.addSubview(confirm)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            confirm.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reset.trailingAnchor.constraint(equalTo: confirm.leadingAnchor, constant: -10),
            reset.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            confirm.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
    }

    private func makeGeneralTab() -> NSTabViewItem {
        msync.target = self
        msync.action = #selector(msyncChanged)
        esync.target = self
        esync.action = #selector(esyncChanged)
        let msyncDescription = note("使用 macOS 原生同步機制改善部分遊戲效能；若遊戲凍結或無法啟動，可保持關閉。")
        let esyncDescription = note("使用事件同步機制降低等待開銷。MSync 與 ESync 不能同時開啟。")
        return tab("一般", rows: [
            row("MSync", msync),
            msyncDescription,
            row("ESync", esync),
            esyncDescription,
        ])
    }

    private func makeDisplayTab() -> NSTabViewItem {
        retina.target = self
        retina.action = #selector(markDirty)
        dpi.addItems(withTitles: ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"])
        dpi.target = self
        dpi.action = #selector(markDirty)
        return tab("顯示", rows: [
            row("高解析度（Retina Mode）", retina),
            row("縮放比例 / DPI", dpi),
            note("建議使用高解析度模式與 200%。\n125%、150%、175%、250% 等非整數倍率，可能讓部分老遊戲的像素邊緣出現鋸齒或模糊。"),
        ])
    }

    private func makeFontsTab() -> NSTabViewItem {
        font.addItems(withTitles: ["宋體（Songti TC，預設）", "細明體（MingLiU）"])
        font.target = self
        font.action = #selector(fontChanged)
        smoothing.addItems(withTitles: ["關閉", "灰階", "ClearType RGB", "ClearType BGR"])
        smoothing.target = self
        smoothing.action = #selector(markDirty)
        return tab("字體", rows: [
            row("Windows 預設字體", font),
            note("Cyder 只設定 Wine 的字體替代規則，不會自動安裝受授權保護的字型。"),
            row("字體平滑", smoothing),
        ])
    }

    private func tab(_ title: String, rows: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        item.view = container
        return item
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        let stack = NSStackView(views: [label, spacer, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.widthAnchor.constraint(equalToConstant: 530).isActive = true
        return stack
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return label
    }

    private func reload() {
        let value = store.value
        msync.state = value.msync ? .on : .off
        esync.state = (value.esync ?? false) && !value.msync ? .on : .off
        retina.state = value.retinaMode ? .on : .off
        let dpiValues = [96, 120, 144, 168, 192, 240]
        dpi.selectItem(at: dpiValues.firstIndex(of: value.dpi) ?? 4)
        font.selectItem(at: value.fontPreset == "mingliu" ? 1 : 0)
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        smoothing.selectItem(at: smoothingValues.firstIndex(of: value.fontSmoothing) ?? 1)
        isDirty = false
        status.stringValue = "設定將於確認後儲存"
        status.textColor = .secondaryLabelColor
    }

    func prepareForDisplay() {
        reload()
    }

    @objc private func markDirty() {
        isDirty = true
        status.stringValue = "有尚未儲存的變更"
        status.textColor = .systemOrange
    }

    @objc private func msyncChanged() {
        if msync.state == .on { esync.state = .off }
        markDirty()
    }

    @objc private func esyncChanged() {
        if esync.state == .on { msync.state = .off }
        markDirty()
    }

    private func saveControls() -> Bool {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        do {
            try store.update {
                $0.msync = msync.state == .on
                $0.esync = esync.state == .on
                $0.retinaMode = retina.state == .on
                $0.dpi = dpiValues[max(0, dpi.indexOfSelectedItem)]
                $0.fontPreset = font.indexOfSelectedItem == 1 ? "mingliu" : "songti"
                $0.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
            }
            status.stringValue = "已儲存；重新啟動遊戲後生效"
            status.textColor = .secondaryLabelColor
            isDirty = false
            return true
        } catch {
            status.stringValue = "無法儲存設定：\(error.localizedDescription)"
            status.textColor = .systemRed
            return false
        }
    }

    @objc private func fontChanged() {
        if font.indexOfSelectedItem == 1 {
            let alert = NSAlert()
            alert.messageText = "使用細明體前需要先安裝字型"
            alert.informativeText = "請先在 macOS「字體簿」安裝細明體，或將合法取得的 MingLiU 字型安裝到目前的 Wine 環境。Cyder 只切換字體設定，不會提供或自動安裝細明體。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "我知道了")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                font.selectItem(at: 0)
            }
        }
        markDirty()
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "恢復所有進階設定？"
        alert.informativeText = "這不會刪除遊戲所需元件、遊戲或個人檔案。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢復預設值")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = CyderSettings.defaults
        msync.state = value.msync ? .on : .off
        esync.state = (value.esync ?? false) ? .on : .off
        retina.state = value.retinaMode ? .on : .off
        dpi.selectItem(at: 4)
        font.selectItem(at: 0)
        smoothing.selectItem(at: 1)
        markDirty()
    }

    @objc private func confirmChanges() {
        let running = hasRunningExes?() ?? false
        var shouldStopAll = false
        if running {
            let alert = NSAlert()
            alert.messageText = "重新開啟遊戲後會套用新設定"
            alert.informativeText = "目前有遊戲正在執行。要立即關閉所有遊戲並套用設定，還是只儲存設定、稍後自行重新開啟？未儲存的遊戲進度可能會遺失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "儲存並關閉所有遊戲")
            alert.addButton(withTitle: "只儲存")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            guard response != .alertThirdButtonReturn else { return }
            shouldStopAll = response == .alertFirstButtonReturn
        }
        onSaveStarted?()
        guard saveControls() else {
            onSaveFailed?()
            return
        }
        onCommit?(shouldStopAll)
        close()
    }
}

final class CyderSetupPanel {
    private let window: NSWindow
    private let progress: NSProgressIndicator
    private let label: NSTextField
    private let detail: NSTextField

    init() {
        let width: CGFloat = 420
        let height: CGFloat = 150
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cyder"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .regular
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)

        label = NSTextField(labelWithString: "正在準備…")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        detail = NSTextField(labelWithString: "請稍候，完成後會自動關閉。")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(label)
        content.addSubview(progress)
        content.addSubview(detail)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            progress.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 14),
        ])
    }

    func setMessage(_ text: String) {
        label.stringValue = text
        window.displayIfNeeded()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.displayIfNeeded()
    }

    func close() {
        progress.stopAnimation(nil)
        window.orderOut(nil)
    }
}

private final class WineActivationWaiter {
    let prefix: String
    let semaphore = DispatchSemaphore(value: 0)

    init(prefix: String) {
        self.prefix = (prefix as NSString).standardizingPath
    }
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false
    private var setupPanel: CyderSetupPanel?
    private var terminateWhenSettingsClose = false
    private var environmentPreparationInProgress = false
    private var wineActivationWaiter: WineActivationWaiter?
    private lazy var settingsController: CyderSettingsWindowController = {
        let controller = CyderSettingsWindowController()
        controller.onCommit = { [weak self] shouldStopAll in
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
        controller.onClose = { [weak self] in
            guard let self, self.terminateWhenSettingsClose,
                  !self.environmentPreparationInProgress else { return }
            NSApp.terminate(nil)
        }
        return controller
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opening an EXE should not leave a Cyder Dock item behind.  The Wine
        // process owns the game windows and will become the regular frontmost
        // application after the native launcher activates it.  Settings mode
        // remains a normal AppKit application with a Dock item.
        NSApp.setActivationPolicy(hasDocumentArgument ? .prohibited : .regular)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        terminateWhenSettingsClose = false
        NSApp.setActivationPolicy(.prohibited)
        if settingsController.window?.isVisible == true {
            settingsController.close()
        }
        pendingFiles.append(contentsOf: filenames)
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
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasPrefix("-psn_") {
                continue
            }
            if arg == "--args" {
                continue
            }
            pendingFiles.append(arg)
        }
        if pendingFiles.isEmpty {
            terminateWhenSettingsClose = true
            showSettings()
        } else {
            scheduleRun()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private var hasDocumentArgument: Bool {
        CommandLine.arguments.dropFirst().contains { raw in
            let path = raw.replacingOccurrences(of: "file://", with: "")
            return path.lowercased().hasSuffix(".exe")
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Cyder")
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
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "結束 Cyder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        settingsController.prepareForDisplay()
        settingsController.showWindow(nil)
        settingsController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let status = runLauncher(context: context, args: [context.launcher, "--stop-all"])
        if status != 0 {
            showAlert("有些遊戲未能關閉", "請先手動關閉遊戲，再重新套用設定。")
        }
    }

    private func hasRunningExes() -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let context = CyderLaunchContext(resourcePath: resourcePath)
        return runLauncher(context: context, args: [context.launcher, "--has-running-exes"]) == 0
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
            let status = self.ensureEnvironment(context: context)
            var settingsStatus = status
            if status == 0 {
                self.showSetup("正在套用新設定…")
                settingsStatus = self.runLauncher(context: context, args: [
                    context.launcher, "--apply-settings-only",
                ])
            }
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if settingsStatus == 0 {
                    self.showAlert(
                        "設定完成",
                        "新設定已儲存，下次開啟遊戲時會自動使用。",
                        style: .informational
                    )
                } else if status == 0 {
                    self.showAlert("設定未完成", "套用設定時發生問題。請重新開啟 Cyder 再試一次。")
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
        NSApp.setActivationPolicy(.prohibited)

        guard let resourcePath = Bundle.main.resourcePath else {
            fputs("Cyder: missing Resources path\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let context = CyderLaunchContext(resourcePath: resourcePath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let status = self.runPhasedLaunch(context: context)
            DispatchQueue.main.async {
                self.hideSetup()
                if status == 2 {
                    self.showAlert(
                        "遊戲尚未準備完成",
                        "請先單獨開啟 Cyder.app，按「確認」完成首次準備，再重新開啟遊戲。"
                    )
                }
                NSApp.terminate(nil)
                exit(status)
            }
        }
    }

    private func environmentState(context: CyderLaunchContext) -> (needsEngine: Bool, needsBootstrap: Bool) {
        let engineWine = CyderPaths.engine.appendingPathComponent("bin/wine")

        let unsafeEnginePath = CyderPaths.engine.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let needsEngine = unsafeEnginePath
            || !FileManager.default.isExecutableFile(atPath: engineWine.path)
            || engineNeedsInstall(context: context, engineWine: engineWine)
        let needsBootstrap = !FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path)
        return (needsEngine, needsBootstrap)
    }

    private func ensureEnvironment(context: CyderLaunchContext) -> Int32 {
        let state = environmentState(context: context)

        if state.needsEngine {
            showSetup("正在準備遊戲執行元件…")
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--ensure-engine-only",
            ])
            if code != 0 {
                showAlert(
                    "無法完成遊戲準備",
                    "準備遊戲所需元件時發生問題。請重新開啟 Cyder 再試一次。"
                )
                return code
            }
        }

        // Engine installation can create/replace the engine tree. Recompute
        // the marker decision after that operation so first-run setup cannot
        // be deferred to the next Cyder launch.
        let bootstrapNeeded = state.needsEngine
            || state.needsBootstrap
            || environmentState(context: context).needsBootstrap
        if bootstrapNeeded {
            showSetup("正在準備遊戲環境…")
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only",
            ])
            if code != 0 {
                showAlert(
                    "無法完成遊戲準備",
                    "準備遊戲環境時發生問題。請重新開啟 Cyder 再試一次。"
                )
                return code
            }
        }
        return 0
    }

    private func runPhasedLaunch(context: CyderLaunchContext) -> Int32 {
        var exePaths = normalizeExePaths(pendingFiles)
        if exePaths.isEmpty {
            hideSetup()
            guard let chosen = chooseExeOnMainThread() else {
                return 1
            }
            exePaths = [chosen]
        }

        // Direct EXE launches intentionally do not install or bootstrap the
        // environment.  That work is completed by the settings flow first.
        let state = environmentState(context: context)
        guard !state.needsEngine, !state.needsBootstrap else {
            return 2
        }

        let wine = CyderPaths.engine.appendingPathComponent("bin/wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            return 2
        }
        return runDirectWine(wine: wine, exe: exePaths[0])
    }

    /// Launch Wine directly through Apple's architecture selector, then wait
    /// for CrossOver Wine to publish the actual foreground application PID in
    /// WineAppWillActivateNotification.  The wrapper Process PID is not used
    /// for activation. Wine continues independently after Cyder exits.
    private func runDirectWine(wine: URL, exe: String) -> Int32 {
        let support = CyderPaths.support
        let logDirectory = support.appendingPathComponent("Logs", isDirectory: true)
        let prefix = CyderPaths.sharedBottle.path
        let activationWaiter = WineActivationWaiter(prefix: prefix)
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
            fputs("Cyder: unable to create log directory: \(error)\n", stderr)
            return 1
        }

        let launchLog = logDirectory.appendingPathComponent("last-launch.log")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", wine.path, exe]
        process.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        process.environment = wineEnvironment(wine: wine, support: support)

        let command = "arch -x86_64 \(wine.path) \(exe)\n"
        FileManager.default.createFile(atPath: launchLog.path, contents: command.data(using: .utf8))
        if let handle = FileHandle(forWritingAtPath: launchLog.path) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            fputs("Cyder: failed to run Wine: \(error)\n", stderr)
            return 1
        }

        // The distributed notification is normally posted as soon as Wine's
        // first activatable Cocoa window is ready. Keep this hidden launcher
        // alive only long enough to receive that exact foreground PID.
        _ = activationWaiter.semaphore.wait(timeout: .now() + 30)
        return 0
    }

    private func wineEnvironment(wine: URL, support: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in CyderSettingsStore.shared.environment {
            environment[key] = value
        }

        let engineRoot = wine.deletingLastPathComponent().deletingLastPathComponent()
        let prefix = CyderPaths.sharedBottle.path
        environment["WINEPREFIX"] = prefix
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
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            alert.runModal()
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

    private func runLauncher(context: CyderLaunchContext, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = args
        var environment = context.environment
        for (key, value) in CyderSettingsStore.shared.environment {
            environment[key] = value
        }
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("Cyder: failed to run launcher: \(error)\n", stderr)
            return 1
        }
    }
}

private struct CyderLaunchContext {
    let launcher: String
    let engineSrc: String
    let engineVersionFile: String
    let environment: [String: String]

    init(resourcePath: String) {
        let entitlements = resourcePath + "/entitlements.plist"
        let libarchive = resourcePath + "/addons/libarchive"
        let contentsPath = (resourcePath as NSString).deletingLastPathComponent
        let appPath = (contentsPath as NSString).deletingLastPathComponent
        let engineSrc = resolveEngineSrc(resourcePath: resourcePath)

        launcher = resourcePath + "/ogom-scripts/cyder_launcher.sh"
        self.engineSrc = engineSrc
        engineVersionFile = resourcePath + "/engine-version.txt"

        var env = ProcessInfo.processInfo.environment
        env["CYDER_ENGINE_SRC"] = engineSrc
        env["CYDER_SCRIPTS"] = resourcePath + "/ogom-scripts"
        env["CYDER_LIBARCHIVE_SRC"] = libarchive
        env["CYDER_GUI"] = "1"
        env["OGOM"] = resourcePath
        env["WINE_INSTALL"] = engineSrc
        env["ENTITLEMENTS_PLIST"] = entitlements
        env["CYDER_ENTITLEMENTS"] = entitlements
        env["CYDER_APP"] = appPath
        env["CYDER_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? "local.cyder.app"
        environment = env
    }
}

private func resolveEngineSrc(resourcePath: String) -> String {
    let archiveListFile = resourcePath + "/engine-archive.txt"
    if let archiveName = try? String(contentsOfFile: archiveListFile, encoding: .utf8) {
        let trimmedArchive = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArchive.isEmpty {
            let archivePath = resourcePath + "/" + trimmedArchive
            if FileManager.default.fileExists(atPath: archivePath) {
                return archivePath
            }
        }
    }
    let versionFile = resourcePath + "/engine-version.txt"
    if let ver = try? String(contentsOfFile: versionFile, encoding: .utf8) {
        let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let zst = resourcePath + "/engine-\(trimmed).tar.zst"
            if FileManager.default.fileExists(atPath: zst) {
                return zst
            }
            let xz = resourcePath + "/engine-wine-x86_64-\(trimmed).tar.xz"
            if FileManager.default.fileExists(atPath: xz) {
                return xz
            }
        }
    }
    return resourcePath + "/engine-payload"
}

private func normalizeExePaths(_ paths: [String]) -> [String] {
    var out: [String] = []
    for raw in paths {
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.isEmpty {
            continue
        }
        if path.lowercased().hasSuffix(".exe") {
            out.append(path)
        }
    }
    return out
}

private func resolvedWineLocale(environment: [String: String]) -> String {
    for key in ["LC_ALL", "LANG"] {
        if let value = environment[key],
           !value.isEmpty,
           value != "C",
           value != "POSIX",
           value != "C.UTF-8" {
            return value
        }
    }

    let identifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
    let lower = identifier.lowercased()
    if lower.hasPrefix("zh_hant_tw") || lower == "zh_tw" {
        return "zh_TW.UTF-8"
    }
    if lower.hasPrefix("zh_hant_hk") || lower == "zh_hk" {
        return "zh_HK.UTF-8"
    }
    if lower.hasPrefix("zh_hans") || lower == "zh_cn" {
        return "zh_CN.UTF-8"
    }
    if lower.hasPrefix("ja") {
        return "ja_JP.UTF-8"
    }
    if lower.hasPrefix("ko") {
        return "ko_KR.UTF-8"
    }
    return identifier.contains(".") ? identifier : "\(identifier).UTF-8"
}

let app = NSApplication.shared
let delegate = CyderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
