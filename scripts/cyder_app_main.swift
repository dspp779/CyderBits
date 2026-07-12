// Cyder.app entry — phased setup UI, then launch Windows EXE via cyder_launcher.sh.
import Cocoa
import Foundation
import UniformTypeIdentifiers

private struct CyderSettings: Codable {
    var schemaVersion = 1
    var msync = false
    var disableMshtml: Bool? = false
    var retinaMode = false
    var dpi = 96
    var fontPreset = "songti"
    var fontSmoothing = "cleartype-rgb"

    static let defaults = CyderSettings()
}

private final class CyderSettingsStore {
    static let shared = CyderSettingsStore()
    private(set) var value: CyderSettings
    private let url: URL

    private init() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
        url = support.appendingPathComponent("settings.json")
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
            "CYDER_DISABLE_MSHTML": (value.disableMshtml ?? false) ? "1" : "0",
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
    var onClose: (() -> Void)?
    var hasRunningExes: (() -> Bool)?
    private let store = CyderSettingsStore.shared
    private let msync = NSSwitch()
    private let disableMshtml = NSSwitch()
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
        msync.action = #selector(markDirty)
        disableMshtml.target = self
        disableMshtml.action = #selector(markDirty)
        let description = note("通常可改善效能與執行緒同步；若遊戲凍結或無法啟動，可嘗試關閉。")
        let mshtmlDescription = note("停用後可避免 Wine Gecko／HTML 元件提示，但需要內嵌網頁的啟動器可能無法顯示內容。")
        return tab("一般", rows: [
            row("MSync", msync),
            description,
            row("停用 MSHTML", disableMshtml),
            mshtmlDescription,
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
            note("建議使用 Retina Mode + 200%。只調高 DPI 可能使部分舊遊戲出現黑邊。"),
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
            row("字體反鋸齒平滑", smoothing),
        ])
    }

    private func tab(_ title: String, rows: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 22, bottom: 20, right: 22)
        item.view = stack
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
        disableMshtml.state = (value.disableMshtml ?? false) ? .on : .off
        retina.state = value.retinaMode ? .on : .off
        let dpiValues = [96, 120, 144, 168, 192, 240]
        dpi.selectItem(at: dpiValues.firstIndex(of: value.dpi) ?? 4)
        font.selectItem(at: value.fontPreset == "mingliu" ? 1 : 0)
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        smoothing.selectItem(at: smoothingValues.firstIndex(of: value.fontSmoothing) ?? 2)
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

    private func saveControls() -> Bool {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        do {
            try store.update {
                $0.msync = msync.state == .on
                $0.disableMshtml = disableMshtml.state == .on
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
        alert.informativeText = "這不會刪除 Wine 引擎、遊戲或個人檔案。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢復預設值")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = CyderSettings.defaults
        msync.state = value.msync ? .on : .off
        disableMshtml.state = (value.disableMshtml ?? false) ? .on : .off
        retina.state = value.retinaMode ? .on : .off
        dpi.selectItem(at: 0)
        font.selectItem(at: 0)
        smoothing.selectItem(at: 2)
        markDirty()
    }

    @objc private func confirmChanges() {
        let running = hasRunningExes?() ?? false
        let alert = NSAlert()
        alert.messageText = "EXE 重新開啟後設定才會生效"
        if running {
            alert.informativeText = "偵測到由 Cyder 執行的 EXE。是否儲存設定並關閉所有 EXE？未儲存的遊戲進度可能會遺失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "儲存並關閉所有 EXE")
            alert.addButton(withTitle: "僅儲存")
            alert.addButton(withTitle: "取消")
        } else {
            alert.informativeText = "目前沒有偵測到執行中的 Cyder EXE。確定儲存設定嗎？"
            alert.addButton(withTitle: "儲存")
            alert.addButton(withTitle: "取消")
        }
        let response = alert.runModal()
        if running {
            guard response != .alertThirdButtonReturn else { return }
        } else {
            guard response == .alertFirstButtonReturn else { return }
        }
        guard saveControls() else { return }
        onCommit?(running && response == .alertFirstButtonReturn)
        close()
    }
}

final class CyderSetupPanel {
    private let window: NSWindow
    private let spinner: NSProgressIndicator
    private let label: NSTextField

    init() {
        let width: CGFloat = 360
        let height: CGFloat = 120
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

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        label = NSTextField(labelWithString: "正在準備…")
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(spinner)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
        ])
    }

    func setMessage(_ text: String) {
        label.stringValue = text
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        spinner.stopAnimation(nil)
        window.orderOut(nil)
    }
}

