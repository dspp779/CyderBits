import Cocoa

/// Observes only the packaged Ruby scanner. Never invokes Wine or a repair command.
final class CyderComponentDiagnosticsController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let runner = CyderProcessRunner()
    private var operation: UUID?
    private var generation = UUID()
    private let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 300))
    private let start = NSButton(title: "重新檢查", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)

    private let resources: URL?
    private let runtime: URL
    private let budget: TimeInterval
    private let engine: URL
    var diagnosticText: String { text.string }
    var isChecking: Bool { operation != nil }

    init(resources: URL? = Bundle.main.resourceURL, runtime: URL = CyderPaths.runtimeRoot, engine: URL = CyderPaths.engine, budget: TimeInterval = 60) {
        self.resources = resources; self.runtime = runtime; self.engine = engine; self.budget = min(300, max(0.1, budget))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "執行元件完整性診斷"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        text.isEditable = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        start.target = self; start.action = #selector(runScan)
        cancel.target = self; cancel.action = #selector(cancelScan)
        let buttons = NSStackView(views: [start, cancel])
        buttons.spacing = 12
        let note = NSTextField(wrappingLabelWithString: "唯讀檢查 Wine、DXVK 與 DXMT；不掃描遊戲、不修復、不更改登錄值。最多 60 秒。缺檔不代表已證實遭防毒軟體移除。")
        let stack = NSStackView(views: [note, scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func runScan() {
        guard operation == nil, let resources = resources else { return }
        let stamp = UUID(); generation = stamp
        start.isEnabled = false; cancel.isEnabled = true
        text.string = "正在背景檢查…"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [resources.appendingPathComponent("ogom-scripts/cyder-component-integrity.rb").path,
            "check", "--resources", resources.path, "--runtime", runtime.path,
            "--engine", engine.path, "--depth", "full", "--budget", String(budget)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Drain off the main thread, retaining at most 4 MiB. No on-disk report/cache.
        let drained = DispatchGroup(); drained.enter()
        let output = CyderIntegrityOutput()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
            }
            try? pipe.fileHandleForReading.close()
        }
        operation = runner.run(process: process, policy: .observation, deadline: budget + 1, onRelease: {
            try? pipe.fileHandleForWriting.close()
        }) { [weak self] outcome in
            let finish = { [weak self] in
                guard let self, self.generation == stamp else { return }
                self.operation = nil; self.start.isEnabled = true; self.cancel.isEnabled = false
                if case .exited = outcome {
                    self.text.string = Self.describe(output.data, overflow: output.overflow)
                } else {
                    self.text.string = "無法確認：檢查已取消、逾時或無法啟動。未修復或變更任何元件。"
                }
            }
            if case .exited = outcome { drained.notify(queue: .main, execute: finish) }
            else { finish() } // An observer deadline never waits for a pipe to close.
        }
    }

    @objc func cancelScan() {
        generation = UUID()
        if let operation { runner.cancelObservation(operation) }
        operation = nil; start.isEnabled = true; cancel.isEnabled = false
        text.string = "已取消；未完成的檢查結果為無法確認。未修復或變更任何元件。"
    }
    func windowWillClose(_ notification: Notification) { cancelScan(); onClose?() }

    static func describe(_ data: Data, overflow: Bool = false) -> String {
        guard !overflow, let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = report["status"] as? String else { return "無法確認：診斷輸出不完整或格式無效。" }
        let labels = ["ok": "符合清單", "mismatch": "發現差異", "unknown": "無法確認", "missing": "缺檔",
                      "source_mismatch": "來源不符", "content_mismatch": "內容不符", "signature_invalid": "簽章無效", "signature_unsigned": "未簽署（政策不允許）",
                      "signature_policy_mismatch": "簽署者或時間戳不符"]
        func label(_ value: Any?) -> String { let raw = value as? String ?? "unknown"; return labels[raw] ?? "無法確認" }
        let reasons = ["publisher_unverified": "無法確認正式發行者；開發／測試版也會顯示此結果。",
                       "system_signature_verifier_unavailable": "系統簽章驗證服務不可用。",
                       "bundle_signature_invalid": "App 簽章或資源不完整。",
                       "timeout": "檢查逾時；尚未完成的項目無法確認。", "cancelled": "檢查已取消。",
                       "trust_or_inventory_unavailable": "無法讀取或驗證元件清單。"]
        let reason = report["reason"] as? String ?? ""
        var lines = ["結果：\(label(status))", reasons[reason] ?? reason]
        for component in report["components"] as? [[String: Any]] ?? [] {
            lines.append("\n\(component["component"] as? String ?? "?") \(component["version"] as? String ?? "")：\(label(component["status"]))")
            lines.append("已檢查 \(component["checked"] ?? 0) / \(component["inventoryCount"] ?? "?") 項；\(component["bytesRead"] ?? 0) bytes；\(component["elapsedMs"] ?? 0) ms")
            if let reason = component["reason"] { lines.append("原因：\(reason)") }
            let issues = (component["files"] as? [[String: Any]] ?? []).filter { ($0["status"] as? String) != "ok" || ($0["signaturePolicy"] as? String) == "upstream-unsigned" }
            for file in issues.prefix(200) {
                let state = (file["signaturePolicy"] as? String) == "upstream-unsigned" ? "上游原件未簽署（符合精確來源例外）" : label(file["status"])
                lines.append("\(state)：\(file["path"] as? String ?? "?")")
            }
            if issues.count > 200 { lines.append("另有 \(issues.count - 200) 項差異未顯示。") }
        }
        lines.append("\n本結果只代表元件完整性證據，不是防毒判定或遊戲相容性驗收。開發／測試版未驗證發行者時，結果為無法確認。")
        return lines.joined(separator: "\n")
    }
}

private final class CyderIntegrityOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = 4 * 1024 * 1024 - bytes.count
        if chunk.count > remaining { exceeded = true }
        bytes.append(chunk.prefix(remaining))
    }
}
