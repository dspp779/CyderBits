import Cocoa
import Foundation
import UniformTypeIdentifiers

private enum CyderLibraryTheme {
    static let cyberCyan = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.93, alpha: 1)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private enum CyderTitlebarBrandAlignment {
    case centered
    case leading
}

private func addCyderTitlebarBrand(
    to window: NSWindow,
    title: String,
    alignment: CyderTitlebarBrandAlignment = .centered
) {
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    let titlebar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 32))
    let imageView = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
    imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    let brand = NSStackView(views: [imageView, titleLabel])
    brand.orientation = .horizontal
    brand.alignment = .centerY
    brand.spacing = 6
    brand.translatesAutoresizingMaskIntoConstraints = false
    titlebar.addSubview(brand)
    brand.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor).isActive = true
    switch alignment {
    case .centered:
        brand.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor).isActive = true
    case .leading:
        brand.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: 8).isActive = true
    }

    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = titlebar
    accessory.layoutAttribute = .top
    window.addTitlebarAccessoryViewController(accessory)
}

private func addCyderTitlebarButton(to window: NSWindow, button: NSButton) {
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    let titlebar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 32))
    titlebar.addSubview(button)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -8),
        button.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
        button.widthAnchor.constraint(equalToConstant: 28),
        button.heightAnchor.constraint(equalToConstant: 28),
    ])

    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = titlebar
    accessory.layoutAttribute = .top
    window.addTitlebarAccessoryViewController(accessory)
}

/// A small root view is used because layer-backed colors resolve once when
/// assigned. Re-apply them when macOS changes the effective appearance so a
/// live light/dark switch never needs a relaunch.
private final class CyderAppearanceView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        onAppearanceChanged?()
    }
}

private final class CyderGameTileView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var isTileSelected = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingAreaRef: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Keep the visual padding around the icon and title balanced. The tile
        // content sits near the top, so the highlight extends to the top edge
        // while trimming excess space below the title.
        let highlightRect = NSRect(
            x: bounds.minX + 3,
            y: bounds.minY + 9,
            width: max(0, bounds.width - 6),
            height: max(0, bounds.height - 9)
        )
        let shape = NSBezierPath(roundedRect: highlightRect, xRadius: 10, yRadius: 10)
        let dark = CyderLibraryTheme.isDark(effectiveAppearance)
        if isTileSelected {
            (dark
                ? NSColor(calibratedWhite: 0.27, alpha: 1)
                : NSColor(calibratedWhite: 0.84, alpha: 1)
            ).setFill()
            shape.fill()
        } else if isHovered {
            (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.controlColor.withAlphaComponent(0.72)).setFill()
            shape.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func resetInteractionState() {
        isHovered = false
        isTileSelected = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@objc(CyderGameTileItem)
final class CyderGameTileItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var iconTopConstraint: NSLayoutConstraint!
    private var tile: CyderGameTileView { view as! CyderGameTileView }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?

    override func loadView() {
        let tile = CyderGameTileView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        view = tile

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .center
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        tile.addSubview(icon)
        tile.addSubview(nameLabel)
        tile.addSubview(status)
        iconTopConstraint = icon.topAnchor.constraint(equalTo: tile.topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconTopConstraint,
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            nameLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            status.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
        ])
        tile.onClick = { [weak self] in self?.onClick?() }
        tile.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        tile.onContextMenu = { [weak self] in self?.onContextMenu?() }
    }

    func configure(record: CyderGameRecord, independent: Bool, image: NSImage?) {
        tile.resetInteractionState()
        icon.image = image
        icon.toolTip = record.executablePath
        nameLabel.stringValue = record.displayName
        nameLabel.textColor = .labelColor
        nameLabel.font = .systemFont(ofSize: 11, weight: independent ? .semibold : .regular)
        status.stringValue = independent ? "獨立設定" : ""
        status.isHidden = !independent
        iconTopConstraint.constant = independent ? 6 : 10
        tile.isTileSelected = isSelected
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isViewLoaded { tile.resetInteractionState() }
    }

    override var isSelected: Bool {
        didSet {
            if isViewLoaded { tile.isTileSelected = isSelected }
        }
    }
}

