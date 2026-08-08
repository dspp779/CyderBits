import Cocoa
import Foundation

private struct CyderWinetricksComponent {
    let title: String
    let verb: String
}

private let cyderWinetricksComponentGroups: [(String, [CyderWinetricksComponent])] = [
    ("Microsoft Visual C++ Redistributable", [
        CyderWinetricksComponent(title: "Visual C++ 2005", verb: "vcrun2005"),
        CyderWinetricksComponent(title: "Visual C++ 2008", verb: "vcrun2008"),
        CyderWinetricksComponent(title: "Visual C++ 2010", verb: "vcrun2010"),
        CyderWinetricksComponent(title: "Visual C++ 2012", verb: "vcrun2012"),
        CyderWinetricksComponent(title: "Visual C++ 2013", verb: "vcrun2013"),
        CyderWinetricksComponent(title: "Visual C++ 2015", verb: "vcrun2015"),
        CyderWinetricksComponent(title: "Visual C++ 2019", verb: "vcrun2019"),
        CyderWinetricksComponent(title: "Visual C++ 2022", verb: "vcrun2022"),
    ]),
    (".NET Framework", [
        CyderWinetricksComponent(title: ".NET Framework 2.0", verb: "dotnet20"),
        CyderWinetricksComponent(title: ".NET Framework 3.5", verb: "dotnet35"),
        CyderWinetricksComponent(title: ".NET Framework 4.0", verb: "dotnet40"),
        CyderWinetricksComponent(title: ".NET Framework 4.5.2", verb: "dotnet452"),
        CyderWinetricksComponent(title: ".NET Framework 4.8", verb: "dotnet48"),
    ]),
    (".NET Desktop Runtime", [
        CyderWinetricksComponent(title: ".NET Desktop Runtime 6", verb: "dotnetdesktop6"),
        CyderWinetricksComponent(title: ".NET Desktop Runtime 7", verb: "dotnetdesktop7"),
        CyderWinetricksComponent(title: ".NET Desktop Runtime 8", verb: "dotnetdesktop8"),
        CyderWinetricksComponent(title: ".NET Desktop Runtime 9", verb: "dotnetdesktop9"),
    ]),
    ("Legacy multimedia", [
        CyderWinetricksComponent(title: "Windows Media Player 9", verb: "wmp9"),
        CyderWinetricksComponent(title: "Quartz DirectShow", verb: "quartz"),
        CyderWinetricksComponent(title: "DirectShow Devenum", verb: "devenum"),
        CyderWinetricksComponent(title: "Visual Basic 6 Runtime", verb: "vb6run"),
    ]),
    ("Apps", [
        CyderWinetricksComponent(title: "Steam", verb: "steam"),
    ]),
]

