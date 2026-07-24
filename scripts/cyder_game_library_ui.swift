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
    alignment: CyderTitlebarBrandAlignment = .centered,
    image: NSImage? = nil,
    hideImageWhenMissing: Bool = false
) {
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    let titlebar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 32))
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    let brandViews: [NSView]
    if let image {
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        brandViews = [imageView, titleLabel]
    } else if hideImageWhenMissing {
        brandViews = [titleLabel]
    } else {
        let imageView = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        brandViews = [imageView, titleLabel]
    }
    let brand = NSStackView(views: brandViews)
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

/// An information control that works consistently in stack views. Native
/// `toolTip` handling can be easy to miss in a modal panel, so this control
/// explicitly tracks hover and presents the same explanation on click.
private final class CyderInformationButton: NSButton {
    private let explanation: String
    private var trackingAreaRef: NSTrackingArea?
    private var hoverTimer: Timer?
    private var popover: NSPopover?
    private var popoverWasOpenedByHover = false

    init(explanation: String) {
        self.explanation = explanation
        let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "說明") ?? NSImage()
        // Avoid NSButton(image:target:action:). Apple Swift 6.2.3 can emit
        // an ownership assertion in optimized builds for that Obj-C bridge.
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        image = symbol
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .secondaryLabelColor
        toolTip = explanation
        setAccessibilityLabel("說明")
        setAccessibilityHelp(explanation)
        target = self
        action = #selector(buttonPressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.showExplanation(openedByHover: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        hoverTimer = nil
        if popoverWasOpenedByHover {
            popover?.close()
            popover = nil
            popoverWasOpenedByHover = false
        }
    }

    @objc private func buttonPressed() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            popoverWasOpenedByHover = false
        } else {
            showExplanation(openedByHover: false)
        }
    }

    private func showExplanation(openedByHover: Bool) {
        guard window != nil else { return }
        if let popover, popover.isShown { return }

        let label = NSTextField(wrappingLabelWithString: explanation)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 70))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let controller = NSViewController()
        controller.view = container
        let nextPopover = NSPopover()
        nextPopover.behavior = .transient
        nextPopover.animates = true
        nextPopover.contentSize = container.frame.size
        nextPopover.contentViewController = controller
        nextPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = nextPopover
        popoverWasOpenedByHover = openedByHover
    }
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
/// Multiline text view with a simple empty-state placeholder (NSTextView has none).
private final class CyderPlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: 12),
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + 5,
            y: textContainerOrigin.y
        )
        (placeholderString as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

private final class CyderGameSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onLaunch: ((URL, CyderExecutableSettings) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onSettingsChanged: (() -> Void)?

    private let game: CyderGameRecord
    private let settingsStore = CyderSettingsStore.shared
    private var independent: Bool

    private let launchButton = NSButton()
    private let launchHint = NSTextField(labelWithString: "使用目前選項啟動；測試會寫入 Logs/last-launch.log（含指令）")
    private let removeProfileButton = NSButton()
    private let msync = NSSwitch()
    private let esync = NSSwitch()
    private let retina = NSSwitch()
    private let dpi = NSPopUpButton()
    private let power = NSPopUpButton()
    private let font = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let environment = CyderPlaceholderTextView()
    private let arguments = CyderPlaceholderTextView()
    private var settingViews: [NSView] = []
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()

    init(game: CyderGameRecord, independent: Bool) {
        self.game = game
        self.independent = independent
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 450),
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
        addCyderTitlebarBrand(
            to: window,
            title: "\(game.displayName) 的啟動選項",
            image: CyderGameIconStore.shared.logo(for: game),
            hideImageWhenMissing: true
        )
        buildUI()
        prepareForDisplay()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    func prepareForDisplay(independent: Bool? = nil) {
        if let independent { self.independent = independent }
        let global = settingsStore.value
        let rule = settingsStore.value.perProfile[game.id]
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
        environment.string = (rule?.environment ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        arguments.string = formatArguments(rule?.arguments ?? [])

        let executableExists = FileManager.default.fileExists(atPath: game.executablePath)
        launchButton.isEnabled = executableExists
        removeProfileButton.isHidden = !self.independent
        removeProfileButton.isEnabled = self.independent
        setControlsEnabled(executableExists)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let appearanceRoot = content as? CyderAppearanceView {
            appearanceRoot.onAppearanceChanged = { [weak self] in self?.refreshAppearance() }
        }

        launchButton.title = "測試"
        launchButton.bezelStyle = .rounded
        launchButton.target = self
        launchButton.action = #selector(launchGame)
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.textColor = .secondaryLabelColor
        removeProfileButton.title = "移除獨立設定"
        removeProfileButton.bezelStyle = .rounded
        removeProfileButton.target = self
        removeProfileButton.action = #selector(removeProfile)
        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSettings)
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.title = "套用"
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmSettings)

        dpi.addItems(withTitles: dpiTitles)
        power.addItems(withTitles: ["標準", "省電"])
        font.addItems(withTitles: [
            cyderDefaultFontPreset() == "songti"
                ? "宋體（Songti TC，預設）" : "宋體（Songti TC）",
            cyderDefaultFontPreset() == "mingliu"
                ? "細明體（MingLiU，預設）" : "細明體（MingLiU）",
        ])
        smoothing.addItems(withTitles: ["關閉", "灰階", "ClearType RGB"])
        for textView in [environment, arguments] {
            textView.isRichText = false
            textView.isSelectable = true
            textView.isEditable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 12)
            textView.textColor = .labelColor
        }
        environment.placeholderString = "KEY=value  KEY2=value2"
        arguments.placeholderString = "例如：--fullscreen --width 1920"
        msync.target = self
        msync.action = #selector(msyncChanged)
        esync.target = self
        esync.action = #selector(esyncChanged)
        retina.target = self
        retina.action = #selector(retinaChanged)

        let root = NSScrollView()
        root.drawsBackground = false
        root.hasVerticalScroller = true
        root.autohidesScrollers = true
        root.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [launchButton, launchHint, NSView(), cancelButton, confirmButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        [launchButton, cancelButton, confirmButton].forEach {
            $0.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let form: [NSView] = [
            row("MSync", msync, information: "使用 macOS 原生同步機制改善部分遊戲效能；若遊戲凍結或無法啟動，可保持關閉。"),
            row("ESync", esync, information: "使用事件同步機制降低等待開銷；MSync 與 ESync 不能同時開啟。"),
            row("Retina Mode", retina, information: "啟用 macOS Retina 高解析度模式；部分遊戲可能需要關閉。"),
            row("縮放比例 / DPI", dpi, information: "設定 Windows 顯示縮放比例；老遊戲視窗可能需要較低 DPI。"),
            row("能源模式", power, information: "省電模式會降低程序優先級，可能減少耗電但造成遊戲卡頓。"),
            row("遊戲字體", font, information: "選擇 Wine 的字體替代方案；細明體需要系統已安裝對應字型。"),
            row("字體平滑", smoothing, information: "控制 Windows 字體平滑方式。"),
            row(
                "環境變數",
                multilineInput(environment),
                information: "寫 KEY=value。可同行以空白分隔多組，也可換行；換行會當成空白。值含空白請用引號，例如 NAME=\"hello world\"。"
            ),
            row(
                "命令列參數",
                multilineInput(arguments),
                information: "直接接在遊戲執行指令後；以空白分隔參數，含空白的參數可用引號包住。可換行書寫，換行視同空白。"
            ),
        ]
        settingViews = form
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

    private func row(_ title: String, _ control: NSView, information: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let titleViews: [NSView]
        if let information {
            titleViews = [label, informationIcon(information)]
        } else {
            titleViews = [label]
        }
        let titleStack = NSStackView(views: titleViews)
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 4
        titleStack.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [titleStack, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func informationIcon(_ text: String) -> NSView {
        CyderInformationButton(explanation: text)
    }

    private func multilineInput(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 40).isActive = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    private func setControlsEnabled(_ enabled: Bool) {
        [msync, esync, retina, dpi, power, font, smoothing].forEach { $0.isEnabled = enabled }
        environment.isEditable = enabled
        arguments.isEditable = enabled
        settingViews.forEach { $0.alphaValue = enabled ? 1 : 0.52 }
    }

    @objc private func launchGame() {
        // Testing is intentionally non-destructive: keep the draft window
        // open so the user can compare, adjust, and test again before Apply.
        onLaunch?(game.executableURL, currentRule())
    }

    @objc private func removeProfile() {
        let alert = NSAlert()
        alert.messageText = "移除「\(game.displayName)」的獨立設定？"
        alert.informativeText = "這會刪除專屬的 Windows 環境；遊戲檔案與遊戲庫項目不會刪除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除獨立設定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
                self.showAlert(title: "移除失敗", message: "請查看錯誤訊息後再試。")
            }
        }
    }

    @objc private func msyncChanged() {
        if msync.state == .on { esync.state = .off }
    }

    @objc private func esyncChanged() {
        if esync.state == .on { msync.state = .off }
    }

    @objc private func retinaChanged() {
        dpi.selectItem(at: dpiValues.firstIndex(of: retina.state == .on ? 192 : 96) ?? 0)
    }

    @objc private func cancelSettings() {
        stopModal(.cancel)
    }

    @objc private func confirmSettings() {
        persistRule()
    }

    private func stopModal(_ response: NSApplication.ModalResponse) {
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: response)
        }
    }

    private func currentRule() -> CyderExecutableSettings {
        var rule = settingsStore.value.perProfile[game.id] ?? defaultRule()
        rule.msync = msync.state == .on
        rule.esync = esync.state == .on
        rule.retinaMode = retina.state == .on
        rule.dpi = dpiValues[max(0, dpi.indexOfSelectedItem)]
        rule.powerMode = power.indexOfSelectedItem == 1 ? "energySaving" : "standard"
        rule.fontPreset = font.indexOfSelectedItem == 1 ? "mingliu" : "songti"
        rule.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
        rule.environment = parseEnvironment(environment.string)
        // Newlines in the multiline field are treated as whitespace separators.
        rule.arguments = parseArguments(
            arguments.string
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        )
        return rule
    }

    /// Accepts `KEY=value` pairs separated by spaces and/or newlines.
    /// Quoted values keep internal spaces: `NAME="hello world"`.
    private func parseEnvironment(_ text: String) -> [String: String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let characters = Array(normalized)
        var result: [String: String] = [:]
        var index = 0

        func skipWhitespace() {
            while index < characters.count && characters[index].isWhitespace {
                index += 1
            }
        }

        while index < characters.count {
            skipWhitespace()
            guard index < characters.count else { break }

            let keyStart = index
            let first = characters[index]
            guard first.isLetter || first == "_" else {
                while index < characters.count && !characters[index].isWhitespace {
                    index += 1
                }
                continue
            }
            index += 1
            while index < characters.count {
                let character = characters[index]
                if character.isLetter || character.isNumber || character == "_" {
                    index += 1
                } else {
                    break
                }
            }
            let key = String(characters[keyStart..<index])
            guard index < characters.count, characters[index] == "=" else { continue }
            index += 1

            let value: String
            if index < characters.count, characters[index] == "\"" {
                index += 1
                var buffer = ""
                while index < characters.count {
                    let character = characters[index]
                    if character == "\\" {
                        let next = index + 1
                        if next < characters.count {
                            buffer.append(characters[next])
                            index = next + 1
                        } else {
                            index = next
                        }
                    } else if character == "\"" {
                        index += 1
                        break
                    } else {
                        buffer.append(character)
                        index += 1
                    }
                }
                value = buffer
            } else {
                let valueStart = index
                while index < characters.count && !characters[index].isWhitespace {
                    index += 1
                }
                value = String(characters[valueStart..<index])
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func formatArguments(_ values: [String]) -> String {
        values.map { value in
            guard !value.isEmpty else { return "\"\"" }
            let needsQuotes = value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || value.contains("\\")
                || value.contains("\"")
                || value.contains("'")
            guard needsQuotes else { return value }
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    private func parseArguments(_ text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        var quote: Character?
        var tokenStarted = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    tokenStarted = true
                } else if character == "\\",
                          index + 1 < characters.count,
                          ["\\", "\"", "'"].contains(characters[index + 1]) {
                    current.append(characters[index + 1])
                    index += 1
                    tokenStarted = true
                } else {
                    current.append(character)
                    tokenStarted = true
                }
            } else if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character.isWhitespace {
                if tokenStarted {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                    tokenStarted = false
                }
            } else if character == "\\",
                      index + 1 < characters.count,
                      ["\\", "\"", "'"].contains(characters[index + 1]) {
                current.append(characters[index + 1])
                index += 1
                tokenStarted = true
            } else {
                current.append(character)
                tokenStarted = true
            }
            index += 1
        }
        if tokenStarted { result.append(current) }
        return result
    }

    private func persistRule() {
        let rule = currentRule()
        do {
            try settingsStore.update { $0.perProfile[game.id] = rule }
            onSettingsChanged?()
            stopModal(.OK)
        } catch {
            showAlert(title: "無法套用設定", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private var dpiValues: [Int] { [96, 120, 144, 168, 192, 240] }
    private var dpiTitles: [String] { ["100%（96 DPI）", "125%（120 DPI）", "150%（144 DPI）", "175%（168 DPI）", "200%（192 DPI）", "250%（240 DPI）"] }
    private var smoothingValues: [String] { ["off", "grayscale", "cleartype-rgb"] }

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
    var onLaunch: ((URL, CyderExecutableSettings?) -> Void)?
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
        onLaunch?(game.executableURL, nil)
    }

    @objc private func openSettingsForSelectedGame() {
        guard let game = selectedGame else { return }
        let controller = CyderGameSettingsWindowController(game: game, independent: independentIDs.contains(game.id))
        controller.onLaunch = { [weak self] executable, settings in
            self?.onLaunch?(executable, settings)
        }
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