/// A compact five-column grid. Every game owns one fifth of the available row
/// and incomplete rows continue from the leading edge.
private final class CyderFiveColumnGridLayout: NSCollectionViewLayout {
    private let itemHeight: CGFloat = 96
    private let horizontalPadding: CGFloat = 10
    private let topPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 10
    private let rowSpacing: CGFloat = 6
    private var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize = NSSize.zero

    override func prepare() {
        super.prepare()
        attributes.removeAll(keepingCapacity: true)
        guard let collectionView else {
            contentSize = .zero
            return
        }

        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard itemCount > 0 else {
            contentSize = NSSize(width: collectionView.bounds.width, height: 0)
            return
        }

        let width = max(collectionView.bounds.width, horizontalPadding * 2 + 5)
        let columnWidth = max(1, (width - horizontalPadding * 2) / 5)
        let rowCount = Int(ceil(Double(itemCount) / 5.0))
        for row in 0..<rowCount {
            let rowStart = row * 5
            let rowItemCount = min(5, itemCount - rowStart)
            let y = topPadding + CGFloat(row) * (itemHeight + rowSpacing)

            for offset in 0..<rowItemCount {
                let indexPath = IndexPath(item: rowStart + offset, section: 0)
                let frame = NSRect(
                    x: horizontalPadding + CGFloat(offset) * columnWidth,
                    y: y,
                    width: columnWidth,
                    height: itemHeight
                )
                let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                itemAttributes.frame = frame
                attributes[indexPath] = itemAttributes
            }
        }

        contentSize = NSSize(
            width: width,
            height: topPadding + CGFloat(rowCount) * itemHeight
                + CGFloat(max(0, rowCount - 1)) * rowSpacing + bottomPadding
        )
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

/// A dedicated macOS window for per-game launch settings. It keeps advanced
/// controls out of the library until people explicitly ask for them.
private final class CyderGameSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onLaunch: ((URL) -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onSettingsChanged: (() -> Void)?

    private let game: CyderGameRecord
    private let settingsStore = CyderSettingsStore.shared
    private var independent: Bool
    private var isLoading = false

    private let gameTitle = NSTextField(labelWithString: "")
    private let scopeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let launchButton = NSButton()
    private let createProfileButton = NSButton()
    private let removeProfileButton = NSButton()
    private let msync = NSSwitch()
    private let esync = NSSwitch()
    private let retina = NSSwitch()
    private let dpi = NSPopUpButton()
    private let power = NSPopUpButton()
    private let font = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let environment = NSTextField()
    private let arguments = NSTextField()
    private var settingViews: [NSView] = []
    private var originalRule: CyderExecutableSettings?
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()

    init(game: CyderGameRecord, independent: Bool) {
        self.game = game
        self.independent = independent
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.delegate = self
        let appearanceRoot = CyderAppearanceView(frame: window.contentView?.bounds ?? .zero)
        appearanceRoot.autoresizingMask = [.width, .height]
        window.contentView = appearanceRoot
        addCyderTitlebarBrand(to: window, title: "遊戲設定")
        buildUI()
        prepareForDisplay()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window {
            restoreOriginalRule()
            NSApp.stopModal(withCode: .cancel)
        }
    }

    func prepareForDisplay(independent: Bool? = nil) {
        if let independent { self.independent = independent }
        isLoading = true
        let global = settingsStore.value
        let rule = settingsStore.value.perProfile[game.id]
        originalRule = rule
        gameTitle.stringValue = game.displayName
        scopeLabel.stringValue = self.independent ? "獨立設定已啟用" : "目前使用全域設定"
        scopeLabel.textColor = self.independent ? .controlAccentColor : .secondaryLabelColor
        let msyncValue = rule?.msync ?? global.msync
        let esyncValue = rule?.esync ?? (global.esync ?? false)
        let retinaValue = rule?.retinaMode ?? global.retinaMode
        let dpiValue = rule?.dpi ?? global.dpi
        let powerValue = rule?.powerMode ?? "standard"
        let fontValue = rule?.fontPreset ?? global.fontPreset
        let smoothingValue = rule?.fontSmoothing ?? global.fontSmoothing
        msync.state = msyncValue ? .on : .off
        esync.state = esyncValue ? .on : .off
        retina.state = retinaValue ? .on : .off
        dpi.selectItem(at: dpiValues.firstIndex(of: dpiValue) ?? 4)
        power.selectItem(at: powerValue == "energySaving" ? 1 : 0)
        font.selectItem(at: fontValue == "mingliu" ? 1 : 0)
        smoothing.selectItem(at: smoothingValues.firstIndex(of: smoothingValue) ?? 2)
        environment.stringValue = (rule?.environment ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        arguments.stringValue = rule?.arguments.joined(separator: " | ") ?? ""

        let executableExists = FileManager.default.fileExists(atPath: game.executablePath)
        launchButton.isEnabled = executableExists
        createProfileButton.isHidden = self.independent
        createProfileButton.isEnabled = executableExists && !self.independent
        removeProfileButton.isHidden = !self.independent
        removeProfileButton.isEnabled = self.independent
        statusLabel.stringValue = executableExists
            ? (self.independent ? "變更會在下次啟動此遊戲時生效" : "建立獨立設定後即可調整下方選項")
            : "找不到 EXE，請重新加入遊戲庫"
        statusLabel.textColor = .secondaryLabelColor
        setControlsEnabled(self.independent && executableExists)
        isLoading = false
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let appearanceRoot = content as? CyderAppearanceView {
            appearanceRoot.onAppearanceChanged = { [weak self] in self?.refreshAppearance() }
        }

        gameTitle.font = .systemFont(ofSize: 19, weight: .semibold)
        gameTitle.maximumNumberOfLines = 2
        scopeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2

        launchButton.title = "開啟遊戲"
        launchButton.bezelStyle = .rounded
        launchButton.target = self
        launchButton.action = #selector(launchGame)
        createProfileButton.title = "建立獨立設定…"
        createProfileButton.bezelStyle = .rounded
        createProfileButton.target = self
        createProfileButton.action = #selector(createProfile)
        removeProfileButton.title = "移除獨立設定"
        removeProfileButton.bezelStyle = .rounded
        removeProfileButton.target = self
        removeProfileButton.action = #selector(removeProfile)
        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSettings)
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.title = "確認"
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmSettings)

        dpi.addItems(withTitles: dpiTitles)
        power.addItems(withTitles: ["標準", "省電"])
        font.addItems(withTitles: ["宋體（Songti TC）", "細明體（MingLiU）"])
        smoothing.addItems(withTitles: ["關閉", "灰階", "ClearType RGB", "ClearType BGR"])
        environment.placeholderString = "KEY=value；多組以 ; 分隔"
        arguments.placeholderString = "參數1 | 參數2"
        [environment, arguments].forEach {
            $0.widthAnchor.constraint(equalToConstant: 240).isActive = true
            $0.target = self
            $0.action = #selector(controlChanged)
        }
        msync.target = self
        msync.action = #selector(msyncChanged)
        esync.target = self
        esync.action = #selector(esyncChanged)
        retina.target = self
        retina.action = #selector(retinaChanged)
        [dpi, power, font, smoothing].forEach {
            $0.target = self
            $0.action = #selector(controlChanged)
        }

        let root = NSScrollView()
        root.drawsBackground = false
        root.hasVerticalScroller = true
        root.autohidesScrollers = true
        root.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [NSView(), cancelButton, confirmButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [gameTitle, scopeLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        let actions = NSStackView(views: [launchButton, createProfileButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let form: [NSView] = [
            sectionTitle("執行選項"),
            row("MSync", msync),
            row("ESync", esync),
            row("Retina Mode", retina),
            row("縮放比例 / DPI", dpi),
            row("能源模式", power),
            row("遊戲字體", font),
            row("字體平滑", smoothing),
            row("環境變數", environment),
            row("命令列參數", arguments),
            note("這些選項只會套用到這款遊戲。"),
        ]
        settingViews = form
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(separator())
        form.forEach { stack.addArrangedSubview($0) }
        stack.addArrangedSubview(removeProfileButton)

        document.addSubview(stack)
        root.documentView = document
        content.addSubview(root)
        content.addSubview(buttonBar)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            root.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -8),
            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttonBar.heightAnchor.constraint(equalToConstant: 26),
            document.leadingAnchor.constraint(equalTo: root.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: root.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: root.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: root.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        refreshAppearance()
    }

    private func refreshAppearance() {
        window?.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window?.contentView?.needsDisplay = true
    }

    private func sectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.widthAnchor.constraint(equalToConstant: 310).isActive = true
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 310).isActive = true
        return line
    }

    private func setControlsEnabled(_ enabled: Bool) {
        [msync, esync, retina, dpi, power, font, smoothing, environment, arguments].forEach { $0.isEnabled = enabled }
        settingViews.forEach { $0.alphaValue = enabled ? 1 : 0.52 }
    }

    @objc private func launchGame() {
        stopModal(.OK)
        onLaunch?(game.executableURL)
    }

    @objc private func createProfile() {
        let alert = NSAlert()
        alert.messageText = "為這個遊戲建立獨立設定？"
        alert.informativeText = "Cyder 會為「\(game.displayName)」建立專屬的 Windows 環境，不會修改遊戲檔案。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "建立獨立設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopModal(.OK)
        onCreateProfile?(game.executableURL)
    }

    @objc private func removeProfile() {
        let alert = NSAlert()
        alert.messageText = "移除「\(game.displayName)」的獨立設定？"
        alert.informativeText = "這會刪除專屬的 Windows 環境；遊戲檔案與遊戲庫項目不會刪除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除獨立設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        statusLabel.stringValue = "正在移除獨立設定…"
        setControlsEnabled(false)
        removeProfileButton.isEnabled = false
        stopModal(.OK)
        onRemoveProfile?(game.executableURL) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.independent = false
                self.onSettingsChanged?()
                self.prepareForDisplay()
            } else {
                self.prepareForDisplay()
                self.statusLabel.stringValue = "移除失敗，請查看錯誤訊息後再試"
                self.statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func msyncChanged() {
        if msync.state == .on { esync.state = .off }
        saveRule()
    }

    @objc private func esyncChanged() {
        if esync.state == .on { msync.state = .off }
        saveRule()
    }

    @objc private func retinaChanged() {
        dpi.selectItem(at: dpiValues.firstIndex(of: retina.state == .on ? 192 : 96) ?? 0)
        saveRule()
    }

    @objc private func controlChanged() { saveRule() }

    @objc private func cancelSettings() {
        restoreOriginalRule()
        stopModal(.cancel)
    }

    @objc private func confirmSettings() {
        saveRule()
        stopModal(.OK)
    }

    private func stopModal(_ response: NSApplication.ModalResponse) {
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: response)
        }
    }

    private func restoreOriginalRule() {
        do {
            try settingsStore.update { settings in
                if let originalRule {
                    settings.perProfile[game.id] = originalRule
                } else {
                    settings.perProfile.removeValue(forKey: game.id)
                }
            }
        } catch {
            statusLabel.stringValue = "無法還原設定：\(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    private func saveRule() {
        guard !isLoading, independent else { return }
        var rule = settingsStore.value.perProfile[game.id] ?? defaultRule()
        rule.msync = msync.state == .on
        rule.esync = esync.state == .on
        rule.retinaMode = retina.state == .on
        rule.dpi = dpiValues[max(0, dpi.indexOfSelectedItem)]
        rule.powerMode = power.indexOfSelectedItem == 1 ? "energySaving" : "standard"
        rule.fontPreset = font.indexOfSelectedItem == 1 ? "mingliu" : "songti"
        rule.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
        rule.environment = environment.stringValue
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { entry -> (String, String)? in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                let key = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(entry[entry.index(after: separator)...])
                return key.isEmpty ? nil : (key, value)
            }
            .reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        rule.arguments = arguments.stringValue
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try settingsStore.update { $0.perProfile[game.id] = rule }
            statusLabel.stringValue = "已儲存；下次啟動此遊戲時生效"
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            statusLabel.stringValue = "無法儲存：\(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    private var dpiValues: [Int] { [96, 120, 144, 168, 192, 240] }
    private var dpiTitles: [String] { ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"] }
    private var smoothingValues: [String] { ["off", "grayscale", "cleartype-rgb", "cleartype-bgr"] }

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
}

final class CyderGameLibraryWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource {
    var onLaunch: ((URL) -> Void)?
    var onCreateProfile: ((URL) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onClose: (() -> Void)?

    var isGameSettingsVisible: Bool { gameSettingsController?.window?.isVisible == true }

    private let libraryStore = CyderGameLibraryStore.shared
    private let profileStore = CyderProfileStore(root: CyderPaths.support)
    private let settingsStore = CyderSettingsStore.shared
    private let iconStore = CyderGameIconStore.shared
    private let collectionView = NSCollectionView()
    private let emptyState = NSStackView()
    private var games: [CyderGameRecord] = []
    private var selectedGameID: String?
    private var independentIDs: Set<String> = []
    private var gameSettingsController: CyderGameSettingsWindowController?
    private let toolbarAddButton = NSButton()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let appearanceRoot = CyderAppearanceView(frame: window.contentView?.bounds ?? .zero)
        appearanceRoot.autoresizingMask = [.width, .height]
        window.contentView = appearanceRoot
        buildUI()
        prepareForDisplay()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func prepareForDisplay() {
        libraryStore.reload()
        let profiles = profileStore.listRecords()
        try? libraryStore.merge(profileRecords: profiles)
        games = libraryStore.games
        independentIDs = Set(profiles.map(\.profileId))
        if let selectedGameID, !games.contains(where: { $0.id == selectedGameID }) {
            self.selectedGameID = nil
        }
        reloadGrid()
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let appearanceRoot = content as? CyderAppearanceView {
            appearanceRoot.onAppearanceChanged = { [weak self] in self?.refreshAppearance() }
        }

        configureCollectionView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = collectionView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        toolbarAddButton.title = ""
        toolbarAddButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "加入遊戲") ?? NSImage()
        toolbarAddButton.target = self
        toolbarAddButton.action = #selector(addGame)
        toolbarAddButton.imagePosition = .imageOnly
        toolbarAddButton.bezelStyle = .texturedRounded
        toolbarAddButton.toolTip = "加入遊戲"
        toolbarAddButton.setAccessibilityLabel("加入遊戲")
        addCyderTitlebarButton(to: window, button: toolbarAddButton)

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        let emptyTitle = NSTextField(labelWithString: "尚未加入遊戲")
        emptyTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let emptyDescription = NSTextField(labelWithString: "選擇 EXE 即可開始遊玩")
        emptyDescription.font = .systemFont(ofSize: 12)
        emptyDescription.textColor = .secondaryLabelColor
        let emptyButton = NSButton(
            title: "加入遊戲",
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "加入遊戲") ?? NSImage(),
            target: self,
            action: #selector(addGame)
        )
        emptyButton.imagePosition = .imageLeading
        emptyButton.bezelStyle = .rounded
        emptyState.setViews([emptyIcon, emptyTitle, emptyDescription, emptyButton], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 9
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20),
        ])
    }

    private func configureCollectionView() {
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.register(CyderGameTileItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("CyderGameTileItem"))
        collectionView.collectionViewLayout = CyderFiveColumnGridLayout()
    }

    private func reloadGrid() {
        collectionView.reloadData()
        let isEmpty = games.isEmpty
        emptyState.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        toolbarAddButton.isHidden = isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    private func refreshAppearance() {
        window?.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        collectionView.needsDisplay = true
        collectionView.visibleItems().forEach { $0.view.needsDisplay = true }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { games.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("CyderGameTileItem")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! CyderGameTileItem
        let game = games[indexPath.item]
        item.onClick = { [weak self] in self?.selectGame(game) }
        item.onDoubleClick = { [weak self] in self?.launch(game) }
        item.onContextMenu = { [weak self] in self?.contextMenu(for: game) }
        item.configure(record: game, independent: independentIDs.contains(game.id), image: iconStore.image(for: game))
        item.isSelected = game.id == selectedGameID
        return item
    }

    private func selectGame(_ game: CyderGameRecord) {
        guard selectedGameID != game.id else { return }
        selectedGameID = game.id
        for item in collectionView.visibleItems() {
            guard let tileItem = item as? CyderGameTileItem,
                  let indexPath = collectionView.indexPath(for: item),
                  indexPath.item < games.count else { continue }
            tileItem.isSelected = games[indexPath.item].id == game.id
        }
    }

    private func contextMenu(for game: CyderGameRecord) -> NSMenu {
        selectGame(game)
        let menu = NSMenu()
        let options = menu.addItem(withTitle: "啟動選項", action: #selector(openSettingsForSelectedGame), keyEquivalent: "")
        options.target = self
        let remove = menu.addItem(withTitle: "移除", action: #selector(removeGameFromLibrary), keyEquivalent: "")
        remove.target = self
        return menu
    }

    @objc private func addGame() {
        let panel = NSOpenPanel()
        panel.title = "加入遊戲"
        panel.message = "選擇 Windows 遊戲執行檔 (.exe)"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *), let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType, .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let record = try libraryStore.add(executable: url)
            games = libraryStore.games
            selectedGameID = record.id
            independentIDs = Set(profileStore.listRecords().map(\.profileId))
            reloadGrid()
            iconStore.extractSelectedGame(record) { [weak self] in self?.collectionView.reloadData() }
        } catch {
            showAlert(title: "無法加入遊戲", message: error.localizedDescription)
        }
    }

    private func launch(_ game: CyderGameRecord) {
        guard FileManager.default.fileExists(atPath: game.executablePath) else {
            showAlert(title: "找不到遊戲", message: "這個 EXE 已不在原本的位置。")
            return
        }
        onLaunch?(game.executableURL)
    }

    @objc private func openSettingsForSelectedGame() {
        guard let game = selectedGame else { return }
        let controller = CyderGameSettingsWindowController(game: game, independent: independentIDs.contains(game.id))
        controller.onLaunch = { [weak self] executable in self?.onLaunch?(executable) }
        controller.onCreateProfile = { [weak self] executable in self?.onCreateProfile?(executable) }
        controller.onRemoveProfile = { [weak self] executable, completion in
            guard let self else { completion(false); return }
            self.onRemoveProfile?(executable) { succeeded in
                completion(succeeded)
                if succeeded { self.prepareForDisplay() }
            }
        }
        controller.onSettingsChanged = { [weak self] in self?.prepareForDisplay() }
        gameSettingsController = controller
        guard let libraryWindow = window, let settingsWindow = controller.window else { return }
        controller.showWindow(nil)
        let parentFrame = libraryWindow.frame
        let childSize = settingsWindow.frame.size
        settingsWindow.setFrameOrigin(NSPoint(
            x: parentFrame.midX - childSize.width / 2,
            y: parentFrame.midY - childSize.height / 2
        ))
        libraryWindow.addChildWindow(settingsWindow, ordered: .above)
        settingsWindow.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: settingsWindow)
        libraryWindow.removeChildWindow(settingsWindow)
        settingsWindow.orderOut(nil)
        settingsWindow.close()
        gameSettingsController = nil
        if libraryWindow.isVisible {
            libraryWindow.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func removeGameFromLibrary() {
        guard let game = selectedGame else { return }
        let alert = NSAlert()
        alert.messageText = "移除「\(game.displayName)」？"
        alert.informativeText = independentIDs.contains(game.id)
            ? "這會從遊戲庫移除遊戲，並刪除它的獨立設定。遊戲檔案不會被刪除。"
            : "這會從遊戲庫移除遊戲與相關設定。遊戲檔案不會被刪除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let finish = { [weak self] in
            guard let self else { return }
            do {
                try self.libraryStore.remove(id: game.id)
                try self.settingsStore.update { $0.perProfile.removeValue(forKey: game.id) }
                self.gameSettingsController?.close()
                self.selectedGameID = nil
                self.prepareForDisplay()
            } catch {
                self.showAlert(title: "無法移除遊戲", message: error.localizedDescription)
            }
        }

        if independentIDs.contains(game.id) {
            onRemoveProfile?(game.executableURL) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    finish()
                } else {
                    self.showAlert(title: "移除失敗", message: "請查看錯誤訊息後再試。")
                }
            }
        } else {
            finish()
        }
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
