import Cocoa

private final class CyderUnavailableBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One nonmodal fallback when there is no confirmed request authority. It never
/// retries a launch; uncertain forwarding stays distinct from definite refusal.
final class CyderUnavailableWindowController: NSWindowController, NSWindowDelegate {
    enum Reason {
        case ownershipUnavailable, forwardUnconfirmed
        var title: String {
            self == .ownershipUnavailable ? "暫時無法接受啟動要求" : "啟動要求尚未確認"
        }
        var detail: String {
            switch self {
            case .ownershipUnavailable:
                return "暫時無法讀取啟動紀錄或確認目前狀態。您仍可瀏覽遊戲庫、查看診斷記錄，或退出後再開啟 Cyder。現有 Windows 程式不受影響。"
            case .forwardUnconfirmed:
                return "先前的要求可能已被接受，請先確認程式是否已開啟，避免重複啟動。關閉此視窗不代表取消要求，也不會自動重新啟動程式。"
            }
        }
    }
    var onLibrary: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onQuit: (() -> Void)?
    var onClose: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "Cyder"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let background = CyderUnavailableBackgroundView(frame: window.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]; window.contentView = background
        guard let content = window.contentView else { return }
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 13); detail.textColor = .secondaryLabelColor
        let library = NSButton(title: "瀏覽遊戲庫", target: self, action: #selector(browse))
        let logs = NSButton(title: "診斷記錄", target: self, action: #selector(diagnostics))
        let quit = NSButton(title: "退出 Cyder", target: self, action: #selector(quit))
        for button in [library, logs, quit] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [library, logs, NSView(), quit]); footer.spacing = 8
        for view in [heading, detail, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.topAnchor.constraint(greaterThanOrEqualTo: detail.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }
    func update(_ reason: Reason) { heading.stringValue = reason.title; detail.stringValue = reason.detail }
    func windowWillClose(_ notification: Notification) { onClose?() }
    @objc private func browse() { onLibrary?() }
    @objc private func diagnostics() { onDiagnostics?() }
    @objc private func quit() { onQuit?() }
}
