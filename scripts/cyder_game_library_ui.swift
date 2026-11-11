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

private func addCyderTitlebarButtons(to window: NSWindow, buttons: [NSButton]) {
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    let titlebar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 32))
    let stack = NSStackView(views: buttons)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    titlebar.addSubview(stack)
    for button in buttons {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }
    NSLayoutConstraint.activate([
        stack.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -8),
        stack.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: titlebar.leadingAnchor, constant: 8),
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

/// CGColor caches one resolved value; resolve it in this view's drawing appearance.
private func refreshCyderWindowBackground(_ view: NSView?) {
    guard let view else { return }
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

/// A small root view is used because layer-backed colors resolve once when
/// assigned. Re-apply them when macOS changes the effective appearance so a
/// live light/dark switch never needs a relaunch.
private final class CyderAppearanceView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshCyderWindowBackground(self)
        onAppearanceChanged?()
    }
}

private final class CyderGameTileView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var isInteractionEnabled = true {
        didSet {
            alphaValue = isInteractionEnabled ? 1 : 0.45
            setAccessibilityEnabled(isInteractionEnabled)
            if !isInteractionEnabled { isHovered = false }
        }
    }
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

    override func mouseEntered(with event: NSEvent) { if isInteractionEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func resetInteractionState() {
        isHovered = false
        isTileSelected = false
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractionEnabled, let onClick else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if event.clickCount == 1 {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInteractionEnabled else { return nil }
        return onContextMenu?() ?? super.menu(for: event)
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
        let tile = CyderGameTileView(frame: NSRect(x: 0, y: 0, width: 96, height: 114))
        view = tile
        tile.setAccessibilityElement(true)
        tile.setAccessibilityRole(.button)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.usesSingleLineMode = false
        nameLabel.maximumNumberOfLines = 2
        // byTruncatingTail never wraps; byWordWrapping also fails for CJK .lnk
        // names with no spaces. Wrap by character, then ellipsize line 2.
        if let cell = nameLabel.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
            cell.lineBreakMode = .byCharWrapping
            cell.truncatesLastVisibleLine = true
        }
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            nameLabel.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            status.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
        ])
        tile.onClick = { [weak self] in self?.onClick?() }
        tile.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        tile.onContextMenu = { [weak self] in self?.onContextMenu?() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = nameLabel.bounds.width
        if width > 1, abs(nameLabel.preferredMaxLayoutWidth - width) > 0.5 {
            nameLabel.preferredMaxLayoutWidth = width
        }
    }

    func configure(record: CyderGameRecord, independent: Bool, readOnly: Bool, image: NSImage?) {
        tile.resetInteractionState()
        icon.image = image
        icon.toolTip = record.executablePath
        nameLabel.stringValue = record.displayName
        tile.setAccessibilityLabel(record.displayName)
        tile.setAccessibilityHelp(readOnly ? "唯讀遊戲庫，可選取遊戲" : "選取遊戲以顯示啟動與選項按鈕")
        tile.setAccessibilityValue(isSelected ? "已選取" : "")
        nameLabel.textColor = .labelColor
        nameLabel.font = .systemFont(ofSize: 11, weight: independent ? .semibold : .regular)
        status.stringValue = independent ? "獨立設定" : ""
        status.isHidden = !independent
        iconTopConstraint.constant = independent ? 6 : 10
        tile.isTileSelected = isSelected
    }

    func setInteractionEnabled(_ enabled: Bool) { tile.isInteractionEnabled = enabled }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isViewLoaded { tile.resetInteractionState() }
    }

    override var isSelected: Bool {
        didSet {
            if isViewLoaded {
                tile.isTileSelected = isSelected
                tile.setAccessibilityValue(isSelected ? "已選取" : "")
            }
        }
    }
}

private final class CyderLibraryCollectionView: NSCollectionView {
    var isInteractionEnabled = true
    override var acceptsFirstResponder: Bool { isInteractionEnabled }
    var onLaunchSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            if !event.isARepeat { onLaunchSelection?() }
            return
        }
        super.keyDown(with: event)
    }
}

/// A compact five-column grid. Every game owns one fifth of the available row
/// and incomplete rows continue from the leading edge.
private final class CyderFiveColumnGridLayout: NSCollectionViewLayout {
    private let itemHeight: CGFloat = 114
    private let horizontalPadding: CGFloat = 10
    private let topPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 10
    private let rowSpacing: CGFloat = 6
    private var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize = NSSize.zero
    private weak var observedViewport: NSClipView?
    private var viewportObserver: NSObjectProtocol?
    private var observedViewportWidth: CGFloat?

    deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
    }

    private func availableWidth(for collectionView: NSCollectionView) -> CGFloat {
        let viewport = collectionView.enclosingScrollView?.contentView
        if observedViewport !== viewport {
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
            viewportObserver = nil
            observedViewport = viewport
            observedViewportWidth = viewport?.bounds.width
            if let viewport {
                viewport.postsBoundsChangedNotifications = true
                viewportObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: viewport, queue: nil
                ) { [weak self, weak viewport] _ in
                    guard let self, let viewport,
                          self.collectionView?.enclosingScrollView?.contentView === viewport else { return }
                    let width = viewport.bounds.width
                    guard width != self.observedViewportWidth else { return }
                    self.observedViewportWidth = width
                    self.invalidateLayout()
                }
            }
        }
        // The document width is an output of this layout, not the available width.
        // Before attachment (or before a positive viewport exists), retain the old fallback.
        if let width = viewport?.bounds.width, width.isFinite, width > 0 { return width }
        return collectionView.bounds.width
    }

    override func prepare() {
        super.prepare()
        attributes.removeAll(keepingCapacity: true)
        guard let collectionView else {
            contentSize = .zero
            return
        }

        let availableWidth = availableWidth(for: collectionView)
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard itemCount > 0 else {
            contentSize = NSSize(width: availableWidth, height: 0)
            return
        }

        let width = max(availableWidth, horizontalPadding * 2 + 5)
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

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
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

/// DirectDraw actions save immediately; the other display controls use Apply.
private final class CyderDirectDrawOptions: NSObject {
    let detail = NSTextField(wrappingLabelWithString: "正在檢查 DirectDraw…")
    let action = NSButton()
    let restore = NSButton()
    let refresh = NSButton()
    let explanation = NSTextField(wrappingLabelWithString: "")
    private let filter = NSPopUpButton()
    private let frameRate = NSPopUpButton()
    var onBusy: ((Bool) -> Void)?
    var canMutate: (() -> Bool)?
    var selectedBackend: (() -> CyderGraphicsBackend?)?
    private let executable: URL
    private var mode = ""
    private var legacyMode = ""
    private var engineCapability: String?
    private var detailMessage = ""
    private(set) var busy = false
    private var operationInFlight = false
    private var operationID: UUID?
    private var observationGeneration = UUID()

    init(executable: URL) {
        self.executable = executable
        super.init()
        for (button, title, selector) in [
            (action, "啟用 cnc-ddraw", #selector(performAction)),
            (restore, "停用 cnc-ddraw", #selector(restoreOriginal)),
            (refresh, "重新檢查", #selector(reload))
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
        }
        action.identifier = NSUserInterfaceItemIdentifier("game-cnc-action")
        restore.identifier = NSUserInterfaceItemIdentifier("game-cnc-restore")
        filter.identifier = NSUserInterfaceItemIdentifier("game-cnc-filter")
        frameRate.identifier = NSUserInterfaceItemIdentifier("game-cnc-frame-rate")
        filter.setAccessibilityLabel("縮放方式")
        frameRate.setAccessibilityLabel("畫面更新上限")
        filter.addItems(withTitles: ["平滑（雙線性）", "銳利（最近鄰）"])
        frameRate.addItems(withTitles: ["30", "60", "120", "144", "240"])
        frameRate.selectItem(withTitle: "60")
        for control in [filter, frameRate] {
            control.target = self
            control.action = #selector(settingsChanged)
            control.isEnabled = false
        }
        detail.font = .systemFont(ofSize: 13, weight: .medium)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        for label in [detail, explanation] {
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 465).isActive = true
            label.isSelectable = true
        }
        action.isEnabled = false
        restore.isHidden = true
    }

    private func optionRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [label, control])
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    var rows: [NSView] {
        let bar = NSStackView(views: [action, restore, refresh])
        bar.spacing = 8
        return [detail, explanation, optionRow("縮放方式", filter),
                optionRow("畫面更新上限", frameRate), bar]
    }

    private func update(_ state: [String: Any]) {
        mode = state["mode"] as? String ?? ""
        legacyMode = state["legacyMode"] as? String ?? ""
        if let capability = state["capability"] as? String { engineCapability = capability }
        let settings = state["settings"] as? [String: Any] ?? [:]
        filter.selectItem(at: settings["filter"] as? String == "nearest" ? 1 : 0)
        let rate = String((settings["maxfps"] as? NSNumber)?.intValue ?? 60)
        if frameRate.item(withTitle: rate) == nil { frameRate.addItem(withTitle: rate) }
        frameRate.selectItem(withTitle: rate)
        detailMessage = "適用 32 位元 DirectDraw 遊戲，請選「預設」或 WineD3D。cnc-ddraw 變更立即儲存，下次啟動生效；現有視窗不變。"
        restore.isHidden = mode != "on" && !(mode == "legacy" && legacyMode != "off")
        restore.title = mode == "legacy" ? "還原舊版 DLL" : "停用 cnc-ddraw"
        action.isEnabled = true
        switch mode {
        case "on":
            detail.stringValue = "cnc-ddraw \(state["version"] as? String ?? "") 已啟用"
            action.title = "驗證／更新"
        case "off":
            detail.stringValue = "使用原遊戲的 DirectDraw"
            action.title = "啟用 cnc-ddraw"
        case "legacy":
            if legacyMode == "off" {
                detail.stringValue = "舊版 DLL 已還原，可改用啟動時載入"
                action.title = "啟用 cnc-ddraw"
            } else if legacyMode == "recovery" {
                detail.stringValue = "舊版 DLL 切換尚未完成"
                action.title = "修復上次切換"
                restore.isHidden = true
            } else {
                detail.stringValue = "此遊戲使用舊版 DLL 安裝方式"
                action.title = "啟用 cnc-ddraw"
                action.isEnabled = false
            }
            detailMessage = "先關閉這個遊戲及其啟動器，再還原舊版 DLL。備份與遊戲資料會保留，之後可使用新的啟動設定。"
        default:
            detail.stringValue = "無法確認 DirectDraw 狀態"
            action.isEnabled = false
        }
        if engineCapability == "unavailable", mode != "legacy" {
            detailMessage = "目前引擎尚不支援這項啟動設定，請先更新引擎。 " + detailMessage
        }
        // Every helper request disables this button; a confirmed state must
        // restore its availability as well as its visibility.
        restore.isEnabled = !restore.isHidden
        let editable = mode == "on" || mode == "off" || (mode == "legacy" && legacyMode == "off")
        filter.isEnabled = editable
        frameRate.isEnabled = editable
        refreshBackend()
    }

    var rendererConflict: String? {
        let enabled = mode == "on" || (mode == "legacy" && ["on", "outdated"].contains(legacyMode))
        guard enabled, let backend = selectedBackend?(),
              backend != .default, backend != .wined3d else { return nil }
        return "目前選用的 " + backend.rawValue + " 與 cnc-ddraw 互斥。請在「顯示」選取「預設」或 WineD3D，或先停用 cnc-ddraw。"
    }

    func refreshBackend() {
        guard !mode.isEmpty else { return }
        explanation.stringValue = rendererConflict ?? detailMessage
    }

    @objc private func settingsChanged() {
        if mode == "on" { performAction(); return }
        refreshBackend()
    }

    @objc func reload() {
        run("status", argument: CyderPaths.engine.path) { [weak self] in self?.update($0) }
    }

    func cancelPendingRead() {
        guard !busy else { return }
        observationGeneration = UUID()
        if let operationID { CyderDirectDrawOperations.shared.cancelRead(operationID) }
        operationID = nil
        operationInFlight = false
    }

    @objc private func restoreOriginal() {
        run(mode == "legacy" ? "restore" : "disable", mutating: true) { [weak self] in self?.update($0) }
    }

    @objc private func performAction() {
        if mode == "legacy" && legacyMode == "recovery" {
            run("recover", mutating: true) { [weak self] in self?.update($0) }
            return
        }
        if let backend = selectedBackend?(), backend != .default, backend != .wined3d {
            detail.stringValue = "請先在「顯示」選取「預設」或 WineD3D，再啟用 cnc-ddraw。"
            return
        }
        let settings: [String: Any] = [
            "filter": filter.indexOfSelectedItem == 1 ? "nearest" : "bilinear",
            "maxfps": Int(frameRate.titleOfSelectedItem ?? "60") ?? 60
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
              let argument = String(data: data, encoding: .utf8) else { return }
        run("enable", argument: argument, mutating: true) { [weak self] in self?.update($0) }
    }

    private func run(_ command: String, argument: String? = nil, mutating: Bool = false,
                     completion: @escaping ([String: Any]) -> Void) {
        guard !operationInFlight else { return }
        if mutating && canMutate?() == false {
            detail.stringValue = "請等遊戲設定讀取或儲存完成，再試一次。"
            return
        }
        operationInFlight = true
        busy = mutating
        if mutating { onBusy?(true) }
        [action, restore, refresh].forEach { $0.isEnabled = false }
        filter.isEnabled = false
        frameRate.isEnabled = false
        detail.stringValue = mutating ? "正在儲存 DirectDraw 設定…" : "正在檢查 DirectDraw…"
        observationGeneration = UUID()
        let generation = observationGeneration
        operationID = CyderDirectDrawOperations.shared.run(command, executable: executable, argument: argument) { [weak self] update in
            guard let self, self.observationGeneration == generation else { return }
            switch update {
            case .stillRunning:
                self.detail.stringValue = "DirectDraw 作業仍在進行，尚未確認結果。"
                self.explanation.stringValue = "請等目前操作結束後再變更設定。"
            case .completed(let result):
                self.operationID = nil
                self.operationInFlight = false
                self.busy = false
                if mutating { self.onBusy?(false) }
                self.refresh.isEnabled = true
                switch result {
                case .success(let value): completion(value)
                case .failure(let error):
                    self.detail.stringValue = error.localizedDescription
                    self.explanation.stringValue = "目前設定尚未確認，請排除問題後重新檢查。"
                }
            }
        }
    }
}

final class CyderGameSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onLaunch: ((URL, CyderExecutableSettings) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onSettingsChanged: (() -> Void)?
    private lazy var directDraw = CyderDirectDrawOptions(executable: game.executableURL)

    private let game: CyderGameRecord
    private var settingsValue = CyderSettings(fontMingLiuTarget: "songti")
    private var presentation = CyderSettingsPresentation()
    private var settingsReady = false
    private var executableAvailable = false
    private var settingsInFlight = false
    private let settingsAccess: CyderSettingsAccess
    private var settingsViewGeneration = UUID()
    private var independent: Bool

    private let launchButton = NSButton()
    private let launchHint = NSTextField(labelWithString: "使用目前選項啟動；測試會寫入 Logs/last-launch.log")
    private let removeProfileButton = NSButton()
    private let customizeFonts = NSSwitch()
    private let retina = NSSwitch()
    private let graphicsBackend = NSPopUpButton()
    private let fontMingLiu = NSPopUpButton()
    private let fontSongti = NSPopUpButton()
    private let smoothing = NSPopUpButton()
    private let scrolling = NSPopUpButton()
    private let environment = CyderPlaceholderTextView()
    private let arguments = CyderPlaceholderTextView()
    private let tabs = NSTabView()
    private var fontsTab: NSTabViewItem?
    private var settingViews: [NSView] = []
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()

    init(game: CyderGameRecord, independent: Bool, settingsAccess: CyderSettingsAccess = .shared) {
        self.game = game
        self.independent = independent
        self.settingsAccess = settingsAccess
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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
            title: "\(game.displayName) 的選項",
            image: CyderGameIconStore.shared.logo(for: game),
            hideImageWhenMissing: true
        )
        buildUI()
        prepareForDisplay()
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !directDraw.busy }

    func windowWillClose(_ notification: Notification) {
        settingsViewGeneration = UUID()
        directDraw.cancelPendingRead()
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    func prepareForDisplay(independent: Bool? = nil) {
        if let independent { self.independent = independent }
        guard !settingsInFlight else { return }
        settingsInFlight = true; settingsReady = false
        setControlsEnabled(false); launchButton.isEnabled = false; confirmButton.isEnabled = false
        removeProfileButton.isEnabled = false
        launchHint.stringValue = "正在讀取設定…"
        let generation = settingsViewGeneration
        let executablePath = game.executablePath
        settingsAccess.perform({ store in
            (store.value, CyderSettingsPresentation.load(), FileManager.default.fileExists(atPath: executablePath))
        }) { [weak self] update in
            guard let self else { return }
            if case .ready = update { self.settingsInFlight = false }
            if case .failed = update { self.settingsInFlight = false }
            guard self.settingsViewGeneration == generation else { return }
            switch update {
            case .ready(let result):
                self.settingsInFlight = false; self.settingsReady = true
                self.settingsValue = result.0; self.presentation = result.1
                self.applyLoadedSettings(executableExists: result.2)
                self.launchHint.stringValue = "使用目前選項啟動；測試會寫入 Logs/last-launch.log"
            case .unconfirmed: self.launchHint.stringValue = "讀取尚未確認；可關閉視窗，稍後再開啟。"
            case .busy:
                self.settingsInFlight = false
                self.launchHint.stringValue = "另一項設定操作仍在進行；請稍後重新開啟。"
            case .failed:
                self.settingsInFlight = false
                self.launchHint.stringValue = "無法讀取設定；原檔未變更。"
            }
        }
    }

    private func applyLoadedSettings(executableExists: Bool) {
        executableAvailable = executableExists
        let global = settingsValue
        let rule = settingsValue.perProfile[game.id]
        let hasFonts = rule?.fontMingLiuTarget != nil
            || rule?.fontSongtiTarget != nil
            || rule?.fontSmoothing != nil
        let mingLiuValue = rule?.fontMingLiuTarget ?? global.fontMingLiuTarget
        let songtiValue = rule?.fontSongtiTarget ?? global.fontSongtiTarget
        let smoothingValue = rule?.fontSmoothing ?? global.fontSmoothing
        customizeFonts.state = hasFonts ? .on : .off
        // Checked = force Retina + 192 DPI; unchecked = follow global preferences.
        retina.state = rule?.retinaMode == true ? .on : .off
        graphicsBackend.selectItem(at: graphicsBackendIndex(rule?.graphicsBackend))
        scrolling.selectItem(at: rule?.scrolling.map { $0.menuIndex + 1 } ?? 0)
        refreshGraphicsControls()
        fontMingLiu.selectItem(at: cyderFontTargetIndex(mingLiuValue))
        fontSongti.selectItem(at: cyderFontTargetIndex(songtiValue))
        smoothing.selectItem(at: smoothingValues.firstIndex(of: smoothingValue) ?? 2)
        environment.string = (rule?.environment ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        arguments.string = formatArguments(rule?.arguments ?? [])
        refreshOptionalTabs()

        confirmButton.isEnabled = true
        launchButton.isEnabled = executableExists
        removeProfileButton.isHidden = !self.independent
        removeProfileButton.isEnabled = self.independent
        setControlsEnabled(executableExists)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        refreshCyderWindowBackground(content)
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
        confirmButton.identifier = NSUserInterfaceItemIdentifier("game-settings-save")
        retina.identifier = NSUserInterfaceItemIdentifier("game-settings-retina")
        confirmButton.title = "套用"
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmSettings)

        graphicsBackend.addItems(withTitles: graphicsBackendTitles)
        // Availability comes from the loaded graphics capabilities, not action validation.
        graphicsBackend.menu?.autoenablesItems = false
        updateD3DMetalMenuItemAvailability()
        updateDxmtMenuItemAvailability()
        graphicsBackend.target = self
        graphicsBackend.action = #selector(graphicsBackendChanged)
        for popup in [fontMingLiu, fontSongti] {
            popup.addItems(withTitles: cyderFontTargetTitles)
        }
        scrolling.identifier = NSUserInterfaceItemIdentifier("game-settings-scrolling")
        scrolling.addItems(withTitles: CyderScrolling.gameTitles)
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
        customizeFonts.target = self
        customizeFonts.action = #selector(customizeChanged)

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(makeGeneralTab())
        tabs.addTabViewItem(makeDisplayTab())
        directDraw.canMutate = { [weak self] in
            guard let self else { return false }
            return self.settingsReady && !self.settingsInFlight
        }
        directDraw.selectedBackend = { [weak self] in
            guard let self, self.settingsReady else { return nil }
            return self.graphicsBackendOverride ?? self.settingsValue.graphicsBackend
        }
        directDraw.onBusy = { [weak self] busy in
            guard let self else { return }
            self.launchButton.isEnabled = !busy && self.executableAvailable
            self.confirmButton.isEnabled = !busy && self.settingsReady
            self.cancelButton.isEnabled = !busy
            self.removeProfileButton.isEnabled = !busy && self.independent
        }
        directDraw.reload()
        fontsTab = makeFontsTab()

        let buttonBar = NSStackView(views: [launchButton, launchHint, NSView(), cancelButton, confirmButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        [launchButton, cancelButton, confirmButton].forEach {
            $0.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        content.addSubview(tabs)
        content.addSubview(buttonBar)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            tabs.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -10),
            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttonBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        refreshAppearance()
    }

    private func makeGeneralTab() -> NSTabViewItem {
        let scrollingScope = NSTextField(wrappingLabelWithString: "同一 prefix 內同名 EXE 會共用滾輪設定；變更需重新啟動遊戲。")
        scrollingScope.font = .systemFont(ofSize: 11)
        scrollingScope.textColor = .secondaryLabelColor
        scrollingScope.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let rows: [NSView] = [
            row(
                "環境變數",
                multilineInput(environment),
                information: "寫 KEY=value。可同行以空白分隔多組，也可換行；換行會當成空白。值含空白請用引號，例如 NAME=\"hello world\"。"
            ),
            row(
                "啟動選項",
                multilineInput(arguments),
                information: "直接接在遊戲執行指令後；以空白分隔參數，含空白的參數可用引號包住。可換行書寫，換行視同空白。"
            ),
            row("自訂字體", customizeFonts, information: "開啟後會出現「字體」分頁；關閉則跟隨偏好設定。"),
            row("滾輪相容", scrolling, information: "選「跟隨全域設定」使用偏好設定的精準捲動開關；預設關閉，使用傳統捲動。傳統捲動可用於新楓之谷等遊戲；精準捲動保留細緻 delta。不自動套用會在下次啟動前還原 Cyder 保存的原值。同一 prefix 內同名 EXE 會共用設定；不同設定請使用獨立遊戲環境。需重新啟動遊戲生效。"),
            scrollingScope,
            removeProfileButton,
        ]
        settingViews.append(contentsOf: rows)
        return tab("一般", rows: rows)
    }

    private func makeDisplayTab() -> NSTabViewItem {
        let displayRows: [NSView] = [
            row(
                "高解析度",
                retina,
                information: "開啟時強制 Retina Mode 與 192 DPI；關閉則跟隨偏好設定。"
            ),
            row("圖形轉譯", graphicsBackend, information: "選「跟隨全域」會使用 Cyder 偏好設定的圖形後端。"),
        ]
        settingViews.append(contentsOf: displayRows)
        return tab("顯示", rows: displayRows + directDraw.rows)
    }

    private func makeFontsTab() -> NSTabViewItem {
        let rows: [NSView] = [
            row("細明體取代", fontMingLiu, information: "細明體組取代目標；選細明體表示不強制取代，需系統已安裝 MingLiU。"),
            row("宋體取代", fontSongti, information: "宋體組取代目標；選宋體時仍會寫入 Songti TC 以確保可讀性。"),
            row("字體平滑", smoothing, information: "控制 Windows 字體平滑方式。"),
        ]
        settingViews.append(contentsOf: rows)
        return tab("字體", rows: rows)
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
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
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

    private func refreshOptionalTabs() {
        let selected = tabs.selectedTabViewItem?.label
        guard let fontsTab else { return }
        let present = tabs.tabViewItems.contains { $0 === fontsTab }
        if customizeFonts.state == .on, !present {
            tabs.addTabViewItem(fontsTab)
        } else if customizeFonts.state != .on, present {
            tabs.removeTabViewItem(fontsTab)
        }
        if let selected,
           let match = tabs.tabViewItems.first(where: { $0.label == selected }) {
            tabs.selectTabViewItem(match)
        } else if tabs.selectedTabViewItem == nil {
            tabs.selectTabViewItem(at: 0)
        }
    }

    @objc private func customizeChanged() {
        refreshOptionalTabs()
    }

    private func refreshAppearance() {
        refreshCyderWindowBackground(window?.contentView)
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
        [customizeFonts, retina, graphicsBackend, fontMingLiu, fontSongti, smoothing, scrolling].forEach {
            $0.isEnabled = enabled
        }
        environment.isEditable = enabled
        arguments.isEditable = enabled
        settingViews.forEach { $0.alphaValue = enabled ? 1 : 0.52 }
    }

    @objc private func launchGame() {
        guard settingsReady, executableAvailable, !settingsInFlight, !directDraw.busy else { return }
        if let conflict = directDraw.rendererConflict {
            showAlert(title: "圖形轉譯設定互斥", message: conflict)
            return
        }
        // Testing is intentionally non-destructive: keep the draft window
        // open so the user can compare, adjust, and test again before Apply.
        onLaunch?(game.executableURL, currentRule())
    }

    @objc private func removeProfile() {
        guard settingsReady, independent, !settingsInFlight, !directDraw.busy else { return }
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

    @objc private func graphicsBackendChanged() {
        refreshGraphicsControls()
    }

    @objc private func cancelSettings() {
        guard !directDraw.busy else { return }
        stopModal(.cancel)
    }

    @objc private func confirmSettings() {
        persistRule()
    }

    private func stopModal(_ response: NSApplication.ModalResponse) {
        directDraw.cancelPendingRead()
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: response)
        }
    }

    private func currentRule() -> CyderExecutableSettings {
        var rule = settingsValue.perProfile[game.id] ?? CyderExecutableSettings()
        // Sync / power are global-only; clear any legacy per-game overrides.
        rule.msync = nil
        rule.esync = nil
        rule.powerMode = nil
        if retina.state == .on {
            rule.retinaMode = true
            rule.dpi = 192
        } else {
            rule.retinaMode = nil
            rule.dpi = nil
        }
        if customizeFonts.state == .on {
            rule.fontMingLiuTarget = cyderFontTarget(at: fontMingLiu.indexOfSelectedItem)
            rule.fontSongtiTarget = cyderFontTarget(at: fontSongti.indexOfSelectedItem)
            rule.fontSmoothing = smoothingValues[max(0, smoothing.indexOfSelectedItem)]
        } else {
            rule.fontMingLiuTarget = nil
            rule.fontSongtiTarget = nil
            rule.fontSmoothing = nil
        }
        rule.scrolling = CyderScrolling.gameSelection(scrolling.indexOfSelectedItem)
        rule.graphicsBackend = graphicsBackendOverride
        rule.dxvkFrameRate = nil
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
        guard settingsReady, !settingsInFlight, !directDraw.busy else { return }
        if let conflict = directDraw.rendererConflict {
            showAlert(title: "圖形轉譯設定互斥", message: conflict)
            return
        }
        var draft = settingsValue
        draft.perProfile[game.id] = currentRule()
        let patch = CyderSettingsPatch(before: settingsValue, after: draft)
        settingsInFlight = true
        let generation = settingsViewGeneration
        confirmButton.isEnabled = false
        setControlsEnabled(false); launchButton.isEnabled = false
        launchHint.stringValue = "正在儲存…"
        settingsAccess.perform({ store in try store.apply(patch); return store.value }) { [weak self] update in
            guard let self else { return }
            if case .ready = update { self.settingsInFlight = false }
            if case .failed = update { self.settingsInFlight = false }
            guard self.settingsViewGeneration == generation else { return }
            switch update {
            case .ready(let value):
                self.settingsInFlight = false; self.settingsValue = value
                self.confirmButton.isEnabled = true
                self.onSettingsChanged?()
                self.stopModal(.OK)
            case .unconfirmed: self.launchHint.stringValue = "儲存尚未確認；關閉視窗不代表取消。"
            case .busy:
                self.settingsInFlight = false; self.confirmButton.isEnabled = true
                self.setControlsEnabled(self.executableAvailable); self.launchButton.isEnabled = self.executableAvailable
                self.launchHint.stringValue = "另一項設定操作仍在進行；請稍後套用。"
            case .failed:
                self.settingsInFlight = false; self.confirmButton.isEnabled = true
                self.setControlsEnabled(self.executableAvailable); self.launchButton.isEnabled = self.executableAvailable
                self.launchHint.stringValue = "無法儲存或設定已被其他視窗修改；草稿仍保留。"
            }
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

    private var smoothingValues: [String] { ["off", "grayscale", "cleartype-rgb"] }

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
        return ["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]
    }

    // Index map (shared by OEM and official): 0 nil/follow, 1 default, 2 d3dmetal, 3 dxmt, 4 dxvk, 5 wined3d.
    private func updateD3DMetalMenuItemAvailability() {
        guard let item = graphicsBackend.item(at: 2) else { return }
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
        guard let item = graphicsBackend.item(at: 3) else { return }
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
        guard let item = graphicsBackend.item(at: 4) else { return }
        item.isEnabled = canSelectDxvk
        if !canSelectDxvk {
            item.toolTip = "需要已安裝的 DXVK 圖形元件"
        } else {
            item.toolTip = nil
        }
    }

    private var graphicsBackendOverride: CyderGraphicsBackend? {
        switch graphicsBackend.indexOfSelectedItem {
        case 1: return .default
        case 2: return canSelectD3DMetal ? .d3dmetal : nil
        case 3: return canSelectDxmt ? .dxmt : nil
        case 4: return canSelectDxvk ? .dxvk : nil
        case 5: return .wined3d
        default: return nil
        }
    }

    private func graphicsBackendIndex(_ value: CyderGraphicsBackend?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .default: return 1
        case .d3dmetal: return canSelectD3DMetal ? 2 : 0
        case .dxmt: return canSelectDxmt ? 3 : 0
        case .dxvk: return canSelectDxvk ? 4 : 0
        case .wined3d: return 5
        }
    }

    private func refreshGraphicsControls() {
        directDraw.refreshBackend()
        updateD3DMetalMenuItemAvailability()
        updateDxmtMenuItemAvailability()
        updateDxvkMenuItemAvailability()
    }

    private func cyderFontTargetIndex(_ target: String) -> Int {
        cyderFontTargetIDs.firstIndex(of: target) ?? 1
    }

    private func cyderFontTarget(at index: Int) -> String {
        cyderFontTargetIDs[max(0, min(index, cyderFontTargetIDs.count - 1))]
    }
}

final class CyderGameLibraryWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onLaunch: ((URL, CyderExecutableSettings?) -> Void)?
    var onRemoveProfile: ((URL, @escaping (Bool) -> Void) -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onPrepareEnvironment: (() -> Void)?
    var onClose: (() -> Void)?

    var isGameSettingsVisible: Bool { gameSettingsController?.window?.isVisible == true }

    private var loader = CyderLibraryLoader()
    private var readOnly = false
    private var hasSnapshot = false
    private let loadStatus = NSTextField(labelWithString: "")
    private let environmentStatus = NSTextField(wrappingLabelWithString: "正在確認環境狀態…")
    private let environmentButton = NSButton()
    private let environmentProgress = NSProgressIndicator()
    private let environmentControls = NSStackView()
    private var environmentState = CyderEnvironmentReadinessObserver.State.checking
    private let recoveryNotice = NSStackView()
    private var recoveryHeight: NSLayoutConstraint?

    private var environmentBusy: Bool {
        guard !readOnly else { return false }
        switch environmentState { case .checking, .preparing, .current(.notPrepared): return true; default: return false }
    }
    private var canInteract: Bool { !environmentBusy && !isQuiescing }
    private var canMutate: Bool { canInteract && !readOnly }

    func updateEnvironmentState(_ state: CyderEnvironmentReadinessObserver.State) {
        environmentState = state
        let presentation = state.initialization
        let progressMessage = state == .current(.notPrepared) ? "正在初始化環境…" : presentation.message
        environmentStatus.stringValue = readOnly ? "目前僅可瀏覽；啟動與修改暫不可用" : (progressMessage ?? "")
        environmentStatus.isHidden = !readOnly && progressMessage == nil
        environmentStatus.toolTip = environmentStatus.stringValue
        let engineUpdate = state == .current(.needsUpdate)
        environmentButton.title = engineUpdate ? "有可用的引擎更新" : (state == .current(.needsBootstrapUpdate) ? "完成環境準備" : "重新檢查")
        if case .failed = state { environmentButton.title = "重試" }
        environmentButton.isBordered = !engineUpdate
        environmentButton.contentTintColor = engineUpdate ? .systemYellow : nil
        environmentButton.isHidden = readOnly || !presentation.showsButton || environmentBusy
        environmentButton.isEnabled = canMutate && presentation.canInitialize
        environmentProgress.isHidden = readOnly || !environmentBusy
        if environmentBusy && !readOnly { environmentProgress.startAnimation(nil) }
        else { environmentProgress.stopAnimation(nil) }
        environmentControls.isHidden = !readOnly && progressMessage == nil && !presentation.showsButton
        refreshInteractionAvailability()
    }

    private func refreshInteractionAvailability() {
        toolbarPreferencesButton.isEnabled = canMutate
        toolbarRefreshButton.isEnabled = canInteract && !loader.isBusy
        toolbarAddButton.isEnabled = canMutate && !loader.isBusy
        emptyAddButton.isEnabled = canMutate && !loader.isBusy
        selectionOptionsButton.isEnabled = canMutate && selectedGame != nil
        selectionLaunchButton.isEnabled = canMutate && selectedGame != nil
        collectionView.isSelectable = canInteract
        collectionView.isInteractionEnabled = canInteract
        collectionView.visibleItems().forEach { ($0 as? CyderGameTileItem)?.setInteractionEnabled(canInteract) }
        recoveryNotice.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = canInteract }
    }
    func showRecoveryNotice() { recoveryNotice.isHidden = false; recoveryHeight?.constant = 28 }
    @objc private func dismissRecoveryNotice() { guard canInteract else { return }; recoveryNotice.isHidden = true; recoveryHeight?.constant = 0 }
    @objc private func openRecoveryLogs() { guard canInteract else { return }; NSWorkspace.shared.open(CyderPaths.support.appendingPathComponent("Logs")) }
    @objc private func prepareEnvironment() {
        guard canMutate, environmentState.initialization.canInitialize,
              let onPrepareEnvironment else { return }
        // Disable synchronously, before the owner starts its asynchronous work.
        updateEnvironmentState(.preparing(environmentState == .current(.needsUpdate) ? "正在更新引擎…" : "正在初始化環境…"))
        onPrepareEnvironment()
    }

    private let iconStore = CyderGameIconStore.shared
    private let collectionView = CyderLibraryCollectionView()
    private let selectionRow = NSStackView()
    private let selectionTitle = NSTextField(labelWithString: "")
    private let selectionOptionsButton = NSButton()
    private let selectionLaunchButton = NSButton()
    private let emptyAddButton = NSButton()
    private let emptyState = NSStackView()
    private var games: [CyderGameRecord] = []
    private var selectedGameID: String?
    private var independentIDs: Set<String> = []
    private var gameSettingsController: CyderGameSettingsWindowController?
    private var macLauncherInstallInProgress = false
    private var revealInProgress = false
    private var isQuiescing = false
    private var revealPresentation: UUID?
    private var installPresentation: UUID?
    var fileActionDeadline: TimeInterval = 5
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var revealInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var installMacLauncher: (CyderGameRecord, @escaping (Result<URL, Error>) -> Void) -> Void = {
        CyderMacLauncherInstaller.install(game: $0, completion: $1)
    }
    private let toolbarPreferencesButton = NSButton()
    private let toolbarRefreshButton = NSButton()
    private let toolbarAddButton = NSButton()
    private let activityStatus = NSTextField(labelWithString: "")
    func updateProgramActivity(_ summary: String) {
        activityStatus.stringValue = summary.replacingOccurrences(of: " · ", with: "\n")
        activityStatus.toolTip = summary
        activityStatus.setAccessibilityLabel("Windows 程式狀態，" + summary)
    }
    convenience init(loader: CyderLibraryLoader? = nil, readOnly: Bool = false) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        self.readOnly = readOnly
        window.contentMinSize = NSSize(width: 500, height: 320)
        let loader = loader ?? CyderLibraryLoader(readOnly: readOnly)
        self.loader = loader
        loader.onUpdate = { [weak self] update in self?.apply(update) }
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let appearanceRoot = CyderAppearanceView(frame: window.contentView?.bounds ?? .zero)
        appearanceRoot.autoresizingMask = [.width, .height]
        window.contentView = appearanceRoot
        buildUI()
        if readOnly {
            toolbarPreferencesButton.isEnabled = false
            toolbarAddButton.isEnabled = false
        }
        updateEnvironmentState(environmentState)
    }

    func windowWillClose(_ notification: Notification) {
        revealPresentation = nil; installPresentation = nil
        onClose?()
    }

    func prepareForDisplay() { loader.request() }

    func quiesce() {
        isQuiescing = true
        updateEnvironmentState(environmentState)
        updateSelectionRow()
        revealPresentation = nil; installPresentation = nil
        loader.quiesce()
    }

    private func apply(_ update: CyderLibraryLoader.Update) {
        precondition(Thread.isMainThread)
        switch update {
        case .loading: loadStatus.stringValue = "正在讀取遊戲庫…"
        case .unconfirmed: loadStatus.stringValue = readOnly ? "讀取時間較長；仍可退出" : "讀取時間較長；仍可開啟設定或退出"
        case .failed: loadStatus.stringValue = readOnly ? "暫時無法讀取遊戲庫；請重新整理" : "暫時無法讀取或儲存遊戲庫；請重新整理"
        case .ready(let snapshot):
            hasSnapshot = true
            games = snapshot.games; independentIDs = snapshot.independentIDs
            if let id = snapshot.selectedID { selectedGameID = id }
            if let id = selectedGameID, !games.contains(where: { $0.id == id }) { selectedGameID = nil }
            loadStatus.stringValue = ""
            ensureGameIcons()
        }
        reloadGrid()
        refreshInteractionAvailability()
    }

    /// Re-run extract after Wine bootstrap so tiles that opened during first-run
    /// setup are not stuck on placeholders until the user hits refresh.
    func retryMissingIcons() {
        guard window?.isVisible == true else { return }
        ensureGameIcons()
    }

    private func ensureGameIcons() {
        guard !readOnly else { return }
        iconStore.ensureExtracted(games: games) { [weak self] in
            self?.reloadGrid()
        }
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        refreshCyderWindowBackground(content)
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

        configureTitlebarButton(
            toolbarPreferencesButton,
            symbol: "gearshape",
            label: "偏好設定",
            action: #selector(openPreferences)
        )
        configureTitlebarButton(
            toolbarRefreshButton,
            symbol: "arrow.clockwise",
            label: "重新整理遊戲庫",
            action: #selector(refreshLibrary)
        )
        configureTitlebarButton(
            toolbarAddButton,
            symbol: "plus",
            label: "加入遊戲",
            action: #selector(addGame)
        )
        addCyderTitlebarButtons(
            to: window,
            buttons: [toolbarPreferencesButton, toolbarRefreshButton, toolbarAddButton]
        )

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        let emptyTitle = NSTextField(labelWithString: "尚未加入遊戲")
        emptyTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let emptyDescription = NSTextField(labelWithString: "選擇 EXE 即可開始遊玩")
        emptyDescription.font = .systemFont(ofSize: 12)
        emptyDescription.textColor = .secondaryLabelColor
        emptyAddButton.title = "加入遊戲"
        emptyAddButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "加入遊戲")
        emptyAddButton.target = self; emptyAddButton.action = #selector(addGame)
        emptyAddButton.imagePosition = .imageLeading
        emptyAddButton.bezelStyle = .rounded
        emptyState.setViews([emptyIcon, emptyTitle, emptyDescription, emptyAddButton], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 9
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        loadStatus.font = .systemFont(ofSize: 11)
        loadStatus.textColor = .secondaryLabelColor
        loadStatus.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(loadStatus)

        selectionOptionsButton.title = "遊戲選項…"
        selectionOptionsButton.target = self; selectionOptionsButton.action = #selector(openSettingsForSelectedGame)
        selectionLaunchButton.title = "啟動遊戲"
        selectionLaunchButton.target = self; selectionLaunchButton.action = #selector(launchSelection)
        selectionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        selectionTitle.lineBreakMode = .byTruncatingTail
        selectionTitle.alignment = .right
        selectionTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(selectionTitle)
        selectionRow.setViews([selectionOptionsButton, selectionLaunchButton], in: .trailing)
        selectionRow.spacing = 8
        selectionRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(selectionRow)
        environmentStatus.font = .systemFont(ofSize: 11)
        environmentStatus.textColor = .secondaryLabelColor
        environmentStatus.maximumNumberOfLines = 2
        environmentStatus.lineBreakMode = .byTruncatingTail
        environmentStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        environmentButton.target = self; environmentButton.action = #selector(prepareEnvironment)
        environmentButton.bezelStyle = .rounded
        environmentButton.font = .systemFont(ofSize: 11)
        environmentProgress.style = .spinning
        environmentProgress.controlSize = .small
        environmentProgress.setAccessibilityLabel("正在準備 Windows 環境")
        environmentProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        environmentProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        environmentControls.setViews([environmentProgress, environmentStatus, environmentButton], in: .leading)
        environmentControls.orientation = .horizontal; environmentControls.spacing = 6
        environmentControls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(environmentControls)
        activityStatus.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        activityStatus.textColor = .secondaryLabelColor
        activityStatus.alignment = .center
        activityStatus.maximumNumberOfLines = 2
        activityStatus.lineBreakMode = .byTruncatingTail
        activityStatus.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(activityStatus)
        let recoveryLogs = NSButton(title: "上次未正常結束 · 查看記錄", target: self, action: #selector(openRecoveryLogs))
        recoveryLogs.bezelStyle = .rounded
        let dismissRecovery = NSButton(title: "關閉提示", target: self, action: #selector(dismissRecoveryNotice))
        dismissRecovery.bezelStyle = .rounded
        recoveryNotice.setViews([recoveryLogs, dismissRecovery], in: .leading)
        recoveryNotice.orientation = .horizontal; recoveryNotice.spacing = 8
        recoveryNotice.isHidden = true; recoveryNotice.translatesAutoresizingMaskIntoConstraints = false
        recoveryHeight = recoveryNotice.heightAnchor.constraint(equalToConstant: 0)
        content.addSubview(recoveryNotice)
        content.addSubview(scroll)
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            recoveryNotice.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            recoveryNotice.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            recoveryNotice.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            recoveryHeight!,
            scroll.topAnchor.constraint(equalTo: recoveryNotice.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: loadStatus.topAnchor, constant: -4),
            loadStatus.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            loadStatus.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            loadStatus.bottomAnchor.constraint(equalTo: selectionTitle.topAnchor, constant: -4),
            selectionTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            selectionTitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            selectionTitle.bottomAnchor.constraint(equalTo: selectionRow.topAnchor, constant: -4),
            selectionTitle.heightAnchor.constraint(equalToConstant: 18),
            selectionRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            selectionRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            selectionRow.heightAnchor.constraint(equalToConstant: 28),
            activityStatus.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            activityStatus.centerYAnchor.constraint(equalTo: selectionRow.centerYAnchor),
            activityStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
            activityStatus.trailingAnchor.constraint(lessThanOrEqualTo: selectionRow.leadingAnchor, constant: -6),
            environmentControls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            environmentControls.trailingAnchor.constraint(lessThanOrEqualTo: activityStatus.leadingAnchor, constant: -6),
            environmentControls.centerYAnchor.constraint(equalTo: selectionRow.centerYAnchor),
            environmentControls.heightAnchor.constraint(lessThanOrEqualToConstant: 32),
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
        collectionView.delegate = self
        collectionView.setAccessibilityLabel("遊戲庫")
        collectionView.onLaunchSelection = { [weak self] in self?.launchSelection() }
        collectionView.register(CyderGameTileItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("CyderGameTileItem"))
        collectionView.collectionViewLayout = CyderFiveColumnGridLayout()
    }

    private func reloadGrid() {
        let selectedID = selectedGameID
        collectionView.reloadData()
        if let index = games.firstIndex(where: { $0.id == selectedID }) {
            selectGame(games[index])
        } else {
            selectedGameID = nil
            updateSelectionRow()
        }
        let isEmpty = games.isEmpty
        emptyState.isHidden = !isEmpty || !hasSnapshot
        collectionView.isHidden = isEmpty
        toolbarAddButton.isHidden = isEmpty && hasSnapshot
        DispatchQueue.main.async { [weak self] in
            self?.collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    private func refreshAppearance() {
        refreshCyderWindowBackground(window?.contentView)
        collectionView.needsDisplay = true
        collectionView.visibleItems().forEach { $0.view.needsDisplay = true }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { games.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("CyderGameTileItem")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! CyderGameTileItem
        let game = games[indexPath.item]
        item.onClick = { [weak self] in
            guard let self, self.canInteract else { return }
            self.selectGame(game)
            self.window?.makeFirstResponder(self.collectionView)
        }
        item.onDoubleClick = { [weak self] in self?.launch(game) }
        item.onContextMenu = { [weak self] in self?.contextMenu(for: game) }
        // image(for:) returns a PE logo or a neutral placeholder — never the
        // macOS generic EXE document icon — and schedules extraction when needed.
        item.configure(record: game, independent: independentIDs.contains(game.id), readOnly: readOnly, image: readOnly ? (NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage()) : iconStore.image(for: game))
        item.setInteractionEnabled(canInteract)
        item.isSelected = game.id == selectedGameID
        return item
    }

    private func selectGame(_ game: CyderGameRecord) {
        guard canInteract, let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let paths: Set<IndexPath> = [IndexPath(item: index, section: 0)]
        if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
        selectedGameID = game.id
        updateSelectionRow()
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard canInteract, let path = indexPaths.first, games.indices.contains(path.item) else { return }
        selectedGameID = games[path.item].id
        updateSelectionRow()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard canInteract, collectionView.selectionIndexPaths.isEmpty else { return }
        selectedGameID = nil
        updateSelectionRow()
    }

    private func updateSelectionRow() {
        selectionTitle.stringValue = selectedGame?.displayName ?? ""
        selectionTitle.toolTip = selectedGame?.displayName
        refreshInteractionAvailability()
    }

    @objc private func launchSelection() {
        if let game = selectedGame { launch(game) }
    }

    private func contextMenu(for game: CyderGameRecord) -> NSMenu {
        guard canInteract else { return NSMenu() }
        selectGame(game)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let macAppTitle = game.macAppPath != nil
            ? "更新 macOS 應用程式"
            : "加入 macOS 應用程式"
        let macApp = menu.addItem(withTitle: macAppTitle, action: #selector(installMacAppForSelectedGame), keyEquivalent: "")
        macApp.target = self
        macApp.isEnabled = canMutate && !macLauncherInstallInProgress
        let options = menu.addItem(withTitle: "選項", action: #selector(openSettingsForSelectedGame), keyEquivalent: "")
        options.target = self
        options.isEnabled = canMutate
        let reveal = menu.addItem(withTitle: "顯示於 Finder", action: #selector(revealSelectedGameInFinder), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = canInteract && !revealInProgress
        return menu
    }

    private func configureTitlebarButton(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        button.target = self
        button.action = action
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func openPreferences() {
        guard canMutate else { return }
        onOpenPreferences?()
    }

    @objc private func refreshLibrary() { guard canInteract else { return }; prepareForDisplay() }

    @objc private func addGame() {
        guard canMutate, !loader.isBusy else { return }
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
        guard panel.runModal() == .OK, canMutate, let url = panel.url else { return }
        loader.request(.add(url))
    }

    private func launch(_ game: CyderGameRecord) {
        guard canMutate, games.contains(where: { $0.id == game.id }) else { return }
        // The accepted launch path performs file validation off AppKit.
        onLaunch?(game.executableURL, nil)
    }

    @objc private func openSettingsForSelectedGame() {
        guard canMutate, let game = selectedGame else { return }
        let controller = CyderGameSettingsWindowController(game: game, independent: independentIDs.contains(game.id))
        controller.onLaunch = { [weak self] executable, settings in
            guard let self, self.canMutate else { return }
            self.onLaunch?(executable, settings)
        }
        controller.onRemoveProfile = { [weak self] executable, completion in
            guard let self, self.canMutate else { completion(false); return }
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

    @objc private func revealSelectedGameInFinder() {
        guard canInteract, !revealInProgress, let game = selectedGame else { return }
        let url = game.executableURL
        let presentation = UUID(), exists = fileExists
        revealInProgress = true; revealPresentation = presentation
        DispatchQueue.main.asyncAfter(deadline: .now() + fileActionDeadline) { [weak self] in
            guard let self, self.revealPresentation == presentation, !self.isQuiescing else { return }
            self.revealPresentation = nil
            self.loadStatus.stringValue = "檔案位置尚未確認；可先繼續使用，稍後再試"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let available = exists(url.path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.revealInProgress = false
                guard self.revealPresentation == presentation, !self.isQuiescing else { return }
                self.revealPresentation = nil
                guard self.canInteract, self.window?.isVisible == true, self.selectedGameID == game.id else { return }
                if available { self.loadStatus.stringValue = ""; self.revealInFinder([url]) }
                else { self.loadStatus.stringValue = "找不到遊戲：這個 EXE 已不在原本的位置" }
            }
        }
    }

    @objc private func installMacAppForSelectedGame() {
        guard canMutate, let game = selectedGame, !macLauncherInstallInProgress else { return }
        macLauncherInstallInProgress = true
        let updating = game.macAppPath != nil
        let presentation = UUID()
        installPresentation = presentation
        self.loadStatus.stringValue = "正在建立 macOS 應用程式…"
        DispatchQueue.main.asyncAfter(deadline: .now() + fileActionDeadline) { [weak self] in
            guard let self, self.installPresentation == presentation, !self.isQuiescing else { return }
            self.installPresentation = nil
            self.loadStatus.stringValue = "建立結果尚未確認；可先繼續使用，稍後在 Finder 檢查"
        }
        installMacLauncher(game) { [weak self] result in
            guard let self else { return }
            guard self.installPresentation == presentation, !self.isQuiescing else {
                self.macLauncherInstallInProgress = false
                return
            }
            switch result {
            case .success(let appURL):
                self.loader.request(.setMacApp(game.id, appURL.path)) { [weak self] saved in
                    guard let self else { return }
                    self.macLauncherInstallInProgress = false
                    guard self.installPresentation == presentation, !self.isQuiescing else { return }
                    self.installPresentation = nil
                    guard self.window?.isVisible == true else { return }
                    self.loadStatus.stringValue = ""
                    let persistFailed = !saved
                    let alert = NSAlert()
                    if persistFailed {
                        alert.messageText = updating ? "已更新應用程式，但未寫入遊戲庫" : "已建立應用程式，但未寫入遊戲庫"
                        alert.informativeText =
                            "\(appURL.path)\n\n可在 Finder 使用此捷徑，但遊戲庫可能仍顯示「加入 macOS 應用程式」。"
                        alert.alertStyle = .warning
                    } else {
                        alert.messageText = updating ? "已更新 macOS 應用程式" : "已加入 macOS 應用程式"
                        alert.informativeText =
                            "可在 Launchpad 或「\(CyderMacLauncherInstaller.outputDirectory().path)」找到 \(game.displayName)。"
                        alert.alertStyle = .informational
                    }
                    alert.addButton(withTitle: "在 Finder 中顯示")
                    alert.addButton(withTitle: "知道了")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                }
            case .failure(let error):
                self.macLauncherInstallInProgress = false
                self.installPresentation = nil
                self.loadStatus.stringValue = ""
                self.showAlert(title: "無法建立 macOS 應用程式", message: error.localizedDescription)
            }
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
