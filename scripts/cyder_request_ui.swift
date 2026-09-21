import Cocoa

struct CyderRequestRow: Equatable {
    let id: String
    let title: String
    let detail: String
    let canResume: Bool
    let canCancel: Bool
    static func project(_ records: [CyderRequestJournal.Record]) -> [Self] {
        records.compactMap { record in
            guard record.children == nil else { return nil }
            let detail: String
            switch record.phase {
            case .queued: detail = "等待啟動；可取消"
            case .awaitingUserResume: detail = "上次尚未啟動"
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
        }.sorted { $0.id < $1.id }
    }
    static func summary(_ records: [CyderRequestJournal.Record]) -> String {
        let rows = project(records)
        guard !rows.isEmpty else { return "" }
        let waiting = rows.filter(\.canResume).count
        return waiting > 0 ? "上次有 \(waiting) 個項目尚未啟動 · 查看要求" : "\(rows.count) 個啟動要求 · 查看狀態"
    }
}

/// Nonmodal projection of durable request state. Buttons carry stable IDs;
/// both this view and the journal recheck capability before any action.
final class CyderRequestWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case resume, cancel }
    var onResume: ((String, @escaping (Bool) -> Void) -> Void)?
    var onCancel: ((String, @escaping (Bool) -> Void) -> Void)?
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
    func update(_ records: [CyderRequestJournal.Record]) {
        precondition(Thread.isMainThread)
        rows = CyderRequestRow.project(records)
        table.reloadData()
        if rows.isEmpty { feedback.stringValue = "沒有等待處理的啟動要求。" }
    }
    func perform(_ action: Action, id: String) {
        precondition(Thread.isMainThread)
        guard !pending.contains(id), let row = rows.first(where: { $0.id == id }),
              (action == .resume ? row.canResume : row.canCancel) else { return }
        let callback = action == .resume ? onResume : onCancel
        guard let callback else { return }
        pending.insert(id); table.reloadData(); feedback.stringValue = "正在儲存變更…"
        callback(id) { [weak self] succeeded in
            guard let self else { return }
            self.pending.remove(id); self.table.reloadData()
            self.feedback.stringValue = succeeded
                ? (action == .resume ? "已加入啟動佇列。" : "已取消尚未派送的要求。")
                : "狀態已改變或無法儲存；請重新整理。已派送的程式不會被終止。"
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
        for (label, allowed, tag) in [("繼續", item.canResume, 0), ("取消", item.canCancel, 1)] where allowed {
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
        perform(sender.tag == 0 ? .resume : .cancel, id: id)
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
