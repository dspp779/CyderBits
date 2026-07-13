import AppKit
import Foundation
import UniformTypeIdentifiers

private final class PIDTestAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let winePathField = NSTextField()
    private let prefixPathField = NSTextField()
    private let exePathField = NSTextField()
    private let wrapperPIDField = NSTextField()
    private let pidField = NSTextField()
    private let autoCooperateCheckbox = NSButton(
        checkboxWithTitle: "收到同一 WINEPREFIX 的通知時，自動 yield + activateFrom",
        target: nil,
        action: nil
    )
    private let statusTextView = NSTextView()
    private let statusScrollView = NSScrollView()
    private var processes: [Int32: Process] = [:]
    private var logHandles: [Int32: FileHandle] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(wineAppWillActivate(_:)),
            name: Notification.Name("WineAppWillActivateNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appendStatus("已開始監聽 WineAppWillActivateNotification。")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder", isDirectory: true)
        winePathField.stringValue = support
            .appendingPathComponent("Engines/wine-x86_64/bin/wine").path
        prefixPathField.stringValue = support.appendingPathComponent("SharedPrefix").path
        wrapperPIDField.placeholderString = "啟動後顯示 Process.processIdentifier"
        pidField.placeholderString = "收到 Wine 通知後自動填入，也可手動輸入 PID"

        winePathField.isEditable = true
        prefixPathField.isEditable = true
        exePathField.isEditable = true
        wrapperPIDField.isEditable = false
        wrapperPIDField.isSelectable = true
        pidField.isEditable = true
        autoCooperateCheckbox.state = .on

        statusTextView.isEditable = false
        statusTextView.isSelectable = true
        statusTextView.isRichText = false
        statusTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusTextView.textContainerInset = NSSize(width: 8, height: 8)
        statusTextView.isVerticallyResizable = true
        statusTextView.isHorizontallyResizable = false
        statusTextView.autoresizingMask = [.width]
        statusTextView.textContainer?.widthTracksTextView = true
        statusScrollView.documentView = statusTextView
        statusScrollView.hasVerticalScroller = true
        statusScrollView.borderType = .bezelBorder

        let chooseButton = NSButton(title: "選擇 EXE…", target: self, action: #selector(chooseExe))
        chooseButton.bezelStyle = .rounded
        let launchButton = NSButton(title: "啟動 Wine EXE", target: self, action: #selector(launchExe))
        launchButton.bezelStyle = .rounded
        launchButton.keyEquivalent = "\r"
        let activateButton = NSButton(title: "普通 activate", target: self, action: #selector(activatePIDNormally))
        activateButton.bezelStyle = .rounded
        let cooperativeButton = NSButton(
            title: "yield + activateFrom",
            target: self,
            action: #selector(activatePIDCooperatively)
        )
        cooperativeButton.bezelStyle = .rounded

        let title = NSTextField(labelWithString: "Cyder Wine PID / Frontmost 測試")
        title.font = .boldSystemFont(ofSize: 18)
        let explanation = NSTextField(wrappingLabelWithString:
            "直接執行 /usr/bin/arch -x86_64 wine EXE，並監聽 CrossOver Wine 的 WineAppWillActivateNotification。可比較 wrapper PID、Wine 回報的真正 App PID，以及兩種 activation 方法。"
        )

        let launchRow = NSStackView(views: [launchButton, chooseButton])
        launchRow.orientation = .horizontal
        launchRow.spacing = 8
        launchRow.alignment = .centerY

        let activateRow = NSStackView(views: [activateButton, cooperativeButton])
        activateRow.orientation = .horizontal
        activateRow.spacing = 8
        activateRow.alignment = .centerY

        let stack = NSStackView(views: [
            title,
            explanation,
            labeledRow("Wine：", winePathField),
            labeledRow("WINEPREFIX：", prefixPathField),
            labeledRow("EXE：", exePathField),
            launchRow,
            labeledRow("Wrapper PID：", wrapperPIDField),
            labeledRow("Wine／指定 PID：", pidField),
            autoCooperateCheckbox,
            activateRow,
            statusScrollView,
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cyder PID Test Launcher"
        window.center()
        window.contentView = NSView()
        window.contentView?.addSubview(stack)

        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            winePathField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -120),
            prefixPathField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -120),
            exePathField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -120),
            wrapperPIDField.widthAnchor.constraint(equalToConstant: 360),
            pidField.widthAnchor.constraint(equalToConstant: 360),
            statusScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])
    }

    private func labeledRow(_ label: String, _ field: NSTextField) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let row = NSStackView(views: [labelField, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    @objc private func chooseExe() {
        let panel = NSOpenPanel()
        panel.title = "選擇 Windows EXE"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            exePathField.stringValue = url.path
        }
    }

    @objc private func launchExe() {
        let wine = URL(fileURLWithPath: winePathField.stringValue)
        let prefix = URL(fileURLWithPath: prefixPathField.stringValue, isDirectory: true)
        let exe = URL(fileURLWithPath: exePathField.stringValue)

        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            appendStatus("Wine 不存在或不可執行：\n\(wine.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: exe.path),
              exe.pathExtension.lowercased() == "exe" else {
            appendStatus("請先選擇有效的 .exe 檔案。")
            return
        }
        guard FileManager.default.fileExists(atPath: prefix.path) else {
            appendStatus("WINEPREFIX 不存在：\n\(prefix.path)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", wine.path, exe.path]
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.environment = makeWineEnvironment(wine: wine, prefix: prefix)

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder/Logs/pid-test-launch.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            let header = "\narch -x86_64 \(wine.path) \(exe.path)\n"
            try? handle.write(contentsOf: header.data(using: .utf8) ?? Data())
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            appendStatus("Wine 啟動失敗：\n\(error.localizedDescription)")
            return
        }

        let pid = process.processIdentifier
        wrapperPIDField.stringValue = String(pid)
        pidField.stringValue = String(pid)
        processes[pid] = process
        if let handle = process.standardOutput as? FileHandle {
            logHandles[pid] = handle
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes.removeValue(forKey: pid)
                try? self.logHandles.removeValue(forKey: pid)?.close()
                self.appendStatus("Wrapper PID \(pid) 已結束，exit=\(process.terminationStatus)。")
            }
        }

        appendStatus(
            "已啟動 \(exe.lastPathComponent)。\n"
                + "Process 回傳的 wrapper PID：\(pid)\n"
                + "等待 WineAppWillActivateNotification…"
        )
    }

    @objc private func activatePIDNormally() {
        activateEnteredPID(cooperative: false, origin: "手動普通 activate")
    }

    @objc private func activatePIDCooperatively() {
        activateEnteredPID(cooperative: true, origin: "手動 cooperative activation")
    }

    private func activateEnteredPID(cooperative: Bool, origin: String) {
        let text = pidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(text), pid > 0 else {
            appendStatus("PID 格式無效：\(text)")
            return
        }
        activateApplication(pid: pid, cooperative: cooperative, origin: origin)
    }

    private func activateApplication(pid: Int32, cooperative: Bool, origin: String) {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            appendStatus(
                "\(origin)：PID \(pid) 無法轉成 NSRunningApplication。"
                    + "它可能不是 macOS application process，或已經結束。"
            )
            return
        }
        let beforePID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let result: Bool
        if cooperative, #available(macOS 14.0, *) {
            let source = NSRunningApplication.current
            NSApp.yieldActivation(to: application)
            result = application.activate(
                from: source,
                options: [.activateAllWindows, .activateIgnoringOtherApps]
            )
        } else {
            result = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        let name = application.localizedName ?? "（無名稱）"
        let executable = application.executableURL?.path ?? "（無 executableURL）"
        appendStatus(
            "\(origin) 已送出。\n"
                + "PID：\(pid)，policy：\(activationPolicyName(application.activationPolicy))\n"
                + "名稱：\(name)\n路徑：\(executable)\n"
                + "activate 回傳：\(result)，送出前 frontmost PID：\(beforePID)"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak application] in
            guard let self, let application else { return }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            self.appendStatus(
                "\(origin) 300ms 後：target=\(pid)，isActive=\(application.isActive)，"
                    + "frontmost PID=\(frontPID)"
            )
        }
    }

    @objc private func wineAppWillActivate(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        let number = userInfo["ActivatingAppPID"] as? NSNumber
        let prefix = userInfo["ActivatingAppPrefix"] as? String ?? ""
        let configDir = userInfo["ActivatingAppConfigDir"] as? String ?? ""
        let pid = number?.int32Value ?? 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let expectedPrefix = (self.prefixPathField.stringValue as NSString).standardizingPath
            let receivedPrefix = (prefix as NSString).standardizingPath
            let prefixMatches = !prefix.isEmpty && receivedPrefix == expectedPrefix
            let application = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            let policy = application.map { self.activationPolicyName($0.activationPolicy) } ?? "尚未註冊"

            self.appendStatus(
                "收到 WineAppWillActivateNotification。\n"
                    + "ActivatingAppPID：\(pid)，policy：\(policy)\n"
                    + "ActivatingAppPrefix：\(prefix.isEmpty ? "（空）" : prefix)\n"
                    + "ActivatingAppConfigDir：\(configDir.isEmpty ? "（空）" : configDir)\n"
                    + "與目前 WINEPREFIX 相符：\(prefixMatches)"
            )

            guard pid > 0, prefixMatches else { return }
            self.pidField.stringValue = String(pid)
            guard application?.activationPolicy == .regular else {
                self.appendStatus("自動 activation 已略過：通知 PID 目前不是 regular/Foreground App。")
                return
            }
            if self.autoCooperateCheckbox.state == .on {
                self.activateApplication(
                    pid: pid,
                    cooperative: true,
                    origin: "Wine 通知自動 cooperative activation"
                )
            }
        }
    }

    private func activationPolicyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular/Foreground"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited/BackgroundOnly"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }

    private func appendStatus(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] \(message)\n\n"
        statusTextView.textStorage?.append(NSAttributedString(string: entry))
        statusTextView.scrollToEndOfDocument(nil)
    }

    private func makeWineEnvironment(wine: URL, prefix: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let engineBin = wine.deletingLastPathComponent()
        environment["WINEPREFIX"] = prefix.path
        environment["WINESERVER"] = engineBin.appendingPathComponent("wineserver").path
        environment["PATH"] = engineBin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cyder/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if settings["msync"] as? Bool == true {
                environment["WINEMSYNC"] = "1"
            } else {
                environment.removeValue(forKey: "WINEMSYNC")
            }
            if settings["disableMshtml"] as? Bool == true {
                let existing = environment["WINEDLLOVERRIDES"] ?? ""
                environment["WINEDLLOVERRIDES"] = existing.isEmpty ? "mshtml=" : "mshtml=;\(existing)"
            }
        }
        return environment
    }
}

let app = NSApplication.shared
private let delegate = PIDTestAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
