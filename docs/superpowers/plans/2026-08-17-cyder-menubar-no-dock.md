# Cyder 永不進 Dock、啟動即掛選單列

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 外部 `open` 或雙擊 Cyder 時 Dock 完全不出現 Cyder；進程一活著就掛選單列醒酒瓶，讓使用者立刻知道有在跑。

**Architecture:** `Info.plist` 設 `LSUIElement`，Swift 全程 `NSApplication.ActivationPolicy.accessory`，不再升成 `.regular`。啟動路徑（URI／EXE／設定）在決定模式後立刻 `installStatusItem`；Wine PID 之後再 `beginMonitoring` 接上 session。

**Tech Stack:** AppKit `NSStatusItem`、`NSApplication.ActivationPolicy`、Launch Services `LSUIElement`。

## Global Constraints

- 平台：macOS 11+ native `CyderSwift`（Catalina 仍走 shell launcher，不改選單列）。
- 不改 Wine 啟動、URI 參數語意、instance 轉送契約。
- 偏好設定／遊戲庫／alert 視窗仍可出現；只是不再因此把 Cyder 放進 Dock。
- 選單列仍是單一 primary icon；secondary `open -n` instance 不另建 icon。
- 不新增依賴。

---

## 鎖定行為

| 情境 | Dock | 選單列 | 視窗 |
|------|------|--------|------|
| `open gamaniagames://…` 冷啟動 | 永不出現 | 立刻 starting，Wine PID 後接 session | 「正在啟動程式…」浮動面板 |
| `open … MapleStory.exe --args` | 永不出現 | 同上 | 同上 |
| 遊戲庫／常駐後再啟動 | 永不出現 | 既有 icon 切 starting | 同上 |
| 雙擊 Cyder.app | 永不出現 | 立刻出現 | 偏好設定或遊戲庫（環境檢查面板，不是啟動程式） |
| 錯誤／確認 dialog | 永不出現 | 維持 | alert 置前 |
| Wine／遊戲 | 可出現遊戲自己的 icon | Cyder 醒酒瓶 | 遊戲視窗 |

**Cmd-Tab 也不會有 Cyder**（`LSUIElement` + accessory 的正常結果）。入口改為選單列。

`applicationDockMenu` 在沒有 Dock icon 後無法從 Dock 打開；保留程式即可，不必刪。設定入口改以選單列「設定…」為主。

## 檔案

| 檔案 | 責任 |
|------|------|
| `scripts/create-cyder-app.sh` | Info.plist `LSUIElement` |
| `scripts/cyder_launch_support.swift` | `activateCyderUI` 不再升 Dock |
| `scripts/cyder_status_item.swift` | `markLaunchStarted()`：無 PID 也可掛 starting icon |
| `scripts/cyder_app_main.swift` | 全程 accessory；URI／EXE／設定路徑立刻掛選單列 |
| `tests/test-cyder-status-item.sh` | 契約：LSUIElement、markLaunchStarted、不升 regular |
| `tests/test-cyder-app-payload.sh` | plist 宣告 LSUIElement |
| `tests/test-cyder-open-files-lifecycle.sh` | 啟動路徑立刻掛選單列 |
| `docs/cyder.md` | 更新 Dock／選單列說明 |

## 實作要點

### 1. 從根上禁止 Dock

`create-cyder-app.sh` 的 Info.plist 加入：

```xml
<key>LSUIElement</key>
<true/>
```

`CyderMain.main()` 改為：

```swift
app.setActivationPolicy(.accessory)
```

不要先 `.regular` 再切回。`applicationWillFinishLaunching` 維持 accessory 即可。

`activateCyderUI` 改成永遠 accessory，只負責把視窗叫到前面：

```swift
func activateCyderUI(dockVisible: Bool) {
    NSApp.setActivationPolicy(.accessory)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    NSApp.activate(ignoringOtherApps: true)
}
```

暫時保留 `dockVisible` 參數以免一次改完所有呼叫點；呼叫端可之後再刪。**禁止**再出現 `setActivationPolicy(.regular)`（`cyder_pid_test_launcher.swift` 除外）。

### 2. 無 PID 也能掛選單列

在 `CyderStatusItemController` 新增：

```swift
func markLaunchStarted() {
    precondition(Thread.isMainThread)
    visualState = .starting
    installStatusItemIfNeeded()
    refresh()
}
```

`beginMonitoring` 行為不變：有 PID 後寫入 `sessions` 並開始 poll。若先前已 `markLaunchStarted()`，icon 已在，只是補上 session。

啟動失敗且沒有 session、也沒有設定／遊戲庫視窗時，既有 `removeStatusItemIfUnused()` 仍可拿掉 icon（或隨 `NSApp.terminate` 一起結束）。

### 3. 何時呼叫 `markLaunchStarted()`

Primary instance only：

- `enqueueOrLaunchURIs(_:)`：設完 `documentLaunchRequested` 後立刻呼叫。
- `deliverExecutableFiles`：primary 且即將啟動（非只轉送 secondary）時立刻呼叫。
- `runLauncherIfReady()`：進入 EXE 啟動背景工作前呼叫（雙保險）。
- `prepareEnvironmentAndShowSettings()`：設定模式開始時呼叫（或 `setUIVisible(true)`，效果相同）。
- `showSettings`／`showGameLibrary`：已有 `setUIVisible(true)`，維持。

Secondary instance：**不要** `markLaunchStarted()`，避免閃第二個 icon；轉送後結束。

### 4. 文件與測試

- `docs/cyder.md`：刪除「EXE 模式 Dock 顯示 Cyder／再消失」類敘述；改為「Cyder 為選單列常駐，不出現在 Dock；遊戲本身仍可有 Dock icon」。
- `tests/test-cyder-app-payload.sh`：assert Info.plist 產生腳本含 `LSUIElement`。
- `tests/test-cyder-status-item.sh`：assert `markLaunchStarted`、`LSUIElement`；assert `cyder_app_main.swift` / `cyder_launch_support.swift` **沒有** `setActivationPolicy(.regular)`。
- `tests/test-cyder-open-files-lifecycle.sh`：assert `enqueueOrLaunchURIs` 與 `deliverExecutableFiles` 會 `markLaunchStarted`。

現有 `assert_contains ... NSApp.setActivationPolicy(.accessory)` 仍應通過。

## 驗證

自動化：

```bash
bash tests/test-cyder-status-item.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-open-files-lifecycle.sh
bash tests/test-cyder-url-handler.sh
```

手動（實機）：

1. 結束所有 Cyder 後 `open 'gamaniagames://…'`：Dock 無 Cyder；選單列立刻有醒酒瓶；顯示「正在啟動程式…」；之後遊戲視窗出現並關閉該面板。
2. `open -n -b local.cyder.app "/path/MapleStory.exe" --args …`：同上。
3. 雙擊 `Cyder.app`：Dock 無 Cyder；選單列 + 偏好設定／遊戲庫。
4. 錯誤路徑（無效 URI／找不到 GGM）：選單列仍在，alert 置前，不進 Dock。

## 不做

- 不改 Wine／GGM argv。
- 不實作 LaunchGroup process monitor。
- 不刪 `applicationDockMenu`（死碼可留）。