final class CyderAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []
    private var didFinishLaunch = false
    private var didRunLauncher = false
    private var setupPanel: CyderSetupPanel?
    private var terminateWhenSettingsClose = false
    private var environmentPreparationInProgress = false
    private lazy var settingsController: CyderSettingsWindowController = {
        let controller = CyderSettingsWindowController()
        controller.onCommit = { [weak self] shouldStopAll in
            self?.prepareEnvironmentAfterSettings(stopAll: shouldStopAll)
        }
        controller.hasRunningExes = { [weak self] in self?.hasRunningExes() ?? false }
        controller.onClose = { [weak self] in
            guard let self, self.terminateWhenSettingsClose,
                  !self.environmentPreparationInProgress else { return }
            NSApp.terminate(nil)
        }
        return controller
    }()

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        terminateWhenSettingsClose = false
        if settingsController.window?.isVisible == true {
            settingsController.close()
        }
        pendingFiles.append(contentsOf: filenames)
        scheduleRun()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            showAlert("無法關閉所有 EXE", "請手動關閉遊戲後再重新開啟。")
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
        environmentPreparationInProgress = true
        let context = CyderLaunchContext(resourcePath: resourcePath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if stopAll { self.stopAllExes() }
            let status = self.ensureEnvironment(context: context)
            DispatchQueue.main.async {
                self.hideSetup()
                self.environmentPreparationInProgress = false
                if status == 0 {
                    self.showAlert("Cyder 已準備完成", "設定已儲存，遊戲引擎與 Windows 環境均可使用。")
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

        guard let resourcePath = Bundle.main.resourcePath else {
            fputs("Cyder: missing Resources path\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let context = CyderLaunchContext(resourcePath: resourcePath)
        guard FileManager.default.isExecutableFile(atPath: context.launcher) else {
            fputs("Cyder: missing launcher at \(context.launcher)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let status = self.runPhasedLaunch(context: context)
            DispatchQueue.main.async {
                self.hideSetup()
                NSApp.terminate(nil)
                exit(status)
            }
        }
    }

    private func environmentState(context: CyderLaunchContext) -> (needsEngine: Bool, needsBootstrap: Bool) {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
        let engineWine = support
            .appendingPathComponent("Engines/wine-x86_64/bin/wine")
        let bootstrapMarker = support
            .appendingPathComponent("SharedPrefix/.cyder-bootstrap-v1")

        let needsEngine = !FileManager.default.isExecutableFile(atPath: engineWine.path)
            || engineNeedsInstall(context: context, engineWine: engineWine)
        let needsBootstrap = !FileManager.default.fileExists(atPath: bootstrapMarker.path)
        return (needsEngine, needsBootstrap)
    }

    private func ensureEnvironment(context: CyderLaunchContext) -> Int32 {
        let state = environmentState(context: context)

        if state.needsEngine {
            showSetup("建立遊戲引擎中…")
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--ensure-engine-only",
            ])
            if code != 0 {
                showAlert(
                    "Cyder 無法安裝遊戲引擎",
                    "請查看 ~/Library/Application Support/Cyder/Logs/engine-install.log"
                )
                return code
            }
        }

        if state.needsBootstrap {
            showSetup("準備 Windows 環境中…")
            let code = runLauncher(context: context, args: [
                context.launcher, "--engine-src", context.engineSrc, "--bootstrap-only",
            ])
            if code != 0 {
                showAlert(
                    "Cyder 初始化失敗",
                    "請查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log"
                )
                return code
            }
        }
        return 0
    }

    private func runPhasedLaunch(context: CyderLaunchContext) -> Int32 {
        let state = environmentState(context: context)
        if state.needsEngine || state.needsBootstrap {
            showAlert(
                "Cyder 環境尚未完成",
                "請先單獨開啟 Cyder.app、儲存設定並完成遊戲引擎與 Windows 環境建置，再重新開啟此 EXE。"
            )
            return 2
        }

        var exePaths = normalizeExePaths(pendingFiles)
        if exePaths.isEmpty {
            hideSetup()
            guard let chosen = chooseExeOnMainThread() else {
                return 1
            }
            exePaths = [chosen]
        }

        let args = [context.launcher, "--engine-src", context.engineSrc, "--launch-exe", exePaths[0]]
        return runLauncher(context: context, args: args)
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

    private func showAlert(_ title: String, _ message: String) {
        onMainThread {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
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

let app = NSApplication.shared
let delegate = CyderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
