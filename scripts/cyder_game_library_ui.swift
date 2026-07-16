import Cocoa
import Foundation
import UniformTypeIdentifiers

private final class CyderGameTileView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var isTileSelected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isTileSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        if event.clickCount >= 2 {
            onDoubleClick?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CyderGameTileItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var tile: CyderGameTileView { view as! CyderGameTileView }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        let tile = CyderGameTileView(frame: NSRect(x: 0, y: 0, width: 126, height: 132))
        tile.wantsLayer = true
        view = tile

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .center
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.textColor = .controlAccentColor
        status.translatesAutoresizingMaskIntoConstraints = false

        tile.addSubview(icon)
        tile.addSubview(nameLabel)
        tile.addSubview(status)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.topAnchor.constraint(equalTo: tile.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalToConstant: 76),
            nameLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            status.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
        tile.onClick = { [weak self] in self?.onClick?() }
        tile.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
    }

    func configure(record: CyderGameRecord, independent: Bool) {
        let path = record.executablePath
        let image = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSImage(named: NSImage.applicationIconName)
        icon.image = image
        icon.toolTip = path
        nameLabel.stringValue = record.displayName
        nameLabel.font = .systemFont(ofSize: 12, weight: independent ? .semibold : .regular)
        status.stringValue = independent ? "獨立設定" : ""
        tile.isTileSelected = isSelected
    }

    override var isSelected: Bool {
        didSet {
            if isViewLoaded { tile.isTileSelected = isSelected }
        }
    }
}

