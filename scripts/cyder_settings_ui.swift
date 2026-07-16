import Cocoa
import Foundation

final class CyderSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onImmediateSave: ((_ registrySetting: String) -> Bool)?
    var onApplyAll: ((_ shouldStopAll: Bool) -> Void)?
    var onRebuild: (() -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onOpenGameLibrary: (() -> Void)?
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
    private let executableFont = NSPopUpButton()
    private let executableSmoothing = NSPopUpButton()
    private let executableEnvironment = NSTextField()
    private let executableArguments = NSTextField()
    private let removeExecutableButton = NSButton()
    private let profileStore = CyderProfileStore(root: CyderPaths.support)
    private var profileRecords: [String: CyderProfileRecord] = [:]
    private var selectedProfileID: String?
    private var profileDrafts: [String: CyderExecutableSettings] = [:]
    private var deletedProfiles: Set<String> = []
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
        true
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(makeGeneralTab())
        tabs.addTabViewItem(makeDisplayTab())
        tabs.addTabViewItem(makeFontsTab())
        tabs.addTabViewItem(makeAdvancedTab())

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "全部恢復預設值…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        content.addSubview(status)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reset.centerYAnchor.constraint(equalTo: status.centerYAnchor),
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

    @objc private func openGameLibrary() {
        onOpenGameLibrary?()
    }

    private func makeDisplayTab() -> NSTabViewItem {
        retina.target = self
        retina.action = #selector(retinaChanged)
        dpi.addItems(withTitles: ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"])
        dpi.target = self
        dpi.action = #selector(dpiChanged)
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
        smoothing.action = #selector(smoothingChanged)
        return tab("字體", rows: [
            row("Windows 預設字體", font),
            note("Cyder 只設定 Wine 的字體替代規則，不會自動安裝受授權保護的字型。"),
            row("字體平滑", smoothing),
        ])
    }

    private func makeAdvancedTab() -> NSTabViewItem {
        let rebuild = NSButton(title: "重建 Windows 遊戲環境…", target: self, action: #selector(rebuildEnvironment))
        rebuild.bezelStyle = .rounded
        let applyAll = NSButton(title: "套用所有設定", target: self, action: #selector(applyAllSettings))
        applyAll.bezelStyle = .rounded
        return tab("進階", rows: [
            rebuild,
            note("重新建立執行 Windows 遊戲所需的環境。遊戲檔案不會刪除，但已安裝的 Windows 元件與自訂設定需要重新套用。"),
            applyAll,
            note("使用 Wine 完整寫入目前所有設定；一般調整會在點選控制項時立即快速儲存。"),
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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = container
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        item.view = scroll
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
        smoothing.selectItem(at: smoothingValues.firstIndex(of: value.fontSmoothing) ?? 2)
        profileDrafts = value.perProfile
        profileRecords = Dictionary(uniqueKeysWithValues: profileStore.listRecords().map { ($0.profileId, $0) })
        deletedProfiles.removeAll()
        selectedProfileID = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        isDirty = false
        status.stringValue = "變更會立即儲存"
        status.textColor = .secondaryLabelColor
    }

    func prepareForDisplay() {
        reload()
    }

    @objc private func markDirty() {
        saveImmediately()
    }

    private func saveImmediately(registrySetting: String? = nil) {
        let requiresPrefixApply = prefixSettingsChanged()
        isDirty = true
        guard saveControls() else { return }
        guard requiresPrefixApply else { return }
        if hasRunningExes?() ?? false {
            status.stringValue = "已儲存；關閉遊戲後將於下次啟動前套用"
            return
        }
        if onImmediateSave?(registrySetting ?? "all") == false {
            status.stringValue = "設定已儲存，但無法更新 Windows 環境"
            status.textColor = .systemRed
        }
    }

    @objc private func retinaChanged() {
        // RetinaMode changes the effective coordinate scale.  Offer the
        // matching conventional DPI as a starting point, while leaving the
        // popup enabled so users can immediately choose a custom value.
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let targetDPI = retina.state == .on ? 192 : 96
        dpi.selectItem(at: dpiValues.firstIndex(of: targetDPI) ?? 0)
        saveImmediately(registrySetting: "display")
    }

    @objc private func dpiChanged() {
        saveImmediately(registrySetting: "dpi")
    }

    @objc private func smoothingChanged() {
        saveImmediately(registrySetting: "smoothing")
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
                for profileID in deletedProfiles {
                    $0.perProfile.removeValue(forKey: profileID)
                }
                for (profileID, rule) in profileDrafts where !deletedProfiles.contains(profileID) {
                    $0.perProfile[profileID] = rule
                }
            }
            status.stringValue = "已儲存"
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
        saveImmediately(registrySetting: "font")
    }

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "選擇要套用個別設定的 EXE"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch profileStore.resolve(executable: url) {
        case .ready(let record):
            let profileID = record.profileId
            deletedProfiles.remove(profileID)
            selectedProfileID = profileID
            profileRecords[profileID] = record
            refreshExecutableList(selecting: profileID)
            loadExecutableSettings(profileID)
        case .uncreated:
            let alert = NSAlert()
            alert.messageText = "建立獨立遊戲環境？"
            alert.informativeText = "Cyder 會從乾淨的標準環境複製一份給 \(url.lastPathComponent)，不會修改共用環境。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "建立")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            onCreateProfile?(url)
        case .damaged(let profileID, let reason):
            profileAlert("遊戲 Profile 無法使用", "Profile \(profileID) 目前損毀或不完整：\(reason)\n請先由主流程修復，再重新選擇 EXE。", warning: true)
        }
    }

    @objc private func selectConfiguredExecutable() {
        guard executableList.isEnabled,
              let profileID = executableList.selectedItem?.representedObject as? String else { return }
        loadExecutableSettings(profileID)
    }

    @objc private func removeExecutableSettings() {
        guard let profileID = selectedProfileID else { return }
        let alert = NSAlert()
        alert.messageText = "移除這個遊戲的 Profile 設定？"
        alert.informativeText = "這個 Profile 將立即改用一般設定；Profile bottle 本身不會刪除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileDrafts.removeValue(forKey: profileID)
        deletedProfiles.insert(profileID)
        selectedProfileID = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        markDirty()
    }

    @objc private func executableSettingChanged() {
        executableRecommendation.selectItem(at: 0)
        captureExecutableSettings()
        markDirty()
    }

    @objc private func executableRetinaChanged() {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let targetDPI = executableRetina.state == .on ? 192 : 96
        executableDpi.selectItem(at: dpiValues.firstIndex(of: targetDPI) ?? 0)
        executableSettingChanged()
    }

    @objc private func executableFontChanged() {
        if executableFont.indexOfSelectedItem == 1 {
            let alert = NSAlert()
            alert.messageText = "使用細明體前需要先安裝字型"
            alert.informativeText = "請先在 macOS「字體簿」安裝細明體，或將合法取得的 MingLiU 字型安裝到目前的 Wine 環境。Cyder 只切換字體設定，不會提供或自動安裝細明體。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "我知道了")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                executableFont.selectItem(at: 0)
            }
        }
        executableSettingChanged()
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
        guard let profileID = selectedProfileID else {
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
        profileDrafts[profileID] = rule
        loadExecutableSettings(profileID)
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
        rule.fontPreset = value.fontPreset
        rule.fontSmoothing = value.fontSmoothing
        return rule
    }

    private func captureExecutableSettings() {
        guard let profileID = selectedProfileID else { return }
        let dpiValues = [96, 120, 144, 168, 192, 240]
        var rule = profileDrafts[profileID] ?? defaultExecutableSettings()
        rule.msync = executableMsync.state == .on
        rule.esync = executableEsync.state == .on
        rule.retinaMode = executableRetina.state == .on
        rule.dpi = dpiValues[max(0, executableDpi.indexOfSelectedItem)]
        rule.powerMode = ["standard", "energySaving"][max(0, executablePowerMode.indexOfSelectedItem)]
        rule.fontPreset = executableFont.indexOfSelectedItem == 1 ? "mingliu" : "songti"
        rule.fontSmoothing = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"][max(0, executableSmoothing.indexOfSelectedItem)]
        rule.environment = executableEnvironment.stringValue
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { entry -> (String, String)? in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                let key = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(entry[entry.index(after: separator)...])
                return (key, value)
            }
            .reduce(into: [String: String]()) { result, item in
                result[item.0] = item.1
            }
        rule.arguments = executableArguments.stringValue
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        profileDrafts[profileID] = rule
        deletedProfiles.remove(profileID)
    }

    private func loadExecutableSettings(_ profileID: String) {
        guard let record = profileRecords[profileID] else { return }
        let rule = profileDrafts[profileID] ?? defaultExecutableSettings()
        let defaults = defaultExecutableSettings()
        let dpiValues = [96, 120, 144, 168, 192, 240]
        selectedProfileID = profileID
        if let index = executableList.itemArray.firstIndex(where: { ($0.representedObject as? String) == profileID }) {
            executableList.selectItem(at: index)
        }
        let sourceURL = URL(fileURLWithPath: record.sourcePath)
        executableName.stringValue = "\(sourceURL.lastPathComponent)（\(sourceURL.deletingLastPathComponent().path)）"
        executableMsync.state = (rule.msync ?? defaults.msync ?? false) ? .on : .off
        executableEsync.state = (rule.esync ?? defaults.esync ?? false) ? .on : .off
        executableRetina.state = (rule.retinaMode ?? defaults.retinaMode ?? true) ? .on : .off
        executableDpi.selectItem(at: dpiValues.firstIndex(of: rule.dpi ?? defaults.dpi ?? 192) ?? 4)
        executablePowerMode.selectItem(at: rule.powerMode == "energySaving" ? 1 : 0)
        executableFont.selectItem(at: rule.fontPreset == "mingliu" ? 1 : 0)
        let smoothingValues = ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"]
        executableSmoothing.selectItem(at: smoothingValues.firstIndex(of: rule.fontSmoothing ?? defaults.fontSmoothing ?? "cleartype-rgb") ?? 2)
        executableEnvironment.stringValue = rule.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        executableArguments.stringValue = rule.arguments.joined(separator: " | ")
        executableRecommendation.selectItem(at: 0)
        setExecutableControlsEnabled(true)
    }

    private func refreshExecutableList(selecting preferred: String? = nil) {
        executableList.removeAllItems()
        let ids = profileRecords.keys
            .filter { !deletedProfiles.contains($0) }
            .sorted { profileDisplayName(profileRecords[$0]!).localizedStandardCompare(profileDisplayName(profileRecords[$1]!)) == .orderedAscending }
        guard !ids.isEmpty else {
            executableList.addItem(withTitle: "尚無已建立遊戲")
            executableList.isEnabled = false
            setExecutableControlsEnabled(false)
            return
        }
        for profileID in ids {
            executableList.addItem(withTitle: profileDisplayName(profileRecords[profileID]!))
            executableList.item(at: executableList.numberOfItems - 1)?.representedObject = profileID
        }
        executableList.isEnabled = true
        let selected = preferred.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        loadExecutableSettings(selected)
    }

    private func profileDisplayName(_ record: CyderProfileRecord) -> String {
        let sourceURL = URL(fileURLWithPath: record.sourcePath)
        return "\(sourceURL.lastPathComponent) — \(sourceURL.deletingLastPathComponent().path)"
    }

    private func profileAlert(_ title: String, _ message: String, warning: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func setExecutableControlsEnabled(_ enabled: Bool) {
        executableRecommendation.isEnabled = enabled
        executableMsync.isEnabled = enabled
        executableEsync.isEnabled = enabled
        executableRetina.isEnabled = enabled
        executableDpi.isEnabled = enabled
        executablePowerMode.isEnabled = enabled
        executableFont.isEnabled = enabled
        executableSmoothing.isEnabled = enabled
        executableEnvironment.isEnabled = enabled
        executableArguments.isEnabled = enabled
        removeExecutableButton.isEnabled = enabled
        if !enabled {
            executableMsync.state = .off
            executableEsync.state = .off
            executableRetina.state = .off
            executableDpi.selectItem(at: 4)
            executablePowerMode.selectItem(at: 0)
            executableFont.selectItem(at: 0)
            executableSmoothing.selectItem(at: 2)
            executableEnvironment.stringValue = ""
            executableArguments.stringValue = ""
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
        smoothing.selectItem(at: 2)
        saveImmediately(registrySetting: "all")
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

    @objc private func applyAllSettings() {
        let running = hasRunningExes?() ?? false
        var shouldStopAll = false
        if running {
            let alert = NSAlert()
            alert.messageText = "套用所有設定前需要關閉遊戲"
            alert.informativeText = "這會關閉所有正在執行的遊戲，未儲存的遊戲進度可能會遺失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "關閉遊戲並套用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            shouldStopAll = true
        }
        onSaveStarted?()
        onApplyAll?(shouldStopAll)
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
        for profileID in deletedProfiles {
            if value.perProfile[profileID] != nil { return true }
        }
        for (profileID, rule) in profileDrafts {
            let stored = value.perProfile[profileID]
            if stored?.msync != rule.msync
                || stored?.esync != rule.esync
                || stored?.powerMode != rule.powerMode {
                return true
            }
        }
        return false
    }
}
