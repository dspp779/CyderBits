import Cocoa
import Foundation

private struct CyderWinetricksComponent {
    let title: String
    let verb: String
}

private let cyderWinetricksComponentGroups: [(String, [CyderWinetricksComponent])] = [
    ("Legacy multimedia", [
        CyderWinetricksComponent(title: "Windows Media Player 9", verb: "wmp9"),
        CyderWinetricksComponent(title: "Quartz DirectShow", verb: "quartz"),
        CyderWinetricksComponent(title: "DirectShow Devenum", verb: "devenum"),
        CyderWinetricksComponent(title: "Visual Basic 6 Runtime", verb: "vb6run"),
    ]),
]

/// Loaded with settings on the same bounded background owner, never by menu
/// validation or AppKit control construction.
struct CyderSettingsPresentation {
    var engineVersion = "尚未安裝"
    var hasD3DMetal = false
    var hasDxmt = false
    var hasDxvk = false
    var gptkStatus: String?
    var hasInstalledGptk = false
    var profiles: [CyderProfileRecord] = []
    var defaults = CyderSettings(fontMingLiuTarget: "songti")

    static func load() -> Self {
        var result = Self()
        let caps = CyderGraphicsCapabilities.current(engineRoot: CyderPaths.engine)
        result.hasD3DMetal = CyderGptk.preferredSource() != nil
        result.hasDxmt = caps.hasDxmt; result.hasDxvk = caps.hasDxvk
        result.engineVersion = CyderPaths.installedEngineVersion ?? "尚未安裝"
        result.gptkStatus = CyderGptk.activeInfo()?.statusLine
        result.hasInstalledGptk = FileManager.default.fileExists(atPath: CyderPaths.appleGptkRuntime.path)
        result.profiles = CyderProfileStore(root: CyderPaths.support).listRecords()
        result.defaults = .defaults
        return result
    }
}

