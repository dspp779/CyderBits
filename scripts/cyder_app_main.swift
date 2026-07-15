// Cyder.app entry — phased setup UI, then launch Windows EXE directly with Wine.
import Cocoa
import Foundation
import UniformTypeIdentifiers

private final class CyderSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onCommit: ((_ shouldStopAll: Bool, _ requiresPrefixApply: Bool) -> Void)?
    var onRebuild: (() -> Void)?
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
    private let executableList = NSPopUpButton()
    private let executableRecommendation = NSPopUpButton()
    private let executableName = NSTextField(labelWithString: "尚未選擇 EXE")
    private let executableMsync = NSSwitch()
    private let executableEsync = NSSwitch()
    private let executableRetina = NSSwitch()
    private let executableDpi = NSPopUpButton()
    private let executablePowerMode = NSPopUpButton()
    private let removeExecutableButton = NSButton()
    private var selectedExecutable: String?
    private var executableDrafts: [String: CyderExecutableSettings] = [:]
    private var deletedExecutables: Set<String> = []
    private let status = NSTextField(labelWithString: "設定將於下次啟動遊戲時生效")
    private var isDirty = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Cyder 偏好設定"
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
        tabs.addTabViewItem(makeExecutableTab())
        tabs.addTabViewItem(makeAdvancedTab())

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

    private func makeExecutableTab() -> NSTabViewItem {
        let choose = NSButton(title: "選擇新的 EXE…", target: self, action: #selector(chooseExecutable))
        choose.bezelStyle = .rounded
        removeExecutableButton.title = "移除設定"
        removeExecutableButton.target = self
        removeExecutableButton.action = #selector(removeExecutableSettings)
        removeExecutableButton.bezelStyle = .rounded
        executableList.target = self
        executableList.action = #selector(selectConfiguredExecutable)
        executableList.widthAnchor.constraint(equalToConstant: 280).isActive = true
        executableRecommendation.addItems(withTitles: [
            "自行設定",
            "世紀帝國 II（關閉 Retina）",
            "越南大戰（96 DPI）",
            "皮卡丘打排球（關閉同步）",
            "水藍魔力／BlueCG（Retina、192 DPI）",
        ])
        executableRecommendation.target = self
        executableRecommendation.action = #selector(applyExecutableRecommendation)
        executableDpi.addItems(withTitles: ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"])
        executablePowerMode.addItems(withTitles: ["標準", "省電"])
        executableName.textColor = .secondaryLabelColor
        executableName.lineBreakMode = .byTruncatingMiddle
        executableName.widthAnchor.constraint(equalToConstant: 580).isActive = true
        [executableMsync, executableEsync, executableRetina].forEach {
            $0.target = self
            $0.action = #selector(executableSettingChanged)
        }
        executableMsync.action = #selector(executableMsyncChanged)
        executableEsync.action = #selector(executableEsyncChanged)
        executableDpi.target = self
        executableDpi.action = #selector(executableSettingChanged)
        executablePowerMode.target = self
        executablePowerMode.action = #selector(executableSettingChanged)
        let actions = NSStackView(views: [choose, removeExecutableButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        return tab("遊戲設定", rows: [
            row("已設定遊戲", executableList),
            actions,
            executableName,
            row("建議設定", executableRecommendation),
            note("目前以 EXE 檔名比對設定；同名 EXE 會使用相同設定。選擇建議設定後仍可逐項調整。"),
            row("MSync", executableMsync),
            row("ESync", executableEsync),
            row("Retina Mode", executableRetina),
            row("縮放比例 / DPI", executableDpi),
            row("能源模式", executablePowerMode),
            note("省電模式可以降低 CPU 使用率，但可能造成畫面卡頓。\n\nApple 晶片會優先使用節能核心，可大幅延長續航；BlueCG 測試中，能耗約為標準模式的 1/10。\n注意：M1 Pro/Max 僅有 2 個節能核心，可能極度卡頓，不建議使用。"),
        ])
    }

    private func makeAdvancedTab() -> NSTabViewItem {
        let rebuild = NSButton(title: "重建 Windows 遊戲環境…", target: self, action: #selector(rebuildEnvironment))
        rebuild.bezelStyle = .rounded
        return tab("進階", rows: [
            rebuild,
            note("重新建立執行 Windows 遊戲所需的環境。遊戲檔案不會刪除，但已安裝的 Windows 元件與自訂設定需要重新套用。"),
        ])
    }

    private func tab(_ title: String, rows: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
        stack.widthAnchor.constraint(equalToConstant: 590).isActive = true
        return stack
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 7
        label.widthAnchor.constraint(equalToConstant: 580).isActive = true
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
        executableDrafts = value.perExecutable
        deletedExecutables.removeAll()
        selectedExecutable = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
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
                for basename in deletedExecutables {
                    $0.perExecutable.removeValue(forKey: basename)
                }
                for (basename, rule) in executableDrafts where !deletedExecutables.contains(basename) {
                    $0.perExecutable[basename] = rule
                }
            }
            status.stringValue = "已儲存；重新啟動遊戲後生效"
            status.textColor = .secondaryLabelColor
            isDirty = false
            return true
        } catch {
            CyderDiagnostics.shared.warning("unable to save settings error=\(error)")
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

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "選擇要套用個別設定的 EXE"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let basename = url.lastPathComponent.lowercased()
        if executableDrafts[basename] == nil {
            executableDrafts[basename] = defaultExecutableSettings()
        }
        deletedExecutables.remove(basename)
        selectedExecutable = basename
        refreshExecutableList(selecting: basename)
        loadExecutableSettings(basename, displayName: "\(url.lastPathComponent)（\(url.path)）")
        markDirty()
    }

    @objc private func selectConfiguredExecutable() {
        guard executableList.isEnabled,
              let basename = executableList.selectedItem?.title,
              executableDrafts[basename] != nil else { return }
        loadExecutableSettings(basename)
    }

    @objc private func removeExecutableSettings() {
        guard let basename = selectedExecutable else { return }
        let alert = NSAlert()
        alert.messageText = "移除 \(basename) 的遊戲設定？"
        alert.informativeText = "確認儲存後，這個 EXE 將改用一般設定。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        executableDrafts.removeValue(forKey: basename)
        deletedExecutables.insert(basename)
        selectedExecutable = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        markDirty()
    }

    @objc private func executableSettingChanged() {
        executableRecommendation.selectItem(at: 0)
        captureExecutableSettings()
        markDirty()
    }

    @objc private func executableMsyncChanged() {
        if executableMsync.state == .on { executableEsync.state = .off }
        executableSettingChanged()
    }

    @objc private func executableEsyncChanged() {
        if executableEsync.state == .on { executableMsync.state = .off }
        executableSettingChanged()
    }

    @objc private func applyExecutableRecommendation() {
        guard let basename = selectedExecutable else {
            executableRecommendation.selectItem(at: 0)
            return
        }
        let recommendation = executableRecommendation.indexOfSelectedItem
        var rule = defaultExecutableSettings()
        switch recommendation {
        case 1:
            rule.retinaMode = false
        case 2:
            rule.dpi = 96
        case 3:
            rule.msync = false
            rule.esync = false
        case 4:
            rule.retinaMode = true
            rule.dpi = 192
        default:
            return
        }
        executableDrafts[basename] = rule
        loadExecutableSettings(basename)
        executableRecommendation.selectItem(at: recommendation)
        markDirty()
    }

    private func defaultExecutableSettings() -> CyderExecutableSettings {
        let value = store.value
        var rule = CyderExecutableSettings()
        rule.msync = value.msync
        rule.esync = value.esync ?? false
        rule.retinaMode = value.retinaMode
        rule.dpi = value.dpi
        rule.powerMode = "standard"
        return rule
    }

    private func captureExecutableSettings() {
        guard let basename = selectedExecutable else { return }
        let dpiValues = [96, 120, 144, 168, 192, 240]
        var rule = executableDrafts[basename] ?? defaultExecutableSettings()
        rule.msync = executableMsync.state == .on
        rule.esync = executableEsync.state == .on
        rule.retinaMode = executableRetina.state == .on
        rule.dpi = dpiValues[max(0, executableDpi.indexOfSelectedItem)]
        rule.powerMode = ["standard", "energySaving"][max(0, executablePowerMode.indexOfSelectedItem)]
        executableDrafts[basename] = rule
        deletedExecutables.remove(basename)
    }

    private func loadExecutableSettings(_ basename: String, displayName: String? = nil) {
        guard let rule = executableDrafts[basename] else { return }
        let defaults = defaultExecutableSettings()
        let dpiValues = [96, 120, 144, 168, 192, 240]
        selectedExecutable = basename
        executableList.selectItem(withTitle: basename)
        executableName.stringValue = displayName ?? basename
        executableMsync.state = (rule.msync ?? defaults.msync ?? false) ? .on : .off
        executableEsync.state = (rule.esync ?? defaults.esync ?? false) ? .on : .off
        executableRetina.state = (rule.retinaMode ?? defaults.retinaMode ?? true) ? .on : .off
        executableDpi.selectItem(at: dpiValues.firstIndex(of: rule.dpi ?? defaults.dpi ?? 192) ?? 4)
        executablePowerMode.selectItem(at: rule.powerMode == "energySaving" ? 1 : 0)
        executableRecommendation.selectItem(at: 0)
        setExecutableControlsEnabled(true)
    }

    private func refreshExecutableList(selecting preferred: String? = nil) {
        executableList.removeAllItems()
        let names = executableDrafts.keys
            .filter { !deletedExecutables.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else {
            executableList.addItem(withTitle: "尚無已設定遊戲")
            executableList.isEnabled = false
            setExecutableControlsEnabled(false)
            return
        }
        executableList.addItems(withTitles: names)
        executableList.isEnabled = true
        let selected = preferred.flatMap { names.contains($0) ? $0 : nil } ?? names[0]
        loadExecutableSettings(selected)
    }

    private func setExecutableControlsEnabled(_ enabled: Bool) {
        executableRecommendation.isEnabled = enabled
        executableMsync.isEnabled = enabled
        executableEsync.isEnabled = enabled
        executableRetina.isEnabled = enabled
        executableDpi.isEnabled = enabled
        executablePowerMode.isEnabled = enabled
        removeExecutableButton.isEnabled = enabled
        if !enabled {
            executableMsync.state = .off
            executableEsync.state = .off
            executableRetina.state = .off
            executableDpi.selectItem(at: 4)
            executablePowerMode.selectItem(at: 0)
            executableRecommendation.selectItem(at: 0)
        }
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
        deletedExecutables.formUnion(executableDrafts.keys)
        executableDrafts.removeAll()
        selectedExecutable = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        markDirty()
    }

    @objc private func rebuildEnvironment() {
        let alert = NSAlert()
        alert.messageText = "重建 Windows 遊戲環境？"
        alert.informativeText = "遊戲檔案不會刪除，但已安裝的 Windows 元件與自訂設定需要重新套用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRebuild?()
        close()
    }

    @objc private func confirmChanges() {
        // Opening Cyder only to inspect settings should be a no-op: do not
        // rewrite the settings file or invoke the Wine launcher.
        guard isDirty else {
            close()
            return
        }
        // Only registry-backed display/font fields need Wine to be invoked
        // immediately. Launch policy, sync and per-EXE fields are consumed on
        // the next launch and should not trigger another environment check.
        let requiresPrefixApply = prefixSettingsChanged()
        let requiresSessionRestart = sessionSettingsChanged()
        let running = (requiresPrefixApply || requiresSessionRestart) && (hasRunningExes?() ?? false)
        var shouldStopAll = false
        if running && requiresPrefixApply {
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
        } else if running && requiresSessionRestart {
            let alert = NSAlert()
            alert.messageText = "關閉所有遊戲後會使用新的執行模式"
            alert.informativeText = "能源模式與同步設定由目前的 Windows 遊戲環境共用。這次只會儲存變更；請關閉所有遊戲後再重新開啟。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "只儲存")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if requiresPrefixApply {
            onSaveStarted?()
        }
        guard saveControls() else {
            onSaveFailed?()
            return
        }
        onCommit?(shouldStopAll, requiresPrefixApply)
        close()
    }

    private func prefixSettingsChanged() -> Bool {
        let value = store.value
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        return value.retinaMode != (retina.state == .on)
            || value.dpi != dpiValues[max(0, dpi.indexOfSelectedItem)]
            || value.fontPreset != (font.indexOfSelectedItem == 1 ? "mingliu" : "songti")
            || value.fontSmoothing != smoothingValues[max(0, smoothing.indexOfSelectedItem)]
    }

    private func sessionSettingsChanged() -> Bool {
        let value = store.value
        if value.msync != (msync.state == .on)
            || (value.esync ?? false) != (esync.state == .on) {
            return true
        }
        for basename in deletedExecutables {
            if value.perExecutable[basename] != nil { return true }
        }
        for (basename, rule) in executableDrafts {
            let stored = value.perExecutable[basename]
            if stored?.msync != rule.msync
                || stored?.esync != rule.esync
                || stored?.powerMode != rule.powerMode {
                return true
            }
        }
        return false
    }
}

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
    private var setupPanel: CyderSetupPanel?
    private var terminateWhenSettingsClose = false
    private var environmentPreparationInProgress = false
    private var wineActivationWaiter: WineActivationWaiter?
    private lazy var settingsController: CyderSettingsWindowController = {
        let controller = CyderSettingsWindowController()
        controller.onCommit = { [weak self] shouldStopAll, requiresPrefixApply in
            if requiresPrefixApply {
                self?.prepareEnvironmentAfterSettings(stopAll: shouldStopAll)
            }
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
        controller.onClose = { [weak self] in
            guard let self, self.terminateWhenSettingsClose,
                  !self.environmentPreparationInProgress else { return }
            NSApp.terminate(nil)
        }
        return controller
    }()

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
        CyderDiagnostics.shared.enter(.appStart, detail: hasDocumentArgument ? "finder-exe" : "settings")
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(wineAppWillActivate(_:)),
            name: Notification.Name("WineAppWillActivateNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        installMainMenu()
        didFinishLaunch = true
        if ProcessInfo.processInfo.environment["CYDER_DIAGNOSTICS_SELF_TEST"] == "1" {
            CyderDiagnostics.shared.enter(.resourceValidation, detail: "self-test")
            CyderDiagnostics.shared.finish(outcome: "diagnostics-self-test")
            NSApp.terminate(nil)
            return
        }
        showPreviousCrashIfNeeded()
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
            prepareEnvironmentAndShowSettings()
        } else {
            scheduleRun()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        CyderDiagnostics.shared.finish(outcome: "terminated")
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
                operation: "apply-settings"
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
        NSApp.setActivationPolicy(.prohibited)

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
                        "請先單獨開啟 Cyder.app，按「確認」完成首次準備，再重新開啟遊戲。"
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
        let needsBootstrap = !FileManager.default.fileExists(atPath: CyderPaths.bootstrapMarker.path)
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
        let bootstrapNeeded = state.needsEngine
            || state.needsBootstrap
            || environmentState(context: context).needsBootstrap
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
                self.showSettings()
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
        let basename = URL(fileURLWithPath: exePaths[0]).lastPathComponent.lowercased()
        if CyderSettingsStore.shared.hasSettings(forExecutable: basename) {
            if hasRunningExes() {
                return .failure(CyderFailure(
                    code: "CYD-GAM-001",
                    stage: .settingsApply,
                    summary: "無法切換這個遊戲的個別設定。",
                    technicalDetails: "The shared Windows game environment is already in use. Close all Cyder games before launching an EXE with per-game settings.",
                    logURL: CyderDiagnostics.shared.sessionLogURL
                ))
            }
            showSetup("正在套用遊戲設定…")
            var launchSettings = CyderSettingsStore.shared.environment(forExecutable: basename)
            launchSettings["CYDER_STOP_WINESERVER_AFTER_SETTINGS"] = "1"
            let applied = runLauncher(
                context: context,
                args: [context.launcher, "--apply-settings-only"],
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
        return runDirectWine(wine: wine, exe: exePaths[0])
    }

    /// Launch Wine directly through Apple's architecture selector, then wait
    /// for CrossOver Wine to publish the actual foreground application PID in
    /// WineAppWillActivateNotification.  The wrapper Process PID is not used
    /// for activation. Wine continues independently after Cyder exits.
    private func runDirectWine(wine: URL, exe: String) -> CyderLaunchOutcome {
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
        let environment = wineEnvironment(wine: wine, support: support, exe: exe)
        let basename = URL(fileURLWithPath: exe).lastPathComponent.lowercased()
        let gameArguments = CyderSettingsStore.shared.arguments(forExecutable: basename)
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
            "cmd=\(commandDescription)\npower_mode=\(powerMode)\ntaskpolicy_available=\(hasTaskpolicy)\nWINEPREFIX=\(prefix)\ncwd=\((exe as NSString).deletingLastPathComponent)\n\n"
        )
        try? handle.write(contentsOf: Data(command.utf8))
        process.standardOutput = handle
        process.standardError = handle

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

    private func wineEnvironment(wine: URL, support: URL, exe: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let basename = URL(fileURLWithPath: exe).lastPathComponent.lowercased()
        for (key, value) in CyderSettingsStore.shared.environment(forExecutable: basename) {
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
            // Finder launches begin as an accessory app. Promote Cyder before
            // presenting any modal alert so warnings cannot appear invisibly.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            alert.runModal()
        }
    }

    private func showPreviousCrashIfNeeded() {
        guard let previous = CyderDiagnostics.shared.previousUnexpectedSession else { return }
        onMainThread {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Cyder 上次未正常結束"
            alert.informativeText = "上次執行在「\(previous.stage)」階段中斷。已保留診斷記錄，您可以繼續使用 Cyder。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "繼續")
            alert.addButton(withTitle: "開啟上次記錄")
            let response = alert.runModal()
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
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
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
            let response = alert.runModal()
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
        extraEnvironment: [String: String] = [:]
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
            CyderDiagnostics.shared.info(
                "operation=\(operation) status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) log=\(operationLog.path)"
            )
            return CyderProcessResult(
                status: process.terminationStatus,
                terminationReason: process.terminationReason,
                logURL: operationLog,
                outputTail: tail
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