final class CyderGameLibraryWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource {
    var onLaunch: ((URL) -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onClose: (() -> Void)?

    private let libraryStore = CyderGameLibraryStore.shared
    private let profileStore = CyderProfileStore(root: CyderPaths.support)
    private let settingsStore = CyderSettingsStore.shared
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "尚未加入遊戲\n按上方「加入遊戲」開始建立你的遊戲庫")
    private let detailTitle = NSTextField(labelWithString: "選擇一個遊戲")
    private let detailPath = NSTextField(wrappingLabelWithString: "")
    private let detailStatus = NSTextField(labelWithString: "")
    private let detailScope = NSTextField(labelWithString: "")
    private let detailMsync = NSSwitch()
    private let detailEsync = NSSwitch()
    private let detailRetina = NSSwitch()
    private let detailDpi = NSPopUpButton()
    private let detailPower = NSPopUpButton()
    private let detailFont = NSPopUpButton()
    private let detailSmoothing = NSPopUpButton()
    private let detailEnvironment = NSTextField()
    private let detailArguments = NSTextField()
    private let createProfileButton = NSButton()
    private let removeProfileButton = NSButton()
    private let launchButton = NSButton()
    private let panelScroll = NSScrollView()
    private var games: [CyderGameRecord] = []
    private var selectedGameID: String?
    private var independentIDs: Set<String> = []
    private var isLoadingDetail = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Cyder 遊戲庫"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 560)
        window.center()
        buildUI()
        prepareForDisplay()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func prepareForDisplay() {
        libraryStore.reload()
        let profiles = profileStore.listRecords()
        try? libraryStore.merge(profileRecords: profiles)
        games = libraryStore.games
        independentIDs = Set(profiles.map(\.profileId))
        reloadGrid()
        if let selectedGameID, games.contains(where: { $0.id == selectedGameID }) {
            showDetail(for: games.first { $0.id == selectedGameID })
        } else {
            selectedGameID = games.first?.id
            showDetail(for: games.first)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let heading = NSTextField(labelWithString: "遊戲庫")
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(labelWithString: "集中管理每個 Windows 遊戲的啟動環境與顯示設定")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let add = NSButton(title: "加入遊戲…", target: self, action: #selector(addGame))
        add.bezelStyle = .rounded
        add.controlSize = .large
        let headerText = NSStackView(views: [heading, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        let header = NSStackView(views: [headerText, NSView(), add])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        configureCollectionView()
        let libraryScroll = NSScrollView()
        libraryScroll.hasVerticalScroller = true
        libraryScroll.autohidesScrollers = true
        libraryScroll.drawsBackground = false
        libraryScroll.documentView = collectionView
        libraryScroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let libraryPane = NSView()
        libraryPane.translatesAutoresizingMaskIntoConstraints = false
        libraryPane.addSubview(libraryScroll)
        libraryPane.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            libraryScroll.leadingAnchor.constraint(equalTo: libraryPane.leadingAnchor),
            libraryScroll.trailingAnchor.constraint(equalTo: libraryPane.trailingAnchor),
            libraryScroll.topAnchor.constraint(equalTo: libraryPane.topAnchor),
            libraryScroll.bottomAnchor.constraint(equalTo: libraryPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: libraryPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: libraryPane.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 250),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(libraryPane)
        split.addArrangedSubview(makeDetailPane())
        split.setPosition(610, ofDividerAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(split)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func configureCollectionView() {
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.register(CyderGameTileItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("CyderGameTileItem"))
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 126, height: 132)
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        collectionView.collectionViewLayout = layout
    }

    private func makeDetailPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        panelScroll.hasVerticalScroller = true
        panelScroll.autohidesScrollers = true
        panelScroll.drawsBackground = false
        panelScroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        detailTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        detailTitle.maximumNumberOfLines = 2
        detailPath.textColor = .secondaryLabelColor
        detailPath.font = .systemFont(ofSize: 11)
        detailPath.maximumNumberOfLines = 3
        detailScope.font = .systemFont(ofSize: 12, weight: .medium)
        detailStatus.font = .systemFont(ofSize: 11)
        detailStatus.textColor = .secondaryLabelColor
        launchButton.title = "開啟遊戲"
        launchButton.target = self
        launchButton.action = #selector(launchSelectedGame)
        launchButton.bezelStyle = .rounded
        createProfileButton.title = "為遊戲建立獨立設定…"
        createProfileButton.target = self
        createProfileButton.action = #selector(createIndependentProfile)
        createProfileButton.bezelStyle = .rounded
        removeProfileButton.title = "移除獨立設定"
        removeProfileButton.target = self
        removeProfileButton.action = #selector(removeIndependentProfile)
        removeProfileButton.bezelStyle = .rounded

        detailDpi.addItems(withTitles: dpiTitles)
        detailPower.addItems(withTitles: ["標準", "省電"])
        detailFont.addItems(withTitles: ["宋體（Songti TC）", "細明體（MingLiU）"])
        detailSmoothing.addItems(withTitles: ["關閉", "灰階", "ClearType RGB", "ClearType BGR"])
        detailEnvironment.placeholderString = "KEY=value；多組以 ; 分隔"
        detailArguments.placeholderString = "參數1 | 參數2"
        [detailEnvironment, detailArguments].forEach {
            $0.widthAnchor.constraint(equalToConstant: 215).isActive = true
            $0.target = self
            $0.action = #selector(detailTextChanged)
        }
        detailMsync.target = self
        detailMsync.action = #selector(detailMsyncChanged)
        detailEsync.target = self
        detailEsync.action = #selector(detailEsyncChanged)
        detailRetina.target = self
        detailRetina.action = #selector(detailRetinaChanged)
        detailDpi.target = self
        detailDpi.action = #selector(detailControlChanged)
        detailPower.target = self
        detailPower.action = #selector(detailControlChanged)
        detailFont.target = self
        detailFont.action = #selector(detailControlChanged)
        detailSmoothing.target = self
        detailSmoothing.action = #selector(detailControlChanged)

        stack.addArrangedSubview(detailTitle)
        stack.addArrangedSubview(detailPath)
        stack.addArrangedSubview(detailScope)
        let actions = NSStackView(views: [launchButton, createProfileButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(detailStatus)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("遊戲設定"))
        stack.addArrangedSubview(row("MSync", detailMsync))
        stack.addArrangedSubview(row("ESync", detailEsync))
        stack.addArrangedSubview(row("Retina Mode", detailRetina))
        stack.addArrangedSubview(row("縮放比例 / DPI", detailDpi))
        stack.addArrangedSubview(row("能源模式", detailPower))
        stack.addArrangedSubview(row("遊戲字體", detailFont))
        stack.addArrangedSubview(row("字體平滑", detailSmoothing))
        stack.addArrangedSubview(row("環境變數", detailEnvironment))
        stack.addArrangedSubview(row("命令列參數", detailArguments))
        stack.addArrangedSubview(note("未建立獨立設定時，這裡會顯示全域值但不可修改。建立後，此遊戲會使用自己的 Wine prefix。"))
        stack.addArrangedSubview(removeProfileButton)

        content.addSubview(stack)
        panelScroll.documentView = content
        container.addSubview(panelScroll)
        NSLayoutConstraint.activate([
            panelScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panelScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panelScroll.topAnchor.constraint(equalTo: container.topAnchor),
            panelScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: panelScroll.contentView.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: panelScroll.contentView.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: panelScroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: panelScroll.contentView.widthAnchor, constant: -44),
            content.heightAnchor.constraint(greaterThanOrEqualTo: panelScroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        return container
    }

    private var dpiTitles: [String] {
        ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"]
    }

    private func sectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return line
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 5
        label.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return label
    }

    private func reloadGrid() {
        collectionView.reloadData()
        emptyLabel.isHidden = !games.isEmpty
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        games.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("CyderGameTileItem")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! CyderGameTileItem
        let game = games[indexPath.item]
        item.onClick = { [weak self] in self?.selectGame(game) }
        item.onDoubleClick = { [weak self] in self?.launch(game) }
        item.configure(record: game, independent: independentIDs.contains(game.id))
        item.isSelected = game.id == selectedGameID
        return item
    }

    private func selectGame(_ game: CyderGameRecord) {
        selectedGameID = game.id
        collectionView.reloadData()
        showDetail(for: game)
    }

    private func showDetail(for game: CyderGameRecord?) {
        guard let game else {
            detailTitle.stringValue = "選擇一個遊戲"
            detailPath.stringValue = ""
            detailScope.stringValue = ""
            setDetailControlsEnabled(false)
            launchButton.isEnabled = false
            createProfileButton.isEnabled = false
            removeProfileButton.isEnabled = false
            return
        }
        selectedGameID = game.id
        isLoadingDetail = true
        let independent = independentIDs.contains(game.id)
        detailTitle.stringValue = game.displayName
        detailPath.stringValue = game.executablePath
        detailScope.stringValue = independent ? "● 獨立設定已啟用" : "使用全域設定"
        detailScope.textColor = independent ? .controlAccentColor : .secondaryLabelColor
        let global = settingsStore.value
        let rule = settingsStore.value.perProfile[game.id]
        let msync = rule?.msync ?? global.msync
        let esync = rule?.esync ?? (global.esync ?? false)
        let retina = rule?.retinaMode ?? global.retinaMode
        let dpi = rule?.dpi ?? global.dpi
        let font = rule?.fontPreset ?? global.fontPreset
        let smoothing = rule?.fontSmoothing ?? global.fontSmoothing
        let power = rule?.powerMode == "energySaving"
        detailMsync.state = msync ? .on : .off
        detailEsync.state = esync && !msync ? .on : .off
        detailRetina.state = retina ? .on : .off
        detailDpi.selectItem(at: dpiValues.firstIndex(of: dpi) ?? 4)
        detailPower.selectItem(at: power ? 1 : 0)
        detailFont.selectItem(at: font == "mingliu" ? 1 : 0)
        detailSmoothing.selectItem(at: smoothingValues.firstIndex(of: smoothing) ?? 2)
        detailEnvironment.stringValue = rule?.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") ?? ""
        detailArguments.stringValue = rule?.arguments.joined(separator: " | ") ?? ""
        let executableExists = FileManager.default.fileExists(atPath: game.executablePath)
        launchButton.isEnabled = executableExists
        createProfileButton.isEnabled = executableExists && !independent
        removeProfileButton.isEnabled = independent
        createProfileButton.isHidden = independent
        removeProfileButton.isHidden = !independent
        detailStatus.stringValue = FileManager.default.fileExists(atPath: game.executablePath)
            ? (independent ? "獨立設定會在下次啟動此遊戲時生效" : "全域設定會套用到共用環境")
            : "找不到 EXE，請重新加入遊戲庫"
        setDetailControlsEnabled(independent)
        isLoadingDetail = false
    }

    private var dpiValues: [Int] { [96, 120, 144, 168, 192, 240] }
    private var smoothingValues: [String] { ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"] }

    private func setDetailControlsEnabled(_ enabled: Bool) {
        [detailMsync, detailEsync, detailRetina, detailDpi, detailPower, detailFont, detailSmoothing, detailEnvironment, detailArguments].forEach {
            $0.isEnabled = enabled
        }
    }

    @objc private func addGame() {
        let panel = NSOpenPanel()
        panel.title = "加入 Windows 遊戲"
        panel.message = "選擇 Windows 遊戲執行檔 (.exe)"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            if let exeType = UTType(filenameExtension: "exe") {
                panel.allowedContentTypes = [exeType, .data]
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let record = try libraryStore.add(executable: url)
            games = libraryStore.games
            selectedGameID = record.id
            let profiles = profileStore.listRecords()
            independentIDs = Set(profiles.map(\.profileId))
            reloadGrid()
            showDetail(for: record)
        } catch {
            showAlert(title: "無法加入遊戲", message: error.localizedDescription)
        }
    }

    @objc private func launchSelectedGame() {
        guard let game = selectedGame else { return }
        launch(game)
    }

    private func launch(_ game: CyderGameRecord) {
        guard FileManager.default.fileExists(atPath: game.executablePath) else {
            showAlert(title: "找不到遊戲", message: "這個 EXE 已不在原本的位置：\n\n\(game.executablePath)")
            return
        }
        onLaunch?(game.executableURL)
    }

    @objc private func createIndependentProfile() {
        guard let game = selectedGame else { return }
        let alert = NSAlert()
        alert.messageText = "為這個遊戲建立獨立設定？"
        alert.informativeText = "Cyder 會複製一份專屬的 Windows prefix 給「\(game.displayName)」。這不會修改遊戲檔案，也不會影響其他遊戲。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "建立獨立設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onCreateProfile?(game.executableURL)
    }

    @objc private func removeIndependentProfile() {
        guard let game = selectedGame else { return }
        let alert = NSAlert()
        alert.messageText = "移除「\(game.displayName)」的獨立設定？"
        alert.informativeText = "這會刪除該遊戲專屬的 Wine prefix，遊戲檔案與遊戲庫項目不會刪除；之後會改用全域設定與共用 prefix。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除獨立設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        detailStatus.stringValue = "正在移除獨立設定…"
        setDetailControlsEnabled(false)
        launchButton.isEnabled = false
        removeProfileButton.isEnabled = false
        onRemoveProfile?(game.executableURL) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.independentIDs.remove(game.id)
                self.showDetail(for: game)
                self.collectionView.reloadData()
            } else {
                self.showDetail(for: game)
                self.detailStatus.stringValue = "移除失敗，請查看錯誤訊息後再試"
            }
        }
    }

    @objc private func detailMsyncChanged() {
        if detailMsync.state == .on { detailEsync.state = .off }
        saveSelectedRule()
    }

    @objc private func detailEsyncChanged() {
        if detailEsync.state == .on { detailMsync.state = .off }
        saveSelectedRule()
    }

    @objc private func detailRetinaChanged() {
        let target = detailRetina.state == .on ? 192 : 96
        detailDpi.selectItem(at: dpiValues.firstIndex(of: target) ?? 0)
        saveSelectedRule()
    }

    @objc private func detailControlChanged() { saveSelectedRule() }
    @objc private func detailTextChanged() { saveSelectedRule() }

    private func saveSelectedRule() {
        guard !isLoadingDetail, let game = selectedGame, independentIDs.contains(game.id) else { return }
        var rule = settingsStore.value.perProfile[game.id] ?? defaultRule()
        rule.msync = detailMsync.state == .on
        rule.esync = detailEsync.state == .on
        rule.retinaMode = detailRetina.state == .on
        rule.dpi = dpiValues[max(0, detailDpi.indexOfSelectedItem)]
        rule.powerMode = detailPower.indexOfSelectedItem == 1 ? "energySaving" : "standard"
        rule.fontPreset = detailFont.indexOfSelectedItem == 1 ? "mingliu" : "songti"
        rule.fontSmoothing = smoothingValues[max(0, detailSmoothing.indexOfSelectedItem)]
        rule.environment = detailEnvironment.stringValue
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { entry -> (String, String)? in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                let key = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(entry[entry.index(after: separator)...])
                return (key, value)
            }
            .reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        rule.arguments = detailArguments.stringValue
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try settingsStore.update { $0.perProfile[game.id] = rule }
            detailStatus.stringValue = "已儲存；下次啟動此遊戲時生效"
            detailStatus.textColor = .secondaryLabelColor
        } catch {
            detailStatus.stringValue = "無法儲存：\(error.localizedDescription)"
            detailStatus.textColor = .systemRed
        }
    }

    private func defaultRule() -> CyderExecutableSettings {
        let value = settingsStore.value
        return CyderExecutableSettings(
            msync: value.msync,
            esync: value.esync ?? false,
            retinaMode: value.retinaMode,
            dpi: value.dpi,
            fontPreset: value.fontPreset,
            fontSmoothing: value.fontSmoothing,
            powerMode: "standard"
        )
    }

    private var selectedGame: CyderGameRecord? {
        guard let selectedGameID else { return nil }
        return games.first { $0.id == selectedGameID }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