private final class CyderSettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class CyderSettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onImmediateSave: ((_ registrySetting: String) async -> Bool)?
    /// Live Wine `reg add` with draft env; return true only after registry apply succeeds.
    var onApplyWhileRunning: ((_ draftEnvironment: [String: String]) async -> Bool)?
    var onRebuild: (() -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onOpenWinetricks: (([String]) -> Void)?
    var onExportLastGameLog: (() -> Void)?
    var onInspectComponents: (() -> Void)?
    var onCleanDebugLogs: (() -> Void)?
    var onScanURIHandlers: ((_ completion: @escaping (CyderURIHandlerRecord?, Bool) -> Void) -> Void)?
    var onEnableURIHandler: ((_ record: CyderURIHandlerRecord) -> Bool)?
    var onDisableURIHandler: (() -> Bool)?
    var onIsCyderURIHandlerDefault: (() -> Bool)?
    var onSaveStarted: (() -> Void)?
    var onSaveFailed: (() -> Void)?
    var onClose: (() -> Void)?
    var hasRunningExes: (() async -> Bool)?
    /// Stops all Cyder Wine processes (wineserver -k) and waits (-w). Returns true on success.
    var onStopAllWine: (() async -> Bool)?
    private var settingsValue = CyderSettings(fontMingLiuTarget: "songti")
    private var presentation = CyderSettingsPresentation()
    private var settingsReady = false
    private var settingsLoadInFlight = false
    private var loadGeneration = UUID()
    private var settingsAccess = CyderSettingsAccess.shared
    var maintenanceGate = CyderOperationGate()
    var runtimePresentationReader: () -> CyderSettingsPresentation = CyderSettingsPresentation.load
    private var maintenanceToken: UUID?
    private var maintenanceAcquisition: UUID?
    private var auxiliaryGeneration = UUID()
    private let applyButton = NSButton()
    private var wineIsRunning = false
    private let engineVersion = NSTextField(labelWithString: "")
    private let syncMode = NSPopUpButton()
    private let syncModeDescription = NSTextField(wrappingLabelWithString: "")
    private let wineLocale = NSPopUpButton()
    private let retina = NSSwitch()
    private let dpi = NSPopUpButton()
    private let fontMingLiu = NSPopUpButton()
    private let fontSongti = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let scrolling = NSSwitch()
    private let graphicsBackend = NSPopUpButton()
    private let moltenvkVariant = NSPopUpButton()
    private let dxvkFrameRate = NSPopUpButton()
    private let graphicsHud = NSPopUpButton()
    private let moltenvkHelp = NSTextField(wrappingLabelWithString: "")
    private let dxvkHudFrametimes = NSSwitch()
    private let graphicsHelp = NSTextField(wrappingLabelWithString: "")
    private let d3dmetalStatus = NSTextField(labelWithString: "")
    private let gptkNote = NSTextField(wrappingLabelWithString: "")
    private let installGptkButton = NSButton()
    private let removeGptkButton = NSButton()
    private let stopAllWineButton = NSButton()
    private var settingsRevision = 0
    private var runningRefreshToken = UUID()
    private var explicitApplyInProgress = false
    private var prefixApplyPending = false
    private let wineDiagnostics = NSPopUpButton()
    private let maplestoryWZCache = NSSwitch()
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
    private var profileRecords: [String: CyderProfileRecord] = [:]
    private var selectedProfileID: String?
    private var profileDrafts: [String: CyderExecutableSettings] = [:]
    private var deletedProfiles: Set<String> = []
    private let status = NSTextField(wrappingLabelWithString: "正在讀取設定…")
    private let retrySettingsButton = NSButton(title: "重試", target: nil, action: nil)
    private var isDirty = false
    private var settingsTabView: NSTabView?
    private var uriHandlerTabItem: NSTabViewItem?
    private var uriHandlerScanGeneration = 0
    private struct CyderURIHandlerRow {
        let record: CyderURIHandlerRecord
        var isCyderDefault: Bool
    }
    private var uriHandlerRows: [CyderURIHandlerRow] = []
    private let uriHandlerTable = NSTableView()
    private let uriHandlerStatusLabel = NSTextField(labelWithString: "開啟偏好設定時會在背景掃描 shared bottle。")
    private let uriHandlerProgress = NSProgressIndicator()
    private let uriHandlerRescanButton = NSButton()

    // Keep the production zero-argument entry explicit. Otherwise overload
    // resolution can select NSWindowController's inherited empty initializer
    // instead of the dependency-injected convenience initializer.
    convenience init() {
        self.init(settingsAccess: .shared)
    }

    convenience init(settingsAccess: CyderSettingsAccess) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        self.settingsAccess = settingsAccess
        window.title = "Cyder 偏好設定"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let background = CyderSettingsBackgroundView(frame: window.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        window.contentView = background
        buildUI()
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        auxiliaryGeneration = UUID()
        maintenanceToken = nil
        if let id = maintenanceAcquisition { maintenanceGate.cancel(id); maintenanceAcquisition = nil }
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
        settingsTabView = tabs
        tabs.addTabViewItem(makeGeneralTab())
        tabs.addTabViewItem(makeDisplayTab())
        tabs.addTabViewItem(makeInputTab())
        tabs.addTabViewItem(makeFontsTab())
        tabs.addTabViewItem(makeGraphicsTab())
        tabs.addTabViewItem(makeAdvancedTab())
        if #available(macOS 11.0, *) {
            tabs.addTabViewItem(makeURIHandlerTab())
        }
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
        retrySettingsButton.target = self
        retrySettingsButton.action = #selector(retrySettings)
        retrySettingsButton.bezelStyle = .rounded
        retrySettingsButton.isHidden = true
        retrySettingsButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(retrySettingsButton)
        status.maximumNumberOfLines = 2
        retina.identifier = NSUserInterfaceItemIdentifier("settings-retina")
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            status.trailingAnchor.constraint(lessThanOrEqualTo: retrySettingsButton.leadingAnchor, constant: -8),
            retrySettingsButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            retrySettingsButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
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
        engineVersion.font = .systemFont(ofSize: 11)
        engineVersion.textColor = .secondaryLabelColor
        engineVersion.alignment = .left
        engineVersion.isSelectable = true
        refreshEngineVersionLabel()
        let engineFooterGap = NSView()
        engineFooterGap.translatesAutoresizingMaskIntoConstraints = false
        engineFooterGap.heightAnchor.constraint(equalToConstant: 16).isActive = true
        wineLocale.removeAllItems()
        wineLocale.addItems(withTitles: CyderWineLocale.menuCases.map { $0.title })
        wineLocale.target = self
        wineLocale.action = #selector(wineLocaleChanged)
        return tab("一般", rows: [
            row("同步機制", syncMode),
            syncModeDescription,
            row("Windows 語系", wineLocale),
            note("系統目前偵測為\(CyderWineLocale.detectedSystemLabel())。指定語系會在下次啟動 EXE 時生效；若該 bottle 的 wineserver 仍在跑，代碼頁要等該 bottle 的 wineserver 結束後才會更新。"),
            engineFooterGap,
            engineVersionFooter(),
        ])
    }

    private func engineVersionFooter() -> NSView {
        let title = NSTextField(labelWithString: "引擎版本")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        let stack = NSStackView(views: [title, engineVersion])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return stack
    }

    @objc private func openWinetricks() {
        let alert = NSAlert()
        alert.messageText = "選擇要安裝的 Windows 元件"
        alert.informativeText = "元件會安裝到 Cyder 的 shared prefix。VC++ Redistributable 與 .NET Desktop Runtime 請下載官方 Windows installer，再直接用 Cyder 開啟；此處保留需要 Wine 專用處理的元件。安裝前請先關閉所有遊戲。"
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

    private func makeInputTab() -> NSTabViewItem {
        scrolling.identifier = NSUserInterfaceItemIdentifier("settings-scrolling")
        scrolling.target = self
        scrolling.action = #selector(scrollingChanged)
        return tab("輸入", rows: [
            row("精準捲動", scrolling),
            note("開啟可能會捲動過快。"),
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
        moltenvkVariant.removeAllItems()
        moltenvkVariant.addItems(withTitles: CyderMoltenvkVariant.allCases.map(\.menuTitle))
        moltenvkVariant.target = self
        moltenvkVariant.action = #selector(moltenvkVariantChanged)
        updateMoltenvkMenuItemAvailability()
        moltenvkHelp.stringValue = "舊 Intel 顯示異常時可改用 1.2.10；Mach Ports 修復由引擎 shim 提供。"
        moltenvkHelp.textColor = .secondaryLabelColor
        moltenvkHelp.font = .systemFont(ofSize: 12)
        moltenvkHelp.maximumNumberOfLines = 3
        moltenvkHelp.widthAnchor.constraint(equalToConstant: 460).isActive = true
        dxvkFrameRate.addItems(withTitles: ["60", "120", "144", "不限制"])
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
            row("MoltenVK", moltenvkVariant),
            moltenvkHelp,
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
        maplestoryWZCache.target = self
        maplestoryWZCache.action = #selector(maplestoryWZCacheChanged)
        stopAllWineButton.title = "關閉所有 Windows 程序"
        stopAllWineButton.bezelStyle = .rounded
        stopAllWineButton.target = self
        stopAllWineButton.action = #selector(stopAllWine)
        return tab("進階", rows: [
            stopAllWineButton,
            rebuild,
            note("重新建立執行 Windows 遊戲所需的環境。遊戲檔案不會刪除，但已安裝的 Windows 元件與自訂設定需要重新套用。"),
            winetricks,
            note("以原生選擇器安裝 WMP、Quartz、Devenum、VB6 等元件到 shared prefix。.NET／Wine Mono 不預裝：需要時 Wine 會提示安裝，或手動執行 install-wine-mono.sh。VC++ 與 .NET Desktop Runtime 請用官方 installer。請先關閉所有遊戲。"),
            row("MapleStory WZ 快取", maplestoryWZCache),
            note("預設開啟，只對 MapleStory 的唯讀 WZ 小讀取啟用 read-ahead。若遇到資源載入異常，可關閉後重新啟動遊戲。"),
        ])
    }

    @available(macOS 11.0, *)
    private func makeURIHandlerTab() -> NSTabViewItem {
        uriHandlerStatusLabel.font = .systemFont(ofSize: 11)
        uriHandlerStatusLabel.textColor = .secondaryLabelColor

        uriHandlerProgress.style = .spinning
        uriHandlerProgress.controlSize = .small
        uriHandlerProgress.isDisplayedWhenStopped = false
        uriHandlerProgress.isHidden = true

        uriHandlerRescanButton.title = "重新掃描"
        uriHandlerRescanButton.bezelStyle = .rounded
        uriHandlerRescanButton.target = self
        uriHandlerRescanButton.action = #selector(rescanURIHandlers)

        uriHandlerTable.headerView = NSTableHeaderView()
        uriHandlerTable.delegate = self
        uriHandlerTable.dataSource = self
        uriHandlerTable.rowHeight = 22
        uriHandlerTable.usesAlternatingRowBackgroundColors = true
        uriHandlerTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        uriHandlerTable.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [
            ("enabled", "啟用", 44),
            ("uri", "URI", 110),
            ("exe", "EXE", 120),
            ("command", "命令", 180),
            ("version", "版本", 70),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            if id == "enabled" {
                let cell = NSButtonCell()
                cell.title = ""
                cell.setButtonType(.switch)
                column.dataCell = cell
            }
            uriHandlerTable.addTableColumn(column)
        }

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = uriHandlerTable
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let loadingRow = NSStackView(views: [uriHandlerProgress, uriHandlerStatusLabel])
        loadingRow.orientation = .horizontal
        loadingRow.spacing = 8
        loadingRow.alignment = .centerY

        let item = NSTabViewItem(identifier: "URI 協定")
        item.label = "URI 協定"
        let stack = NSStackView(views: [
            loadingRow,
            tableScroll,
            uriHandlerRescanButton,
            note("當 gamania Games Manager 在 shared bottle 註冊 gamaniagames:// 後，Cyder 可代為啟動 GGMWebStart.exe。URI 會原樣傳入 Windows，不做 percent-decoding。"),
        ])
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
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(equalToConstant: 120),
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
        ])
        item.view = scroll
        uriHandlerTabItem = item
        return item
    }

    @available(macOS 11.0, *)
    @objc private func rescanURIHandlers() {
        beginURIHandlerScan()
    }

    @available(macOS 11.0, *)
    private func beginURIHandlerScan() {
        guard onScanURIHandlers != nil else {
            uriHandlerStatusLabel.stringValue = "Cyder 無法掃描 URI handler。"
            uriHandlerRows = []
            uriHandlerTable.reloadData()
            return
        }
        uriHandlerScanGeneration += 1
        let generation = uriHandlerScanGeneration
        uriHandlerProgress.isHidden = false
        uriHandlerProgress.startAnimation(nil)
        uriHandlerStatusLabel.stringValue = "掃描中…"
        uriHandlerTable.isEnabled = false
        uriHandlerRescanButton.isEnabled = false

        onScanURIHandlers? { [weak self] record, isCyderDefault in
            guard let self, generation == self.uriHandlerScanGeneration else { return }
            self.applyURIHandlerScanResult(record: record, isCyderDefault: isCyderDefault)
        }
    }

    @available(macOS 11.0, *)
    private func applyURIHandlerScanResult(record: CyderURIHandlerRecord?, isCyderDefault: Bool) {
        uriHandlerProgress.stopAnimation(nil)
        uriHandlerProgress.isHidden = true
        uriHandlerTable.isEnabled = true
        uriHandlerRescanButton.isEnabled = true

        if let record {
            uriHandlerRows = [CyderURIHandlerRow(record: record, isCyderDefault: isCyderDefault)]
            uriHandlerStatusLabel.stringValue = record.isValid
                ? "共 1 個 URI handler"
                : "gamaniagames:// 註冊無效（\(record.status)）"
        } else {
            uriHandlerRows = []
            uriHandlerStatusLabel.stringValue = "尚未偵測到 gamaniagames://；請先在 shared bottle 安裝 gamania Games Manager。"
        }
        uriHandlerTable.reloadData()
    }

    @available(macOS 11.0, *)
    private func refreshURIHandlerCheckboxState() {
        let isDefault = onIsCyderURIHandlerDefault?() ?? false
        guard !uriHandlerRows.isEmpty else { return }
        uriHandlerRows[0].isCyderDefault = isDefault
        uriHandlerTable.reloadData()
    }

    @available(macOS 11.0, *)
    func numberOfRows(in tableView: NSTableView) -> Int {
        uriHandlerRows.count
    }

    @available(macOS 11.0, *)
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < uriHandlerRows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let item = uriHandlerRows[row]
        switch id {
        case "uri":
            return "\(item.record.scheme)://"
        case "exe":
            return item.record.executableName
        case "command":
            return item.record.windowsCommand
        case "version":
            return item.record.version.isEmpty ? "—" : item.record.version
        case "enabled":
            return item.isCyderDefault
        default:
            return nil
        }
    }

    @available(macOS 11.0, *)
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "enabled",
              row < uriHandlerRows.count,
              let wantsEnabled = object as? Bool else { return }
        let record = uriHandlerRows[row].record
        if wantsEnabled {
            guard record.isValid else {
                refreshURIHandlerCheckboxState()
                return
            }
            if onEnableURIHandler?(record) != true {
                refreshURIHandlerCheckboxState()
                return
            }
        } else {
            _ = onDisableURIHandler?()
        }
        refreshURIHandlerCheckboxState()
    }

    @available(macOS 11.0, *)
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard tableColumn?.identifier.rawValue == "enabled", row < uriHandlerRows.count else { return false }
        let item = uriHandlerRows[row]
        return item.record.isValid || item.isCyderDefault
    }

    @available(macOS 11.0, *)
    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        guard row < uriHandlerRows.count, tableColumn?.identifier.rawValue == "command" else { return "" }
        return uriHandlerRows[row].record.windowsCommand
    }

    private func makeDiagnosticsTab() -> NSTabViewItem {
        wineDiagnostics.addItems(withTitles: ["安靜（預設）", "只記錄錯誤", "等待與凍結追蹤", "完整堆疊追蹤"])
        wineDiagnostics.target = self
        wineDiagnostics.action = #selector(wineDiagnosticsChanged)

        diagnosticsWarning.stringValue = "⚠ 除錯記錄可能快速佔用大量磁碟空間，並改變遊戲時序。只在重現問題時短時間開啟；完成後請切回「安靜」，再清理除錯記錄。"
        diagnosticsWarning.textColor = .systemRed
        diagnosticsWarning.font = .boldSystemFont(ofSize: 12)
        diagnosticsWarning.isHidden = true

        let inspect = NSButton(title: "檢查執行元件…", target: self, action: #selector(inspectComponents))
        inspect.bezelStyle = .rounded
        let export = NSButton(title: "匯出上次遊戲記錄…", target: self, action: #selector(exportLastGameLog))
        export.bezelStyle = .rounded
        let cleanup = NSButton(title: "清理除錯記錄…", target: self, action: #selector(cleanDebugLogs))
        cleanup.bezelStyle = .rounded
        return tab("除錯", rows: [
            row("Wine 診斷記錄", wineDiagnostics),
            diagnosticsWarning,
            note("「安靜」不開啟 Wine trace，啟動失敗仍會由程序退出碼判斷；「只記錄錯誤」適合一般排障；「等待與凍結追蹤」用於重現卡住／凍結；「完整堆疊追蹤」僅供短時間重現 exception／unwind 問題。"),
            inspect,
            note("背景唯讀檢查 Wine、DXVK 與 DXMT 的逐檔清單；可取消，不會自動修復。"),
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

    private func refreshEngineVersionLabel() {
        engineVersion.stringValue = presentation.engineVersion
    }

    private func setSettingsControlsEnabled(_ enabled: Bool) {
        var visited = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            if let control = view as? NSControl, control !== status, control !== retrySettingsButton {
                let navigation: [Selector] = [#selector(inspectComponents), #selector(exportLastGameLog), #selector(cleanDebugLogs), #selector(stopAllWine)]
                control.isEnabled = control.action.map { navigation.contains($0) } == true || enabled
            }
            for child in view.subviews { visit(child) }
            if let tabs = view as? NSTabView {
                tabs.tabViewItems.compactMap { $0.view }.forEach(visit)
            }
        }
        if let content = window?.contentView { visit(content) }
    }

    private func reload() {
        guard !settingsLoadInFlight else { return }
        settingsLoadInFlight = true
        let wasReady = settingsReady
        let token = UUID(); loadGeneration = token
        settingsReady = false
        setSettingsControlsEnabled(false)
        setNormalStatus("正在讀取設定…")
        settingsAccess.perform({ store in (store.value, CyderSettingsPresentation.load()) }) { [weak self] update in
            guard let self, self.loadGeneration == token else { return }
            switch update {
            case .ready(let result):
                self.settingsLoadInFlight = false
                self.settingsValue = result.0; self.presentation = result.1; self.settingsReady = true
                self.setSettingsControlsEnabled(true)
                self.applyLoadedSettings()
            case .unconfirmed: self.showSettingsIssue("讀取尚未確認；可關閉視窗，稍後再開啟。")
            case .busy:
                self.settingsLoadInFlight = false; self.settingsReady = wasReady
                self.setSettingsControlsEnabled(wasReady)
                if wasReady { self.refreshGraphicsControls() }
                self.showSettingsIssue("另一項設定操作仍在進行；請稍後重新開啟。")
            case .failed:
                self.settingsLoadInFlight = false
                self.showSettingsIssue("無法讀取設定；保留原檔，請檢查記錄。")
            }
        }
    }

    private func applyLoadedSettings() {
        let value = settingsValue
        syncMode.selectItem(at: CyderSyncMode(msync: value.msync, esync: value.esync ?? false).rawValue)
        updateSyncModeDescription()
        wineLocale.selectItem(at: value.wineLocale.menuIndex)
        scrolling.state = value.scrolling == .precise ? .on : .off
        retina.state = value.retinaMode ? .on : .off
        let dpiValues = [96, 120, 144, 168, 192, 240]
        dpi.selectItem(at: dpiValues.firstIndex(of: value.dpi) ?? 4)
        fontMingLiu.selectItem(at: cyderFontTargetIndex(value.fontMingLiuTarget))
        fontSongti.selectItem(at: cyderFontTargetIndex(value.fontSongtiTarget))
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        smoothing.selectItem(at: smoothingValues.firstIndex(of: value.fontSmoothing) ?? 2)
        graphicsBackend.selectItem(at: graphicsBackendIndex(value.graphicsBackend))
        moltenvkVariant.selectItem(at: value.moltenvkVariant.menuIndex)
        updateMoltenvkMenuItemAvailability()
        dxvkFrameRate.selectItem(at: value.dxvkFrameRate.menuIndex)
        refreshEngineVersionLabel()
        rebuildGraphicsHudMenu(selecting: value.graphicsHud)
        dxvkHudFrametimes.state = value.dxvkHudFrametimes ? .on : .off
        switch value.wineDiagnostics {
        case .quiet: wineDiagnostics.selectItem(at: 0)
        case .errors: wineDiagnostics.selectItem(at: 1)
        case .sync: wineDiagnostics.selectItem(at: 2)
        case .unwind: wineDiagnostics.selectItem(at: 3)
        }
        maplestoryWZCache.state = value.maplestoryWZCache ? .on : .off
        diagnosticsWarning.isHidden = value.wineDiagnostics == .quiet
        refreshGraphicsControls()
        profileDrafts = value.perProfile
        profileRecords = Dictionary(uniqueKeysWithValues: presentation.profiles.map { ($0.profileId, $0) })
        deletedProfiles.removeAll()
        selectedProfileID = nil
        executableName.stringValue = "尚未選擇 EXE"
        refreshExecutableList()
        isDirty = false
        refreshRunningChrome()
    }

    func prepareForDisplay() {
        reload()
        if #available(macOS 11.0, *) {
            beginURIHandlerScan()
        }
    }

    private func refreshRunningChrome(persistPendingWhenIdle: Bool = false) {
        let token = UUID()
        runningRefreshToken = token
        let revision = settingsRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            let running = await self.hasRunningExes?() ?? true
            guard self.runningRefreshToken == token, self.settingsReady, self.settingsRevision == revision else { return }
            self.wineIsRunning = running
            if !running && persistPendingWhenIdle && self.deferredSettingsChanged() {
                self.saveImmediately(registrySetting: "all", deferredChange: true)
                return
            }
            if running && self.deferredSettingsChanged() { self.showDeferredSettingsNotice() }
            else { self.applyButton.isHidden = true; self.setNormalStatus() }
        }
    }

    @objc private func retrySettings() {
        if settingsReady { saveImmediately(registrySetting: "all", deferredChange: true) }
        else { reload() }
    }

    private func showSettingsIssue(_ message: String) {
        setNormalStatus(message)
        retrySettingsButton.isHidden = false
    }

    private func setNormalStatus(_ message: String = "設定已儲存") {
        retrySettingsButton.isHidden = true
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
    }

    private func showDeferredSettingsNotice() {
        applyButton.isHidden = false
        status.stringValue = "待套用：同步機制、高解析度、字體設定。請關閉所有 Windows 程序後按「套用設定」。"
        status.textColor = .systemOrange
        status.font = .boldSystemFont(ofSize: 11)
    }

    private func saveImmediately(registrySetting: String? = nil, deferredChange: Bool = false) {
        guard settingsReady else { return }
        settingsRevision += 1
        let revision = settingsRevision
        Task { @MainActor [weak self] in
            await self?.saveImmediatelyAsync(registrySetting: registrySetting, deferredChange: deferredChange, revision: revision)
        }
    }

    @MainActor private func saveImmediatelyAsync(registrySetting: String?, deferredChange: Bool, revision: Int) async {
        let running = await hasRunningExes?() ?? true
        guard settingsRevision == revision else { return }
        wineIsRunning = running
        if running && deferredChange && deferredSettingsChanged() {
            isDirty = true
            showDeferredSettingsNotice()
            return
        }

        let requiresPrefixApply = !running && (prefixApplyPending || prefixSettingsChanged())
        isDirty = true
        guard await saveControls(persistDeferredSettings: !running, revision: revision, needsPrefixApply: requiresPrefixApply), settingsRevision == revision else { return }
        if !running && requiresPrefixApply {
            status.stringValue = "正在套用設定…"
            let ok = await onImmediateSave?(registrySetting ?? "all") ?? false
            guard settingsRevision == revision else { return }
            prefixApplyPending = !ok
            if !ok {
                showSettingsIssue("設定已儲存，但無法更新 Windows 環境；可重試。")
                status.textColor = .systemRed
                status.font = .systemFont(ofSize: 11)
                return
            }
        }
        isDirty = deferredSettingsChanged()
        if running && isDirty {
            showDeferredSettingsNotice()
        } else {
            setNormalStatus()
        }
    }

    @objc private func applyRunningSettings() {
        guard !explicitApplyInProgress else { return }
        explicitApplyInProgress = true
        settingsRevision += 1
        let revision = settingsRevision
        Task { @MainActor [weak self] in
            await self?.applyRunningSettingsAsync(revision: revision)
        }
    }

    @MainActor private func applyRunningSettingsAsync(revision: Int) async {
        defer { explicitApplyInProgress = false }
        wineIsRunning = await hasRunningExes?() ?? true
        guard settingsRevision == revision else { return }
        guard wineIsRunning else {
            // Wine exited while the window was open — fall back to immediate save.
            saveImmediately(registrySetting: "all", deferredChange: true)
            return
        }
        let draft = draftApplyEnvironment()
        status.stringValue = "正在套用設定…"
        status.textColor = .secondaryLabelColor
        onSaveStarted?()
        let ok = await onApplyWhileRunning?(draft) ?? false
        onSaveFailed?() // clears setup chrome; success path still continues below
        guard settingsRevision == revision else { return }
        guard ok else {
            status.stringValue = "無法寫入 Windows 環境；設定尚未儲存"
            status.textColor = .systemRed
            return
        }
        guard await saveControls(persistDeferredSettings: true, revision: revision), settingsRevision == revision else { return }
        prefixApplyPending = false
        isDirty = false
        applyButton.isHidden = true
        setNormalStatus("設定已儲存；關閉所有 Windows 程序後重新啟動才會生效。")
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

    @objc private func scrollingChanged() {
        // Save the preference only. The next EXE launch performs the backed-up
        // registry update; do not edit live bottles from the preferences UI.
        saveImmediately()
    }

    @objc private func retinaChanged() {
        // RetinaMode changes the effective coordinate scale.  Offer the
        // matching conventional DPI as a starting point, while leaving the
        // popup enabled so users can immediately choose a custom value.
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let targetDPI = retina.state == .on ? 192 : 96
        dpi.selectItem(at: dpiValues.firstIndex(of: targetDPI) ?? 0)
        saveImmediately(registrySetting: "display", deferredChange: true)
    }

    @objc private func dpiChanged() {
        saveImmediately(registrySetting: "dpi", deferredChange: true)
    }

    @objc private func smoothingChanged() {
        saveImmediately(registrySetting: "smoothing", deferredChange: true)
    }

    @objc private func graphicsBackendChanged() {
        let preferred: CyderGraphicsHud = !graphicsBackendValue.usesDxvkTranslation && settingsValue.graphicsHud == .dxvk
            ? .off : settingsValue.graphicsHud
        rebuildGraphicsHudMenu(selecting: preferred)
        refreshGraphicsControls()
        saveImmediately()
    }

    @objc private func moltenvkVariantChanged() {
        saveImmediately()
        // The launcher applies the accepted preference before launching Wine.
        // Changing the UI must not mutate a shared runtime on the AppKit thread.
    }

    private var moltenvkVariantValue: CyderMoltenvkVariant {
        CyderMoltenvkVariant(menuIndex: moltenvkVariant.indexOfSelectedItem)
    }

    private func updateMoltenvkMenuItemAvailability() {
        guard let item = moltenvkVariant.item(at: CyderMoltenvkVariant.v142.menuIndex) else { return }
        item.isEnabled = CyderMoltenvkVariant.hostSupports142
        if !CyderMoltenvkVariant.hostSupports142 {
            item.toolTip = "需要 macOS 12 或更新版本"
            moltenvkVariant.selectItem(at: CyderMoltenvkVariant.v1210.menuIndex)
        } else {
            item.toolTip = nil
        }
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
                switch settingsValue.wineDiagnostics {
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

    @objc private func maplestoryWZCacheChanged() {
        saveImmediately()
    }

    @objc private func exportLastGameLog() {
        onExportLastGameLog?()
    }

    @objc private func inspectComponents() { onInspectComponents?() }

    @objc private func cleanDebugLogs() {
        onCleanDebugLogs?()
    }

    @objc private func stopAllWine() {
        let alert = NSAlert()
        alert.messageText = "關閉所有 Windows 程序？"
        alert.informativeText = "會結束目前 Cyder 使用的 Wine 環境中所有遊戲與相關程序。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "關閉")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopAllWineButton.isEnabled = false
        status.stringValue = "正在關閉 Windows 程序…"
        status.textColor = .secondaryLabelColor
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.onStopAllWine?() ?? false
            self.stopAllWineButton.isEnabled = true
            self.refreshRunningChrome(persistPendingWhenIdle: ok)
            self.status.stringValue = ok ? "已送出環境停止操作" : "環境停止失敗或尚未確認"
            self.status.textColor = ok ? .secondaryLabelColor : .systemRed
        }
    }

    private static let gptkDownloadURL = URL(
        string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit"
    )!

    @objc private func installGptk() {
        guard maintenanceToken == nil else { return }
        let generation = UUID(); auxiliaryGeneration = generation
        let revision = settingsRevision
        setNormalStatus("正在尋找 GPTK…")
        settingsAccess.performWork(CyderGptk.scanEvaluationVolumes) { [weak self] update in
            guard let self, self.auxiliaryGeneration == generation, self.settingsRevision == revision else { return }
            switch update {
            case .ready(let candidates): self.presentGptkCandidates(candidates)
            case .unconfirmed: self.setNormalStatus("尋找 GPTK 尚未確認；可關閉視窗。")
            case .busy: self.setNormalStatus("另一項設定操作仍在進行；請稍後安裝。")
            case .failed: self.setNormalStatus("無法讀取 GPTK 來源；請稍後再試。")
            }
        }
    }

    private func presentGptkCandidates(_ candidates: [CyderGptkVolumeCandidate]) {
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
        performRuntimeMaintenance {
            try CyderGptk.install(from: chosen)
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
        performRuntimeMaintenance(CyderGptk.removeRuntimeInstall)
    }

    /// Holds the same all-environment lease used by launcher mutations until
    /// the real filesystem work returns, even if its UI observation expires.
    func performRuntimeMaintenance(_ work: @escaping () throws -> Void) {
        guard maintenanceToken == nil else { return }
        let token = UUID(); maintenanceToken = token
        setNormalStatus("正在等待其他環境操作完成…")
        let gate = maintenanceGate
        maintenanceAcquisition = gate.acquire(.allEnvironments) { [weak self] lease in
            guard let self, self.maintenanceToken == token else {
                if let lease { gate.release(lease) }; return
            }
            self.maintenanceAcquisition = nil
            guard let lease else {
                self.maintenanceToken = nil
                self.setNormalStatus("元件更新尚未開始；請稍後再試。")
                return
            }
            self.setNormalStatus("正在更新圖形元件…")
            self.settingsAccess.performWork({
                try CyderExecutionOwner.withScope(root: CyderPaths.support.appendingPathComponent("execution-owners"), scope: nil, work)
            }, onRelease: { gate.release(lease) }) { [weak self] update in
                guard let self, self.maintenanceToken == token else { return }
                switch update {
                case .ready:
                    self.maintenanceToken = nil
                    self.setNormalStatus("圖形元件已更新")
                    self.refreshRuntimePresentation()
                case .unconfirmed: self.setNormalStatus("元件更新尚未確認；關閉視窗不代表取消。")
                case .busy:
                    self.maintenanceToken = nil
                    self.setNormalStatus("另一項設定操作仍在進行；請稍後再試。")
                case .failed:
                    self.maintenanceToken = nil
                    self.setNormalStatus("圖形元件更新失敗；請檢查來源後再試。")
                }
            }
        }
    }

    private func refreshRuntimePresentation() {
        let generation = UUID(); auxiliaryGeneration = generation
        settingsAccess.performWork(runtimePresentationReader) { [weak self] update in
            guard let self, self.auxiliaryGeneration == generation else { return }
            switch update {
            case .ready(let presentation):
                self.presentation = presentation; self.refreshGraphicsControls()
                self.setNormalStatus("圖形元件已更新")
            case .unconfirmed: self.setNormalStatus("元件已更新；顯示狀態仍在確認。")
            case .busy, .failed: self.setNormalStatus("元件已更新；請重新開啟偏好設定以更新顯示。")
            }
        }
    }

    @objc private func wineLocaleChanged() {
        saveImmediately()
    }

    @objc private func syncModeChanged() {
        updateSyncModeDescription()
        saveImmediately(deferredChange: true)
    }

    @MainActor private func saveControls(persistDeferredSettings: Bool = true, revision: Int, needsPrefixApply: Bool = false) async -> Bool {
        guard settingsReady else { return false }
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        var draft = settingsValue

        let previousProfiles = draft.perProfile
        let mode = CyderSyncMode.allCases[max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
        if persistDeferredSettings {
            draft.msync = mode == .msync
            draft.esync = mode == .esync
            draft.retinaMode = retina.state == .on
            draft.dpi = dpiValues[max(0, dpi.indexOfSelectedItem)]
            draft.fontMingLiuTarget = cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
            draft.fontSongtiTarget = cyderFontTarget(at: fontSongti.indexOfSelectedItem)
            draft.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
        }
        draft.scrolling = scrolling.state == .on ? .precise : .traditional
        draft.graphicsBackend = graphicsBackendValue
        draft.moltenvkVariant = moltenvkVariantValue
        draft.dxvkFrameRate = CyderDxvkFrameRate(menuIndex: dxvkFrameRate.indexOfSelectedItem)
        draft.graphicsHud = graphicsHudValue
        draft.dxvkHudFrametimes = dxvkHudFrametimes.state == .on
        switch wineDiagnostics.indexOfSelectedItem {
        case 1: draft.wineDiagnostics = .errors
        case 2: draft.wineDiagnostics = .sync
        case 3: draft.wineDiagnostics = .unwind
        default: draft.wineDiagnostics = .quiet
        }
        draft.wineLocale = CyderWineLocale(menuIndex: wineLocale.indexOfSelectedItem)
        draft.maplestoryWZCache = maplestoryWZCache.state == .on
        for profileID in deletedProfiles {
            draft.perProfile.removeValue(forKey: profileID)
        }
        for (profileID, rule) in profileDrafts where !deletedProfiles.contains(profileID) {
            var next = rule
            if !persistDeferredSettings {
                let previous = previousProfiles[profileID]
                next.msync = previous?.msync
                next.esync = previous?.esync
                next.retinaMode = previous?.retinaMode
                next.dpi = previous?.dpi
                next.fontMingLiuTarget = previous?.fontMingLiuTarget
                next.fontSongtiTarget = previous?.fontSongtiTarget
                next.fontSmoothing = previous?.fontSmoothing
            }
            draft.perProfile[profileID] = next
        }
        let patch = CyderSettingsPatch(before: settingsValue, after: draft)
        status.stringValue = "正在儲存…"
        return await withCheckedContinuation { continuation in
            var replied = false
            settingsAccess.perform({ store in try store.apply(patch); return store.value }) { [weak self] update in
                func finish(_ success: Bool) {
                    guard !replied else { return }; replied = true; continuation.resume(returning: success)
                }
                guard let self else { finish(false); return }
                switch update {
                case .ready(let value):
                    self.settingsValue = value
                    self.prefixApplyPending = self.prefixApplyPending || needsPrefixApply
                    if self.settingsRevision == revision {
                        self.isDirty = false; self.setNormalStatus("已儲存")
                    }
                    finish(true)
                case .unconfirmed:
                    // Keep the continuation until the physical outcome. Ending
                    // it here would skip the required prefix apply on late save.
                    if self.settingsRevision == revision { self.setNormalStatus("儲存尚未確認；仍在追蹤實際結果。") }
                case .busy:
                    if self.settingsRevision == revision { self.showSettingsIssue("另一項設定操作仍在進行；草稿尚未儲存。") }
                    finish(false)
                case .failed:
                    if self.settingsRevision == revision { self.showSettingsIssue("無法儲存或設定已被其他視窗修改；草稿仍保留。") }
                    finish(false)
                }
            }
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
                fontMingLiu.selectItem(at: cyderFontTargetIndex(settingsValue.fontMingLiuTarget))
            }
        }
        saveImmediately(registrySetting: "font-mingliu", deferredChange: true)
    }

    @objc private func fontSongtiChanged() {
        saveImmediately(registrySetting: "font-songti", deferredChange: true)
    }

    private var supportsD3DMetalOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
    }

    private var canSelectD3DMetal: Bool {
        supportsD3DMetalOS && presentation.hasD3DMetal
    }

    /// DXMT raises the OS floor to macOS 15 (Sequoia); it does not share
    /// D3DMetal's macOS 14 floor.
    private var supportsDxmtOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    private var canSelectDxmt: Bool {
        supportsDxmtOS && presentation.hasDxmt
    }

    private var canSelectDxvk: Bool {
        presentation.hasDxvk
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
        } else if !presentation.hasD3DMetal {
            item.toolTip = "需要本機 CrossOver 或已安裝的評估版 GPTK"
        } else {
            item.toolTip = nil
        }
    }

    private func updateDxmtMenuItemAvailability() {
        guard let item = graphicsBackend.item(at: 2) else { return }
        item.isEnabled = canSelectDxmt
        if !supportsDxmtOS {
            item.toolTip = "需要 macOS 15+"
        } else if !presentation.hasDxmt {
            item.toolTip = "需要已安裝的 DXMT 圖形元件"
        } else {
            item.toolTip = nil
        }
    }

    private func updateDxvkMenuItemAvailability() {
        guard let item = graphicsBackend.item(at: 3) else { return }
        item.isEnabled = canSelectDxvk
        if !canSelectDxvk {
            item.toolTip = "需要已安裝的 DXVK 圖形元件"
        } else {
            item.toolTip = nil
        }
    }

    private var graphicsBackendValue: CyderGraphicsBackend {
        switch graphicsBackend.indexOfSelectedItem {
        case 1: return canSelectD3DMetal ? .d3dmetal : .default
        case 2: return canSelectDxmt ? .dxmt : .default
        case 3: return canSelectDxvk ? .dxvk : .default
        case 4: return .wined3d
        default: return .default
        }
    }

    private func graphicsBackendIndex(_ value: CyderGraphicsBackend) -> Int {
        switch value {
        case .default: return 0
        case .d3dmetal: return canSelectD3DMetal ? 1 : 0
        case .dxmt: return canSelectDxmt ? 2 : 0
        case .dxvk: return canSelectDxvk ? 3 : 0
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
        if backend.usesDxvkTranslation {
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
        updateDxvkMenuItemAvailability()
        updateMoltenvkMenuItemAvailability()
        let backend = graphicsBackendValue
        let showFrameRate = backend.usesFrameLimiter
        let showDxvkFrametimes = backend.usesDxvkTranslation
        let showMoltenvk = backend.usesDxvkTranslation
        let enableDxvkFrametimes = graphicsHudValue == .dxvk
        let showGptkControls = supportsD3DMetalOS
            && backend != .dxvk && backend != .wined3d && backend != .dxmt
        moltenvkVariant.isHidden = !showMoltenvk
        (moltenvkVariant.superview as? NSStackView)?.isHidden = !showMoltenvk
        moltenvkHelp.isHidden = !showMoltenvk
        dxvkFrameRate.isHidden = !showFrameRate
        (dxvkFrameRate.superview as? NSStackView)?.isHidden = !showFrameRate
        dxvkHudFrametimes.isHidden = !showDxvkFrametimes
        dxvkHudFrametimes.isEnabled = enableDxvkFrametimes
        (dxvkHudFrametimes.superview as? NSStackView)?.isHidden = !showDxvkFrametimes
        graphicsHelp.stringValue = switch backend {
        case .default: "帶入預載的遊戲專屬設定；MapleStory 會依 macOS 版本自動選 DXMT 或 DXVK。"
        case .wined3d: "使用 Wine 內建 Direct3D；相容性較廣，但效能通常較差。"
        case .dxvk: "使用 DXVK 將 Direct3D 轉為 Vulkan，再由 MoltenVK 轉為 Metal。"
        case .dxmt: "使用 DXMT 將 Direct3D 直接轉為 Metal；需要 macOS 15+ 與引擎內建 DXMT。"
        case .d3dmetal: "使用 Apple D3DMetal／GPTK；需要 macOS 14+ 與可用的 GPTK。"
        }
        gptkNote.stringValue = "D3DMetal 可使用本機 CrossOver 內附的 GPTK，或自行從 Apple 下載並安裝；若兩者皆有，Cyder 優先使用已安裝版本。"
        if let line = presentation.gptkStatus {
            d3dmetalStatus.stringValue = line
        } else {
            d3dmetalStatus.stringValue = supportsD3DMetalOS
                ? "D3DMetal 不可用：找不到 CrossOver 或已安裝的 GPTK"
                : "D3DMetal 不可用：需要 macOS 14+"
        }
        // d3dmetalStatus and gptkNote sit directly in the tab stack; hide only
        // the views themselves, not superview (that would hide the whole tab).
        d3dmetalStatus.isHidden = !showGptkControls
        installGptkButton.isHidden = !showGptkControls
        removeGptkButton.isHidden = !presentation.hasInstalledGptk
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
        resolveSelectedExecutable(url)
    }

    func resolveSelectedExecutable(_ url: URL) {
        let generation = UUID(); auxiliaryGeneration = generation
        let revision = settingsRevision
        setNormalStatus("正在確認遊戲環境…")
        settingsAccess.performWork({ CyderProfileStore(root: CyderPaths.support).resolve(executable: url) }) { [weak self] update in
            guard let self, self.auxiliaryGeneration == generation, self.settingsRevision == revision else { return }
            switch update {
            case .ready(let state): self.presentSelectedExecutable(url, state: state)
            case .unconfirmed: self.setNormalStatus("遊戲環境尚未確認；可關閉視窗。")
            case .busy: self.setNormalStatus("另一項設定操作仍在進行；請稍後選取。")
            case .failed: self.setNormalStatus("無法確認遊戲環境；請稍後再試。")
            }
        }
    }

    private func presentSelectedExecutable(_ url: URL, state: CyderProfileState) {
        switch state {
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
        saveImmediately()
    }

    @objc private func executableSettingChanged(deferredChange: Bool = false) {
        executableRecommendation.selectItem(at: 0)
        captureExecutableSettings()
        saveImmediately(deferredChange: deferredChange)
    }

    @objc private func executableRetinaChanged() {
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let targetDPI = executableRetina.state == .on ? 192 : 96
        executableDpi.selectItem(at: dpiValues.firstIndex(of: targetDPI) ?? 0)
        executableSettingChanged(deferredChange: true)
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
        executableSettingChanged(deferredChange: true)
    }

    @objc private func executableFontSongtiChanged() {
        executableSettingChanged(deferredChange: true)
    }

    @objc private func executableSyncModeChanged() {
        executableSettingChanged(deferredChange: true)
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
        saveImmediately(deferredChange: true)
    }

    private func defaultExecutableSettings() -> CyderExecutableSettings {
        let value = settingsValue
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
        executableRetina.state = (rule.retinaMode ?? defaults.retinaMode ?? false) ? .on : .off
        executableDpi.selectItem(at: dpiValues.firstIndex(of: rule.dpi ?? defaults.dpi ?? 96) ?? 0)
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
        let value = presentation.defaults
        let dpiValues = [96, 120, 144, 168, 192, 240]
        syncMode.selectItem(at: CyderSyncMode(msync: value.msync, esync: value.esync ?? false).rawValue)
        updateSyncModeDescription()
        wineLocale.selectItem(at: value.wineLocale.menuIndex)
        scrolling.state = .off
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
        maplestoryWZCache.state = value.maplestoryWZCache ? .on : .off
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
        let value = settingsValue
        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        return value.retinaMode != (retina.state == .on)
            || value.dpi != dpiValues[max(0, dpi.indexOfSelectedItem)]
            || value.fontMingLiuTarget != cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
            || value.fontSongtiTarget != cyderFontTarget(at: fontSongti.indexOfSelectedItem)
            || value.fontSmoothing != smoothingValues[max(0, smoothing.indexOfSelectedItem)]
    }

    /// Settings that cannot be committed while a shared Wine session is live.
    /// Keep this separate from graphics/HUD/diagnostics so those controls can
    /// continue to save immediately while a game is running.
    private func deferredSettingsChanged() -> Bool {
        let value = settingsValue
        let selectedMode = CyderSyncMode.allCases[max(0, min(syncMode.indexOfSelectedItem, CyderSyncMode.allCases.count - 1))]
        if value.msync != (selectedMode == .msync)
            || (value.esync ?? false) != (selectedMode == .esync) {
            return true
        }

        let dpiValues = [96, 120, 144, 168, 192, 240]
        let smoothingValues = ["off", "grayscale", "cleartype-rgb"]
        if value.retinaMode != (retina.state == .on)
            || value.dpi != dpiValues[max(0, dpi.indexOfSelectedItem)]
            || value.fontMingLiuTarget != cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
            || value.fontSongtiTarget != cyderFontTarget(at: fontSongti.indexOfSelectedItem)
            || value.fontSmoothing != smoothingValues[max(0, smoothing.indexOfSelectedItem)] {
            return true
        }

        for (profileID, rule) in profileDrafts where !deletedProfiles.contains(profileID) {
            let stored = value.perProfile[profileID]
            if stored?.msync != rule.msync
                || stored?.esync != rule.esync
                || stored?.retinaMode != rule.retinaMode
                || stored?.dpi != rule.dpi
                || stored?.fontMingLiuTarget != rule.fontMingLiuTarget
                || stored?.fontSongtiTarget != rule.fontSongtiTarget
                || stored?.fontSmoothing != rule.fontSmoothing {
                return true
            }
        }
        return false
    }

    private func sessionSettingsChanged() -> Bool {
        let value = settingsValue
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