final class CyderSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onImmediateSave: ((_ registrySetting: String) -> Bool)?
    /// Live Wine `reg add` with draft env; return true only after registry apply succeeds.
    var onApplyWhileRunning: ((_ draftEnvironment: [String: String]) -> Bool)?
    var onRebuild: (() -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onOpenGameLibrary: (() -> Void)?
    var onOpenWinetricks: (([String]) -> Void)?
    var onExportLastGameLog: (() -> Void)?
    var onCleanDebugLogs: (() -> Void)?
    var onSaveStarted: (() -> Void)?
    var onSaveFailed: (() -> Void)?
    var onClose: (() -> Void)?
    var hasRunningExes: (() -> Bool)?
    /// Stops all Cyder Wine processes (wineserver -k) and waits (-w). Returns true on success.
    var onStopAllWine: (() -> Bool)?
    private let store = CyderSettingsStore.shared
    private let applyButton = NSButton()
    private var wineIsRunning = false
    private var didShowRunningAlert = false
    private let syncMode = NSPopUpButton()
    private let syncModeDescription = NSTextField(wrappingLabelWithString: "")
    private let retina = NSSwitch()
    private let dpi = NSPopUpButton()
    private let fontMingLiu = NSPopUpButton()
    private let fontSongti = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let graphicsBackend = NSPopUpButton()
    private let dxvkFrameRate = NSPopUpButton()
    private let graphicsHud = NSPopUpButton()
    private let dxvkHudFrametimes = NSSwitch()
    private let graphicsHelp = NSTextField(wrappingLabelWithString: "")
    private let d3dmetalStatus = NSTextField(labelWithString: "")
    private let gptkNote = NSTextField(wrappingLabelWithString: "")
    private let installGptkButton = NSButton()
    private let removeGptkButton = NSButton()
    private let stopAllWineButton = NSButton()
    private let wineDiagnostics = NSPopUpButton()
    private let diagnosticsWarning = NSTextField(wrappingLabelWithString: "")
    private let executableList = NSPopUpButton()
    private let executableRecommendation = NSPopUpButton()
    private let executableName = NSTextField(labelWithString: "尚未選擇 EXE")
    private let executableSyncMode = NSPopUpButton()
    private let executableRetina = NSSwitch()
    private let executableDpi = NSPopUpButton()
    private let executablePowerMode = NSPopUpButton()
    private let executableFontMingLiu = NSPopUpButton()
    private let executableFontSongti = NSPopUpButton()
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
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
        tabs.addTabViewItem(makeGraphicsTab())
        tabs.addTabViewItem(makeAdvancedTab())
        tabs.addTabViewItem(makeDiagnosticsTab())

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 320

        applyButton.title = "套用設定"
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyRunningSettings)
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.isHidden = true

        let reset = NSButton(title: "全部恢復預設值…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        content.addSubview(status)
        content.addSubview(applyButton)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            status.trailingAnchor.constraint(lessThanOrEqualTo: applyButton.leadingAnchor, constant: -12),
            applyButton.trailingAnchor.constraint(equalTo: reset.leadingAnchor, constant: -10),
            applyButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reset.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
    }

    private func makeGeneralTab() -> NSTabViewItem {
        syncMode.addItems(withTitles: CyderSyncMode.allCases.map { $0.title })
        syncMode.target = self
        syncMode.action = #selector(syncModeChanged)
        configureNote(syncModeDescription)
        updateSyncModeDescription()
        let gameLibrary = NSButton(title: "打開遊戲庫…", target: self, action: #selector(openGameLibrary))
        gameLibrary.bezelStyle = .rounded
        stopAllWineButton.title = "關閉所有 Wine 程序"
        stopAllWineButton.bezelStyle = .rounded
        stopAllWineButton.target = self
        stopAllWineButton.action = #selector(stopAllWine)
        return tab("一般", rows: [
            gameLibrary,
            note("加入 Windows 遊戲、直接啟動，或管理每個遊戲的獨立 Wine prefix 與設定。"),
            stopAllWineButton,
            note("對目前 Cyder 使用的 Wine 環境執行 wineserver -k，並等待程序結束。"),
            row("同步機制", syncMode),
            syncModeDescription,
        ])
    }

    @objc private func openGameLibrary() {
        onOpenGameLibrary?()
    }

    @objc private func openWinetricks() {
        let alert = NSAlert()
        alert.messageText = "選擇要安裝的 Windows 元件"
        alert.informativeText = "元件會安裝到 Cyder 的 shared prefix。請只選擇遊戲需要的版本；安裝前請先關閉所有遊戲。"
        alert.alertStyle = .informational

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        var checkboxes: [(NSButton, String)] = []
        for (groupTitle, components) in cyderWinetricksComponentGroups {
            let group = NSTextField(labelWithString: groupTitle)
            group.font = .boldSystemFont(ofSize: 12)
            stack.addArrangedSubview(group)
            for component in components {
                let checkbox = NSButton(checkboxWithTitle: component.title, target: nil, action: nil)
                checkbox.font = .systemFont(ofSize: 12)
                stack.addArrangedSubview(checkbox)
                checkboxes.append((checkbox, component.verb))
            }
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            stack.addArrangedSubview(spacer)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 310))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "安裝")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let verbs = checkboxes.compactMap { item in
            item.0.state == .on ? item.1 : nil
        }
        guard !verbs.isEmpty else {
            let empty = NSAlert()
            empty.messageText = "尚未選擇元件"
            empty.informativeText = "請至少選擇一個要安裝的 Windows 元件。"
            empty.addButton(withTitle: "好")
            empty.runModal()
            return
        }
        onOpenWinetricks?(verbs)
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
        for popup in [fontMingLiu, fontSongti] {
            popup.addItems(withTitles: cyderFontTargetTitles)
        }
        fontMingLiu.target = self
        fontMingLiu.action = #selector(fontMingLiuChanged)
        fontSongti.target = self
        fontSongti.action = #selector(fontSongtiChanged)
        smoothing.addItems(withTitles: ["關閉", "灰階", "ClearType RGB"])
        smoothing.target = self
        smoothing.action = #selector(smoothingChanged)
        return tab("字體", rows: [
            row("細明體取代", fontMingLiu),
            row("宋體取代", fontSongti),
            note("Cyder 只設定 Wine 的字體替代規則，不會自動安裝受授權保護的字型。"),
            row("字體平滑", smoothing),
        ])
    }

    private func makeGraphicsTab() -> NSTabViewItem {
        graphicsBackend.addItems(withTitles: graphicsBackendTitles)
        graphicsBackend.target = self
        graphicsBackend.action = #selector(graphicsBackendChanged)
        updateD3DMetalMenuItemAvailability()
        updateDxmtMenuItemAvailability()
        dxvkFrameRate.addItems(withTitles: ["60", "不限制"])
        dxvkFrameRate.target = self
        dxvkFrameRate.action = #selector(dxvkFrameRateChanged)
        graphicsHud.target = self
        graphicsHud.action = #selector(graphicsHudChanged)
        dxvkHudFrametimes.target = self
        dxvkHudFrametimes.action = #selector(dxvkHudFrametimesChanged)
        graphicsHelp.textColor = .secondaryLabelColor
        graphicsHelp.font = .systemFont(ofSize: 12)
        graphicsHelp.maximumNumberOfLines = 4
        graphicsHelp.widthAnchor.constraint(equalToConstant: 460).isActive = true
        d3dmetalStatus.textColor = .secondaryLabelColor
        d3dmetalStatus.font = .systemFont(ofSize: 12)
        d3dmetalStatus.maximumNumberOfLines = 3
        d3dmetalStatus.widthAnchor.constraint(equalToConstant: 460).isActive = true
        gptkNote.textColor = .secondaryLabelColor
        gptkNote.font = .systemFont(ofSize: 12)
        gptkNote.maximumNumberOfLines = 4
        gptkNote.widthAnchor.constraint(equalToConstant: 460).isActive = true
        installGptkButton.title = "安裝 GPTK…"
        installGptkButton.target = self
        installGptkButton.action = #selector(installGptk)
        installGptkButton.bezelStyle = .rounded
        removeGptkButton.title = "移除已安裝 GPTK"
        removeGptkButton.bezelStyle = .rounded
        removeGptkButton.target = self
        removeGptkButton.action = #selector(removeGptk)
        let buttons = NSStackView(views: [installGptkButton, removeGptkButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        return tab("圖形", rows: [
            row("圖形轉譯", graphicsBackend),
            graphicsHelp,
            row("限制幀率", dxvkFrameRate),
            row("顯示畫面流暢度", graphicsHud),
            row("顯示 frametimes", dxvkHudFrametimes),
            d3dmetalStatus,
            buttons,
            gptkNote,
        ])
    }

    private func makeAdvancedTab() -> NSTabViewItem {
        let rebuild = NSButton(title: "重建 Windows 遊戲環境…", target: self, action: #selector(rebuildEnvironment))
        rebuild.bezelStyle = .rounded
        let winetricks = NSButton(title: "Winetricks 元件…", target: self, action: #selector(openWinetricks))
        winetricks.bezelStyle = .rounded
        return tab("進階", rows: [
            rebuild,
            note("重新建立執行 Windows 遊戲所需的環境。遊戲檔案不會刪除，但已安裝的 Windows 元件與自訂設定需要重新套用。"),
            winetricks,
            note("以原生選擇器安裝 VC++、.NET、WMP、Quartz、Devenum 等元件到 shared prefix。請先關閉所有遊戲。"),
        ])
    }

    private func makeDiagnosticsTab() -> NSTabViewItem {
        wineDiagnostics.addItems(withTitles: ["安靜（預設）", "只記錄錯誤", "等待與凍結追蹤", "完整堆疊追蹤"])
        wineDiagnostics.target = self
        wineDiagnostics.action = #selector(wineDiagnosticsChanged)

        diagnosticsWarning.stringValue = "⚠ 除錯記錄可能快速佔用大量磁碟空間，並改變遊戲時序。只在重現問題時短時間開啟；完成後請切回「安靜」，再清理除錯記錄。"
        diagnosticsWarning.textColor = .systemRed
        diagnosticsWarning.font = .boldSystemFont(ofSize: 12)
        diagnosticsWarning.isHidden = true

        let export = NSButton(title: "匯出上次遊戲記錄…", target: self, action: #selector(exportLastGameLog))
        export.bezelStyle = .rounded
        let cleanup = NSButton(title: "清理除錯記錄…", target: self, action: #selector(cleanDebugLogs))
        cleanup.bezelStyle = .rounded
        return tab("除錯", rows: [
            row("Wine 診斷記錄", wineDiagnostics),
            diagnosticsWarning,
            note("「安靜」不開啟 Wine trace，啟動失敗仍會由程序退出碼判斷；「只記錄錯誤」適合一般排障；「等待與凍結追蹤」用於重現卡住／凍結；「完整堆疊追蹤」僅供短時間重現 exception／unwind 問題。"),
            export,
            note("只複製上次遊戲啟動的 Wine log；其他初始化或啟動錯誤可直接複製錯誤對話框中的診斷資訊。"),
            cleanup,
            note("會移除 Wine launch/debug log，以及 Logs/operations 和 Logs/sessions 內的紀錄；不會刪除遊戲、prefix 或設定。清理前請先關閉遊戲。"),
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
        stack.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return stack
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        configureNote(label)
        return label
    }

    private func configureNote(_ label: NSTextField) {
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 7
        label.widthAnchor.constraint(equalToConstant: 460).isActive = true
    }

    private func updateSyncModeDescription() {
        let index = max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))
        syncModeDescription.stringValue = CyderSyncMode.allCases[index].description
    }

    private func reload() {
        let value = store.value
        syncMode.selectItem(at: CyderSyncMode(msync: value.msync, esync: value.esync ?? false).rawValue)
        updateSyncModeDescription()
        retina.state = value.retinaMode ? .on : .off
        let dpiValues = [96, 120, 144, 168, 192, 240]
        dpi.selectItem(at: dpiValues.firstIndex(of: value.dpi) ?? 4)
        fontMingLiu.selectItem(at: cyderFontTargetIndex(value.fontMingLiuTarget))
        fontSongti.selectItem(at: cyderFontTargetIndex(value.fontSongtiTarget))
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        smoothing.selectItem(at: smoothingValues.firstIndex(of: value.fontSmoothing) ?? 2)
        graphicsBackend.selectItem(at: graphicsBackendIndex(value.graphicsBackend))
        dxvkFrameRate.selectItem(at: value.dxvkFrameRate == .unlimited ? 1 : 0)
        rebuildGraphicsHudMenu(selecting: value.graphicsHud)
        dxvkHudFrametimes.state = value.dxvkHudFrametimes ? .on : .off
        switch value.wineDiagnostics {
        case .quiet: wineDiagnostics.selectItem(at: 0)
        case .errors: wineDiagnostics.selectItem(at: 1)
        case .sync: wineDiagnostics.selectItem(at: 2)
        case .unwind: wineDiagnostics.selectItem(at: 3)
        }
        diagnosticsWarning.isHidden = value.wineDiagnostics == .quiet
        refreshGraphicsControls()
        profileDrafts = value.perProfile
        profileRecords = Dictionary(uniqueKeysWithValues: profileStore.listRecords().map { ($0.profileId, $0) })
        deletedProfiles.removeAll()
        selectedProfileID = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        isDirty = false
        refreshRunningChrome()
    }

    func prepareForDisplay() {
        wineIsRunning = hasRunningExes?() ?? false
        didShowRunningAlert = false
        reload()
        if wineIsRunning {
            presentRunningWineAlertIfNeeded()
        }
    }

    private func refreshRunningChrome() {
        wineIsRunning = hasRunningExes?() ?? false
        applyButton.isHidden = !wineIsRunning
        status.textColor = .secondaryLabelColor
        if wineIsRunning {
            status.stringValue = "目前遊戲正在執行中，需套用設定才會儲存設定，並且完全重開才會套用成功。"
        } else if isDirty {
            status.stringValue = "變更會立即儲存"
        } else {
            status.stringValue = "變更會立即儲存"
        }
    }

    private func presentRunningWineAlertIfNeeded() {
        guard wineIsRunning, !didShowRunningAlert else { return }
        didShowRunningAlert = true
        let alert = NSAlert()
        alert.messageText = "目前遊戲正在執行中"
        alert.informativeText = "需按「套用設定」才會儲存設定；Retina／DPI 等顯示設定需完全退出遊戲後再重開才會套用成功。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func markDirty() {
        saveImmediately()
    }

    private func saveImmediately(registrySetting: String? = nil) {
        if wineIsRunning || (hasRunningExes?() ?? false) {
            wineIsRunning = true
            isDirty = true
            applyButton.isHidden = false
            status.stringValue = "目前遊戲正在執行中，需套用設定才會儲存設定，並且完全重開才會套用成功。"
            status.textColor = .secondaryLabelColor
            return
        }
        let requiresPrefixApply = prefixSettingsChanged()
        isDirty = true
        guard saveControls() else { return }
        guard requiresPrefixApply else { return }
        if onImmediateSave?(registrySetting ?? "all") == false {
            status.stringValue = "設定已儲存，但無法更新 Windows 環境"
            status.textColor = .systemRed
        }
    }

    @objc private func applyRunningSettings() {
        wineIsRunning = hasRunningExes?() ?? false
        guard wineIsRunning else {
            // Wine exited while the window was open — fall back to immediate save.
            refreshRunningChrome()
            saveImmediately(registrySetting: "all")
            return
        }
        let draft = draftApplyEnvironment()
        status.stringValue = "正在套用設定…"
        status.textColor = .secondaryLabelColor
        onSaveStarted?()
        let ok = onApplyWhileRunning?(draft) ?? false
        onSaveFailed?() // clears setup chrome; success path still continues below
        guard ok else {
            status.stringValue = "無法寫入 Windows 環境；設定尚未儲存"
            status.textColor = .systemRed
            return
        }
        guard saveControls() else { return }
        isDirty = false
        status.stringValue = "已寫入環境並儲存；請完全退出遊戲後再重開以完整套用。"
        status.textColor = .secondaryLabelColor
    }

    private func draftApplyEnvironment() -> [String: String] {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        let mode = CyderSyncMode.allCases[max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
        return [
            "CYDER_FORCE_SETTINGS": "1",
            "CYDER_RETINA_MODE": retina.state == .on ? "1" : "0",
            "CYDER_DPI": String(dpiValues[max(0, dpi.indexOfSelectedItem)]),
            "CYDER_FONT_SMOOTHING": smoothingValues[max(0, smoothing.indexOfSelectedItem)],
            "CYDER_FONT_MINGLIU_TARGET": cyderFontTarget(at: fontMingLiu.indexOfSelectedItem),
            "CYDER_FONT_SONGTI_TARGET": cyderFontTarget(at: fontSongti.indexOfSelectedItem),
            "CYDER_MSYNC": mode == .msync ? "1" : "0",
            "CYDER_ESYNC": mode == .esync ? "1" : "0",
        ]
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

    @objc private func graphicsBackendChanged() {
        if graphicsBackendValue != .dxvk, store.value.graphicsHud == .dxvk {
            // Drop an invalid DXVK-only HUD choice when leaving manual DXVK.
            try? store.update { $0.graphicsHud = .off }
        }
        rebuildGraphicsHudMenu(selecting: store.value.graphicsHud)
        refreshGraphicsControls()
        saveImmediately()
    }

    @objc private func dxvkFrameRateChanged() {
        saveImmediately()
    }

    @objc private func graphicsHudChanged() {
        refreshGraphicsControls()
        saveImmediately()
    }

    @objc private func dxvkHudFrametimesChanged() {
        saveImmediately()
    }

    @objc private func wineDiagnosticsChanged() {
        let selected: CyderWineDiagnostics
        switch wineDiagnostics.indexOfSelectedItem {
        case 1: selected = .errors
        case 2: selected = .sync
        case 3: selected = .unwind
        default: selected = .quiet
        }
        if selected != .quiet {
            let alert = NSAlert()
            switch selected {
            case .unwind:
                alert.messageText = "即將開啟高容量堆疊追蹤"
                alert.informativeText = "完整堆疊追蹤可能快速產生數十 MB 以上的記錄，並改變遊戲時序。請只在短時間重現問題時使用。"
            case .sync:
                alert.messageText = "即將開啟等待與凍結追蹤"
                alert.informativeText = "等待追蹤會記錄每次等待的物件，資料量明顯小於完整堆疊追蹤，但仍會持續寫入。請在重現卡住問題後切回「安靜」。"
            default:
                alert.messageText = "即將保存 Wine 錯誤記錄"
                alert.informativeText = "只記錄錯誤會保存每次遊戲啟動的 Wine 輸出，可能增加磁碟使用量。重現完成後請切回「安靜」並清理除錯記錄。"
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "啟用")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                switch store.value.wineDiagnostics {
                case .quiet: wineDiagnostics.selectItem(at: 0)
                case .errors: wineDiagnostics.selectItem(at: 1)
                case .sync: wineDiagnostics.selectItem(at: 2)
                case .unwind: wineDiagnostics.selectItem(at: 3)
                }
                return
            }
        }
        diagnosticsWarning.isHidden = selected == .quiet
        saveImmediately()
    }

    @objc private func exportLastGameLog() {
        onExportLastGameLog?()
    }

    @objc private func cleanDebugLogs() {
        onCleanDebugLogs?()
    }

    @objc private func stopAllWine() {
        let alert = NSAlert()
        alert.messageText = "關閉所有 Wine 程序？"
        alert.informativeText = "會結束目前 Cyder 使用的 Wine 環境中所有遊戲與相關程序。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "關閉")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopAllWineButton.isEnabled = false
        status.stringValue = "正在關閉 Wine 程序…"
        status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.onStopAllWine?() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopAllWineButton.isEnabled = true
                    self.refreshRunningChrome()
                    if ok {
                        self.status.stringValue = "已關閉所有 Wine 程序"
                        self.status.textColor = .secondaryLabelColor
                    } else {
                        self.status.stringValue = "關閉 Wine 程序失敗或尚未就緒"
                        self.status.textColor = .systemRed
                    }
            }
        }
    }

    private static let gptkDownloadURL = URL(
        string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit"
    )!

    @objc private func installGptk() {
        let candidates = CyderGptk.scanEvaluationVolumes()
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "找不到可安裝的 GPTK"
            alert.informativeText = """
            請先從 Apple Developer 下載「Evaluation environment for Windows games」DMG，掛載並同意授權後再回來安裝。

            若已安裝 CrossOver 且未另外安裝 GPTK，Cyder 會使用 CrossOver 內附版本。
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "打開下載頁面")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.gptkDownloadURL)
            }
            return
        }

        guard let chosen = chooseGptkCandidate(candidates) else { return }
        let confirm = NSAlert()
        confirm.messageText = "確定安裝此版本？"
        confirm.informativeText = chosen.displayName
        confirm.addButton(withTitle: "安裝")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try CyderGptk.install(from: chosen)
            refreshGraphicsControls()
            showGptkAlert(title: "已安裝 GPTK", message: "已安裝：\(chosen.displayName)")
        } catch {
            showGptkAlert(title: "無法安裝 GPTK", message: error.localizedDescription)
        }
    }

    /// Pick among mounted GPTK volumes. Prefer explicit buttons (reliable on
    /// NSAlert); fall back to a sized popup when there are many candidates.
    private func chooseGptkCandidate(
        _ candidates: [CyderGptkVolumeCandidate]
    ) -> CyderGptkVolumeCandidate? {
        let labels = candidates.map { CyderGptk.versionLabel(fromVolumeDisplayName: $0.displayName) }
        if candidates.count <= 4 {
            let alert = NSAlert()
            alert.messageText = "安裝 GPTK"
            alert.informativeText = "偵測到已掛載的 GPTK 卷宗，請選擇要安裝的版本："
            for label in labels {
                alert.addButton(withTitle: label)
            }
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < candidates.count else { return nil }
            return candidates[index]
        }

        let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28), pullsDown: false)
        selector.addItems(withTitles: labels)
        let alert = NSAlert()
        alert.messageText = "安裝 GPTK"
        alert.informativeText = "偵測到已掛載的 GPTK 卷宗，請選擇要安裝的版本："
        alert.accessoryView = selector
        alert.addButton(withTitle: "安裝")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = max(0, min(selector.indexOfSelectedItem, candidates.count - 1))
        return candidates[index]
    }

    @objc private func removeGptk() {
        do {
            try CyderGptk.removeRuntimeInstall()
            refreshGraphicsControls()
        } catch {
            showGptkAlert(title: "無法移除已安裝 GPTK", message: error.localizedDescription)
        }
    }

    @objc private func syncModeChanged() {
        updateSyncModeDescription()
        markDirty()
    }

    private func saveControls() -> Bool {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        do {
            try store.update {
                let mode = CyderSyncMode.allCases[max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
                $0.msync = mode == .msync
                $0.esync = mode == .esync
                $0.retinaMode = retina.state == .on
                $0.dpi = dpiValues[max(0, dpi.indexOfSelectedItem)]
                $0.fontMingLiuTarget = cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
                $0.fontSongtiTarget = cyderFontTarget(at: fontSongti.indexOfSelectedItem)
                $0.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
                $0.graphicsBackend = graphicsBackendValue
                $0.dxvkFrameRate = dxvkFrameRate.indexOfSelectedItem == 1 ? .unlimited : .sixty
                $0.graphicsHud = graphicsHudValue
                $0.dxvkHudFrametimes = dxvkHudFrametimes.state == .on
                switch wineDiagnostics.indexOfSelectedItem {
                case 1: $0.wineDiagnostics = .errors
                case 2: $0.wineDiagnostics = .sync
                case 3: $0.wineDiagnostics = .unwind
                default: $0.wineDiagnostics = .quiet
                }
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

    @objc private func fontMingLiuChanged() {
        if fontMingLiu.indexOfSelectedItem == 0 {
            let alert = NSAlert()
            alert.messageText = "使用細明體前需要先安裝字型"
            alert.informativeText = "請先在 macOS「字體簿」安裝細明體，或將合法取得的 MingLiU 字型安裝到目前的 Wine 環境。Cyder 只切換字體設定，不會提供或自動安裝細明體。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "我知道了")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                fontMingLiu.selectItem(at: cyderFontTargetIndex(store.value.fontMingLiuTarget))
            }
        }
        saveImmediately(registrySetting: "font-mingliu")
    }

    @objc private func fontSongtiChanged() {
        saveImmediately(registrySetting: "font-songti")
    }

    private var supportsD3DMetalOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
    }

    private var canSelectD3DMetal: Bool {
        supportsD3DMetalOS && CyderGptk.preferredSource() != nil
    }

    private var canSelectDxmt: Bool {
        supportsD3DMetalOS && CyderGraphicsCapabilities.current().hasDxmt
    }

    private var graphicsBackendTitles: [String] {
        return ["預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]
    }

    // Index map (shared by OEM and official): 0 default, 1 d3dmetal, 2 dxmt, 3 dxvk, 4 wined3d.
    private func updateD3DMetalMenuItemAvailability() {
        guard let item = graphicsBackend.item(at: 1) else { return }
        item.isEnabled = canSelectD3DMetal
        if !supportsD3DMetalOS {
            item.toolTip = "需要 macOS 14+"
        } else if CyderGptk.preferredSource() == nil {
            item.toolTip = "需要本機 CrossOver 或已安裝的評估版 GPTK"
        } else {
            item.toolTip = nil
        }
    }

    private func updateDxmtMenuItemAvailability() {
        guard let item = graphicsBackend.item(at: 2) else { return }
        item.isEnabled = canSelectDxmt
        if !supportsD3DMetalOS {
            item.toolTip = "需要 macOS 14+"
        } else if !CyderGraphicsCapabilities.current().hasDxmt {
            item.toolTip = "需要引擎內建 DXMT"
        } else {
            item.toolTip = nil
        }
    }

    private var graphicsBackendValue: CyderGraphicsBackend {
        switch graphicsBackend.indexOfSelectedItem {
        case 1: return canSelectD3DMetal ? .d3dmetal : .default
        case 2: return canSelectDxmt ? .dxmt : .default
        case 3: return .dxvk
        case 4: return .wined3d
        default: return .default
        }
    }

    private func graphicsBackendIndex(_ value: CyderGraphicsBackend) -> Int {
        switch value {
        case .default: return 0
        case .d3dmetal: return canSelectD3DMetal ? 1 : 0
        case .dxmt: return canSelectDxmt ? 2 : 0
        case .dxvk: return 3
        case .wined3d: return 4
        }
    }

    private var graphicsHudValue: CyderGraphicsHud {
        let titles = graphicsHud.itemTitles
        let index = max(0, graphicsHud.indexOfSelectedItem)
        guard index < titles.count else { return .off }
        switch titles[index] {
        case "Metal HUD": return .metal
        case "DXVK HUD": return .dxvk
        default: return .off
        }
    }

    private func rebuildGraphicsHudMenu(selecting preferred: CyderGraphicsHud? = nil) {
        let backend = graphicsBackendValue
        let previous = preferred ?? graphicsHudValue
        graphicsHud.removeAllItems()
        var titles = ["關閉", "Metal HUD"]
        if backend == .dxvk {
            titles.append("DXVK HUD")
        }
        graphicsHud.addItems(withTitles: titles)
        let effective = CyderSettings.resolvedGraphicsHud(preference: backend, requested: previous)
        let wanted: String
        switch effective {
        case .metal: wanted = "Metal HUD"
        case .dxvk: wanted = "DXVK HUD"
        case .off: wanted = "關閉"
        }
        if let idx = titles.firstIndex(of: wanted) {
            graphicsHud.selectItem(at: idx)
        } else {
            graphicsHud.selectItem(at: 0)
        }
    }

    private func refreshGraphicsControls() {
        updateD3DMetalMenuItemAvailability()
        updateDxmtMenuItemAvailability()
        CyderGptk.syncEngineLink()
        let backend = graphicsBackendValue
        let showFrameRate = backend == .dxvk
        let showDxvkFrametimes = backend == .dxvk
        let enableDxvkFrametimes = graphicsHudValue == .dxvk
        let showGptkControls = backend != .dxvk && backend != .wined3d && backend != .dxmt
        dxvkFrameRate.isHidden = !showFrameRate
        (dxvkFrameRate.superview as? NSStackView)?.isHidden = !showFrameRate
        dxvkHudFrametimes.isHidden = !showDxvkFrametimes
        dxvkHudFrametimes.isEnabled = enableDxvkFrametimes
        (dxvkHudFrametimes.superview as? NSStackView)?.isHidden = !showDxvkFrametimes
        graphicsHelp.stringValue = switch backend {
        case .default: "帶入預載的遊戲專屬設定；多數遊戲建議使用。"
        case .wined3d: "使用 Wine 內建 Direct3D；相容性較廣，但效能通常較差。"
        case .dxvk: "使用 DXVK 將 Direct3D 轉為 Vulkan，再由 MoltenVK 轉為 Metal。"
        case .dxmt: "使用 DXMT 將 Direct3D 直接轉為 Metal；需要 macOS 14+ 與引擎內建 DXMT。"
        case .d3dmetal: "使用 Apple D3DMetal／GPTK；需要 macOS 14+ 與可用的 GPTK。"
        }
        gptkNote.stringValue = "D3DMetal 可使用本機 CrossOver 內附的 GPTK，或自行從 Apple 下載並安裝；若兩者皆有，Cyder 優先使用已安裝版本。"
        if let info = CyderGptk.activeInfo() {
            d3dmetalStatus.stringValue = info.statusLine
        } else {
            d3dmetalStatus.stringValue = supportsD3DMetalOS
                ? "D3DMetal 不可用：找不到 CrossOver 或已安裝的 GPTK"
                : "D3DMetal 不可用：需要 macOS 14+"
        }
        // d3dmetalStatus and gptkNote sit directly in the tab stack; hide only
        // the views themselves, not superview (that would hide the whole tab).
        d3dmetalStatus.isHidden = !showGptkControls
        installGptkButton.isHidden = !showGptkControls
        removeGptkButton.isHidden = !FileManager.default.fileExists(atPath: CyderPaths.appleGptkRuntime.path)
            || !showGptkControls
        (installGptkButton.superview as? NSStackView)?.isHidden = !showGptkControls
        gptkNote.isHidden = !showGptkControls
    }

    private func showGptkAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
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

    @objc private func executableFontMingLiuChanged() {
        if executableFontMingLiu.indexOfSelectedItem == 0 {
            let alert = NSAlert()
            alert.messageText = "使用細明體前需要先安裝字型"
            alert.informativeText = "請先在 macOS「字體簿」安裝細明體，或將合法取得的 MingLiU 字型安裝到目前的 Wine 環境。Cyder 只切換字體設定，不會提供或自動安裝細明體。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "我知道了")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                executableFontMingLiu.selectItem(at: cyderFontTargetIndex(
                    profileDrafts[selectedProfileID ?? ""]?.fontMingLiuTarget
                        ?? defaultExecutableSettings().fontMingLiuTarget
                        ?? cyderDefaultMingLiuFontTarget()
                ))
            }
        }
        executableSettingChanged()
    }

    @objc private func executableFontSongtiChanged() {
        executableSettingChanged()
    }

    @objc private func executableSyncModeChanged() {
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
        rule.fontMingLiuTarget = value.fontMingLiuTarget
        rule.fontSongtiTarget = value.fontSongtiTarget
        rule.fontSmoothing = value.fontSmoothing
        return rule
    }

    private func captureExecutableSettings() {
        guard let profileID = selectedProfileID else { return }
        let dpiValues = [96, 120, 144, 168, 192, 240]
        var rule = profileDrafts[profileID] ?? defaultExecutableSettings()
        let mode = CyderSyncMode.allCases[max(0, min(executableSyncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
        rule.msync = mode == .msync
        rule.esync = mode == .esync
        rule.retinaMode = executableRetina.state == .on
        rule.dpi = dpiValues[max(0, executableDpi.indexOfSelectedItem)]
        rule.powerMode = ["standard", "energySaving"][max(0, executablePowerMode.indexOfSelectedItem)]
        rule.fontMingLiuTarget = cyderFontTarget(at: executableFontMingLiu.indexOfSelectedItem)
        rule.fontSongtiTarget = cyderFontTarget(at: executableFontSongti.indexOfSelectedItem)
        rule.fontSmoothing = ["off", "grayscale", "cleartype-rgb"][max(0, executableSmoothing.indexOfSelectedItem)]
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
        if executableSyncMode.numberOfItems == 0 {
            executableSyncMode.addItems(withTitles: CyderSyncMode.allCases.map { $0.title })
        }
        executableSyncMode.selectItem(at: CyderSyncMode(
            msync: rule.msync ?? defaults.msync ?? false,
            esync: rule.esync ?? defaults.esync ?? false
        ).rawValue)
        executableRetina.state = (rule.retinaMode ?? defaults.retinaMode ?? true) ? .on : .off
        executableDpi.selectItem(at: dpiValues.firstIndex(of: rule.dpi ?? defaults.dpi ?? 192) ?? 0)
        executablePowerMode.selectItem(at: rule.powerMode == "energySaving" ? 1 : 0)
        executableFontMingLiu.selectItem(at: cyderFontTargetIndex(
            rule.fontMingLiuTarget ?? defaults.fontMingLiuTarget ?? cyderDefaultMingLiuFontTarget()
        ))
        executableFontSongti.selectItem(at: cyderFontTargetIndex(
            rule.fontSongtiTarget ?? defaults.fontSongtiTarget ?? "songti"
        ))
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
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
        executableSyncMode.isEnabled = enabled
        executableRetina.isEnabled = enabled
        executableDpi.isEnabled = enabled
        executablePowerMode.isEnabled = enabled
        executableFontMingLiu.isEnabled = enabled
        executableFontSongti.isEnabled = enabled
        executableSmoothing.isEnabled = enabled
        executableEnvironment.isEnabled = enabled
        executableArguments.isEnabled = enabled
        removeExecutableButton.isEnabled = enabled
        if !enabled {
            executableSyncMode.selectItem(at: CyderSyncMode.off.rawValue)
            executableRetina.state = .off
            executableDpi.selectItem(at: 4)
            executablePowerMode.selectItem(at: 0)
            executableFontMingLiu.selectItem(at: cyderFontTargetIndex(cyderDefaultMingLiuFontTarget()))
            executableFontSongti.selectItem(at: cyderFontTargetIndex("songti"))
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
        let dpiValues = [96, 120, 144, 168, 192, 240]
        syncMode.selectItem(at: CyderSyncMode(msync: value.msync, esync: value.esync ?? false).rawValue)
        updateSyncModeDescription()
        retina.state = value.retinaMode ? .on : .off
        dpi.selectItem(at: dpiValues.firstIndex(of: value.dpi) ?? 0)
        fontMingLiu.selectItem(at: cyderFontTargetIndex(value.fontMingLiuTarget))
        fontSongti.selectItem(at: cyderFontTargetIndex(value.fontSongtiTarget))
        smoothing.selectItem(at: 2)
        graphicsBackend.selectItem(at: 0)
        dxvkFrameRate.selectItem(at: 0)
        rebuildGraphicsHudMenu(selecting: value.graphicsHud)
        dxvkHudFrametimes.state = value.dxvkHudFrametimes ? .on : .off
        wineDiagnostics.selectItem(at: 0)
        diagnosticsWarning.isHidden = true
        refreshGraphicsControls()
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

    private func prefixSettingsChanged() -> Bool {
        let value = store.value
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        return value.retinaMode != (retina.state == .on)
            || value.dpi != dpiValues[max(0, dpi.indexOfSelectedItem)]
            || value.fontMingLiuTarget != cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
            || value.fontSongtiTarget != cyderFontTarget(at: fontSongti.indexOfSelectedItem)
            || value.fontSmoothing != smoothingValues[max(0, smoothing.indexOfSelectedItem)]
    }

    private func sessionSettingsChanged() -> Bool {
        let value = store.value
        let selectedMode = CyderSyncMode.allCases[max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
        if value.msync != (selectedMode == .msync)
            || (value.esync ?? false) != (selectedMode == .esync) {
            return true
        }
        for profileID in deletedProfiles {
            if value.perProfile[profileID] != nil { return true }
        }
        for (profileID, rule) in profileDrafts {
            let stored = value.perProfile[profileID]
            if stored?.msync != rule.msync
                || stored?.esync != rule.esync
                || stored?.powerMode != rule.powerMode
                || stored?.graphicsBackend != rule.graphicsBackend
                || stored?.dxvkFrameRate != rule.dxvkFrameRate {
                return true
            }
        }
        return false
    }

    private func cyderFontTargetIndex(_ target: String) -> Int {
        cyderFontTargetIDs.firstIndex(of: target) ?? 1
    }

    private func cyderFontTarget(at index: Int) -> String {
        cyderFontTargetIDs[max(0, min(index, cyderFontTargetIDs.count - 1))]
    }
}
