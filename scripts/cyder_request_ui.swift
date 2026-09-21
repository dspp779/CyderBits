import Cocoa

struct CyderRequestRow: Equatable {
    let id: String
    let title: String
    let detail: String
    let canResume: Bool
    let canCancel: Bool
    var canResend = false
    var canWithdraw = false
    static func project(_ records: [CyderRequestJournal.Record], outbox: [CyderOutboxNotice] = []) -> [Self] {
        let accepted: [Self] = records.compactMap { record in
            guard record.children == nil else { return nil }
            let detail: String
            switch record.phase {
            case .queued: detail = "等待啟動；可取消"
            case .awaitingUserResume:
                detail = record.outcome?.hasPrefix("scope-") == true
                    ? "環境暫時無法確認；尚未派送，可稍後繼續" : "上次尚未啟動"
            case .dispatching, .observing: detail = "正在啟動；已無法取消派送"
            case .uncertain: detail = "啟動結果尚未確認；不會自動重試"
            case .failed: detail = "啟動未完成；可查看診斷記錄"
            case .completed, .cancelled: return nil
            }
            let name = record.displayName ?? record.payload?.displayName ?? "啟動要求 \(record.id.suffix(6))"
            let title = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(100))
            return Self(id: record.id, title: title, detail: detail,
                canResume: record.phase == .awaitingUserResume,
                canCancel: [.queued, .awaitingUserResume].contains(record.phase))
        }
        let retained = outbox.map { notice in
            Self(id: notice.id,
                 title: String(notice.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(100)),
                 detail: notice.detail, canResume: false, canCancel: false, canResend: notice.canRecover, canWithdraw: notice.canRecover)
        }
        return (accepted + retained).sorted { $0.id < $1.id }
    }
    static func summary(_ records: [CyderRequestJournal.Record], outbox: [CyderOutboxNotice] = []) -> String {
        let rows = project(records, outbox: outbox)
        guard !rows.isEmpty else { return "" }
        if !outbox.isEmpty { return "\(outbox.count) 個舊要求尚待核對 · 查看狀態" }
        let waiting = rows.filter(\.canResume).count
        if records.contains(where: { $0.phase == .awaitingUserResume && $0.outcome?.hasPrefix("scope-") == true }) {
            return "\(waiting) 個項目尚未啟動 · 查看要求"
        }
        return waiting > 0 ? "上次有 \(waiting) 個項目尚未啟動 · 查看要求" : "\(rows.count) 個啟動要求 · 查看狀態"
    }
}

/// Nonmodal projection of durable request state. Buttons carry stable IDs;
/// both this view and the journal recheck capability before any action.
final class CyderRequestWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case resume, cancel, resend, withdraw }
    var onResume: ((String, @escaping (Bool) -> Void) -> Void)?
    var onCancel: ((String, @escaping (Bool) -> Void) -> Void)?
    var onResend: ((String, @escaping (Bool) -> Void) -> Void)?
    var onWithdraw: ((String, @escaping (Bool) -> Void) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var rows: [CyderRequestRow] = []
    private var pending = Set<String>()
    private let table = NSTableView()
    private let feedback = NSTextField(wrappingLabelWithString: "")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "啟動要求"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 560, height: 260); window.center()
        build()
    }
    func update(_ records: [CyderRequestJournal.Record], outbox: [CyderOutboxNotice] = []) {
        precondition(Thread.isMainThread)
        rows = CyderRequestRow.project(records, outbox: outbox)
        table.reloadData()
        if rows.isEmpty { feedback.stringValue = "沒有等待處理的啟動要求。" }
    }
    func perform(_ action: Action, id: String) {
        precondition(Thread.isMainThread)
        guard !pending.contains(id), let row = rows.first(where: { $0.id == id }) else { return }
        let allowed: Bool
        let callback: ((String, @escaping (Bool) -> Void) -> Void)?
        switch action {
        case .resume: allowed = row.canResume; callback = onResume
        case .cancel: allowed = row.canCancel; callback = onCancel
        case .resend: allowed = row.canResend; callback = onResend
        case .withdraw: allowed = row.canWithdraw; callback = onWithdraw
        }
        guard allowed else { return }
        guard let callback else { return }
        pending.insert(id); table.reloadData(); feedback.stringValue = "正在儲存變更…"
        callback(id) { [weak self] succeeded in
            guard let self else { return }
            self.pending.remove(id); self.table.reloadData()
            self.feedback.stringValue = succeeded
                ? (action == .resume ? "已加入啟動佇列。" : action == .resend ? "已核對原要求；請查看更新狀態。" : "已取消尚未派送的要求。")
                : "結果尚未確認或狀態已改變；請重新整理。關閉視窗不代表取消。"
        }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let buttons = NSStackView(); buttons.orientation = .horizontal
        for (label, allowed, tag) in [("繼續", item.canResume, 0), ("取消", item.canCancel, 1), ("重新傳送", item.canResend, 2), ("取消", item.canWithdraw, 3)] where allowed {
            let button = NSButton(title: label, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.id); button.tag = tag
            button.bezelStyle = .rounded; button.isEnabled = !pending.contains(item.id)
            button.setAccessibilityLabel("\(label)：\(item.title)")
            buttons.addArrangedSubview(button)
        }
        let cell = NSView()
        let stack = NSStackView(views: [labels, NSView(), buttons]); stack.orientation = .horizontal; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    @objc private func pressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let actions: [Action] = [.resume, .cancel, .resend, .withdraw]
        guard actions.indices.contains(sender.tag) else { return }
        perform(actions[sender.tag], id: id)
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func diagnostics() { onOpenDiagnostics?() }
    private func build() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: .init("request")); column.width = 630; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 64; table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("啟動要求狀態")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        let refresh = NSButton(title: "重新整理", target: self, action: #selector(refresh))
        let logs = NSButton(title: "診斷記錄", target: self, action: #selector(diagnostics))
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [feedback, NSView(), logs, refresh]); footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }
}

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
