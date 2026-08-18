# LaunchGroup 選單列唯一真相 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓選單列與 Cyder 進程壽命只跟 LaunchGroup（Unix PID 事件 + 視窗／Dock 認領）走，不再把 sentinel fifo／helper 斷線或「同 prefix 已有 session」當成遊戲結束。

**Architecture:** `runWineThroughLauncher` 已有的 `launchID` 在啟動當下建立 LaunchGroup。pid 檔用同一個 id 附加根 PID 並 kqueue。`WineAppWillActivateNotification`／`NSWorkspace` 依 spec §3.3 認領，禁止 prefix 掃窗。Helper socket 只做 primary 選舉；`onLaunchEnded` 不得 `endLaunch`。

**Tech Stack:** AppKit `NSStatusItem`、`DispatchSource.makeProcessSource`、既有 Unix sentinel socket、bash 契約測試（`tests/assert.sh`）。

## Global Constraints

- 平台：macOS 11+ native `CyderSwift`；不改 Catalina shell-only 路徑。
- 不進 `cyder-wine-engine` 做 `--wait-children`。
- 不新增依賴；不把 Cyder 升成 Dock（禁止 `setActivationPolicy(.regular)`）。
- 選單文案鎖定：`正在啟動`／`執行中`／`等待 {名} 退出`／`已結束，等待背景程序退出`／`正在結束 Windows 程序`。
- 契約測試風格：改 `tests/test-cyder-*.sh` 的 `assert_contains`／`assert_not_contains`，先紅再綠。
- Commit 用 Conventional Commits；**僅在使用者要求 commit 時執行 git commit**（使用者規則優先於本計畫的 commit 步驟）。
- 實作後跑：`bash tests/test-cyder-sentinel.sh`、`bash tests/test-cyder-status-item.sh`、`bash tests/test-cyder-open-files-lifecycle.sh`、`bash tests/test-cyder-instance.sh`，以及 spec 列出的 `swiftc -typecheck` 來源清單。

## File map

| 檔案 | 責任 |
|------|------|
| `tests/test-cyder-sentinel.sh` | LaunchGroup 契約：組由 Swift id 建立、helper ended ≠ endLaunch、附加 PID 用 id |
| `tests/test-cyder-status-item.sh` | 關視窗不 terminate；`attachRootPID(id:)` |
| `tests/test-cyder-open-files-lifecycle.sh` | 啟動等待不掃窗（多半已過） |
| `scripts/cyder_status_item.swift` | Session = LaunchGroup；`attachRootPID`；認領 §3.3 |
| `scripts/cyder_app_main.swift` | 啟動當下 `beginLaunch(id: launchID)`；pid 用同一 id；忽略 helper 結束；認領呼叫新 API |
| `scripts/cyder_sentinel.swift` | 不斷線清組（app 端改接線即可；helper 可維持現狀） |
| `docs/cyder.md` | fifo／helper 不再代表 launch 結束 |

不改：`scripts/cyder-common.sh` 的 fifo 實作（本版承認它不是 UI 壽命）、選單列繪圖、引擎 repo。

---

### Task 1: 寫入會失敗的 LaunchGroup 契約測試

**Files:**
- Modify: `tests/test-cyder-sentinel.sh`
- Modify: `tests/test-cyder-status-item.sh`
- Test: 同上（本 repo 契約測試即測試檔）

**Interfaces:**
- Consumes: 現有 `assert.sh`、`beginLaunch(id:prefix:executableName:pid:)`
- Produces: 後續任務必須滿足的字串契約（見步驟 1 的 assert）

- [ ] **Step 1: Write the failing test**

在 `tests/test-cyder-sentinel.sh` 的 `echo "PASS test-cyder-sentinel"` **之前**追加：

```bash
assert_contains "$app" 'statusItemController.beginLaunch(' \
  "Swift must create the LaunchGroup when the Wine relay starts, not wait for helper hello"
assert_contains "$app" 'attachRootPID(id: launchID' \
  "the pid file must attach to this launch id, not to whichever group shares the prefix"
assert_not_contains "$app" 'sentinel.onLaunchEnded = { [weak self] id in
                self?.statusItemController.endLaunch(id: id)' \
  "helper disconnect must not endLaunch"
assert_not_contains "$app" 'self?.statusItemController.endLaunch(id: id)' \
  "onLaunchEnded must not call endLaunch"
assert_contains "$status" 'func attachRootPID(id: String, pid: Int32)' \
  "root PID attach is keyed by launch id"
assert_contains "$status" 'exactlyOneStartingGroup' \
  "window adoption must prefer the single starting group, not every group with the same prefix"
assert_not_contains "$status" 'for (key, var session) in sessions where session.prefix.path == target' \
  "adoptWindowedProcess must not dump a PID into every LaunchGroup that shares the bottle"
```

把現有這兩條改成符合 spec（hello 不再建立組）：

```bash
assert_contains "$status" 'func beginLaunch(' \
  "the menu bar must track launches as LaunchGroups with a stable id"
assert_not_contains "$app" 'sentinel.onLaunch = { [weak self] launch in
                self?.statusItemController.beginLaunch(' \
  "helper hello must not create a second LaunchGroup"
```

在 `tests/test-cyder-status-item.sh` 追加（`PASS` 之前）：

```bash
assert_contains "$app_source" 'attachRootPID(id: launchID' \
  "library and Finder launches must attach the pid file to the LaunchGroup created for that relay"
assert_contains "$status_source" 'func attachRootPID(id: String, pid: Int32)' \
  "status item must expose id-keyed root PID attach"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/test-cyder-sentinel.sh
```

Expected: `ASSERT_CONTAINS failed` 或 `ASSERT_NOT_CONTAINS failed`，且訊息提到 `attachRootPID` 或 `beginLaunch`／`endLaunch`／`exactlyOneStartingGroup` 其中之一。不得 `PASS test-cyder-sentinel`。

- [ ] **Step 3: Do not implement production code in this task**

本 task 只改測試。

- [ ] **Step 4: Confirm status-item test also fails**

Run:

```bash
bash tests/test-cyder-status-item.sh
```

Expected: FAIL，missing `attachRootPID(id: launchID`。

- [ ] **Step 5: Commit**

僅在使用者要求時：

```bash
git add tests/test-cyder-sentinel.sh tests/test-cyder-status-item.sh
git commit -m "$(cat <<'EOF'
test(app): lock LaunchGroup menu-bar lifetime contracts

EOF
)"
```

---

### Task 2: Status item 用 launch id 附加根 PID，認領改 §3.3

**Files:**
- Modify: `scripts/cyder_status_item.swift`
- Test: `tests/test-cyder-sentinel.sh`、`tests/test-cyder-status-item.sh`

**Interfaces:**
- Consumes: 現有 `beginLaunch(id:prefix:executableName:pid:)`、`watchPID(_:)`、`applyWindowedHandoff`
- Produces:
  - `func attachRootPID(id: String, pid: Int32)`
  - `func adoptWindowedProcess(pid: Int32, prefix: String, name: String?)` 改為 §3.3（內部用 `exactlyOneStartingGroup`）
  - `beginMonitoring` 改為若沒有 matching **id** 才建立 fallback 組；**禁止**用 prefix 找到「隨便一組」就 return

- [ ] **Step 1: Replace prefix-keyed attach with id-keyed attach**

刪除 `attachPublishedPID(_ pid:prefix:)`。新增：

```swift
func attachRootPID(id: String, pid: Int32) {
    precondition(Thread.isMainThread)
    guard pid > 0, var session = sessions[id] else { return }
    session.pid = pid
    session.adoptedPIDs.insert(pid)
    sessions[id] = session
    watchPID(pid)
    refresh()
}
```

`beginMonitoring(pid:prefix:executablePath:lifecycleURL:)` 改為：**不要** `attachPublishedPID(pid, prefix:)`。若呼叫端已改走 `attachRootPID`，此函式只保留「沒有 LaunchGroup 時的 fallback」（id = `"pid:\(pid)"` 建一組）。本版 app 主路徑不再依賴它附加到同 prefix 的另一場遊戲。

- [ ] **Step 2: Change adoptWindowedProcess to spec §3.3**

取代「所有 `session.prefix.path == target` 都 insert」的迴圈。必須出現識別字 `exactlyOneStartingGroup`：

```swift
func adoptWindowedProcess(pid: Int32, prefix: String, name: String?) {
    precondition(Thread.isMainThread)
    guard pid > 0 else { return }
    let target = (prefix as NSString).standardizingPath
    let key: String?
    if let existing = sessions.first(where: { $0.value.adoptedPIDs.contains(pid) })?.key {
        key = existing
    } else {
        let starting = sessions.filter {
            $0.value.prefix.path == target && !$0.value.activated && !$0.value.hasForeground
        }
        let exactlyOneStartingGroup = starting.count == 1
        if exactlyOneStartingGroup {
            key = starting.first?.key
        } else if let treeOwner = sessions.first(where: { session in
            session.value.prefix.path == target
                && session.value.adoptedPIDs.contains(where: { wineProcessTreeIDs(root: $0).contains(pid) })
        })?.key {
            key = treeOwner
        } else {
            key = nil
        }
    }
    guard let key, var session = sessions[key] else { return }
    session.adoptedPIDs.insert(pid)
    session.foregroundPIDs.insert(pid)
    applyWindowedHandoff(&session, preferredName: name)
    sessions[key] = session
    watchPID(pid)
    refresh()
}
```

`wineProcessTreeIDs` 已在 `scripts/cyder_launch_support.swift`。樹檢查可在呼叫端的 utility queue 做；若留在 main，只允許這一次事件、禁止做成 Timer。本 task 為最小實作可先在 main 做一次；不得加回 `.common` poll。

- [ ] **Step 3: Run tests — Task 1 的 status 字串應開始變綠，app 字串仍紅**

Run:

```bash
bash tests/test-cyder-sentinel.sh
```

Expected: 與 `func attachRootPID`、`exactlyOneStartingGroup`、`for (key, var session) in sessions where session.prefix.path == target` 相關的 assert 通過；與 `attachRootPID(id: launchID`、`sentinel.onLaunch` 相關的仍失敗。

- [ ] **Step 4: Commit**

僅在使用者要求時：`fix(app): adopt Wine windows into one LaunchGroup by id`

---

### Task 3: App 在 relay 開始時建立組，pid 用同一 id，helper 不斷組

**Files:**
- Modify: `scripts/cyder_app_main.swift`
- Test: `tests/test-cyder-sentinel.sh`、`tests/test-cyder-status-item.sh`、`tests/test-cyder-open-files-lifecycle.sh`

**Interfaces:**
- Consumes: `beginLaunch(id:prefix:executableName:pid:)`、`attachRootPID(id:pid:)`、既有 `launchID`（`runWineThroughLauncher` 內 `UUID().uuidString`）
- Produces: helper hello 不再 `beginLaunch`；`onLaunchEnded` 只 `noteHelperDisconnected`（該函式不得在 `starting` 或仍有 live PID 時 `endLaunch`）

- [ ] **Step 1: Create the group when the relay starts**

在 `runWineThroughLauncher` 裡，`let launchID = UUID().uuidString` **之後**、`runLauncher(...)` **之前**：

```swift
let executableName = URL(fileURLWithPath: exe).deletingPathExtension().lastPathComponent
onMainThread {
    statusItemController.beginLaunch(
        id: launchID,
        prefix: prefix,
        executableName: executableName,
        pid: 0
    )
}
```

`presentExternalLaunchStarting()` 維持 `markLaunchStarted()`（EXE 尚未解析時先掛 icon）。

- [ ] **Step 2: Attach pid file by launchID**

把

```swift
statusItemController.beginMonitoring(
    pid: winePID,
    prefix: prefix,
    executablePath: exe,
    lifecycleURL: lifecycleURL
)
```

換成：

```swift
statusItemController.attachRootPID(id: launchID, pid: winePID)
```

URI `beginWineSession` 區塊保留。`monitoringStarted = true` 仍可在 `winePID > 0` 時設定。失敗 `defer` 的 `cancelMonitoring(pid: winePID)` 改為只在該 `launchID` 仍無前景時結束該組：若已有 `attachRootPID`／認領，啟動失敗才 `endLaunch(id: launchID)`。最小實作：`defer` 在 `!launchActivated` 時 `onMainThread { statusItemController.endLaunch(id: launchID) }`（取代 `cancelMonitoring(pid:)`），這樣失敗啟動不會留下空組。

- [ ] **Step 3: Stop helper hello from creating a second group**

刪除或停用：

```swift
instanceCoordinator.sentinel.onLaunch = { [weak self] launch in
    self?.statusItemController.beginLaunch(...)
}
```

改為忽略 hello，或只 `attachRootPID` 若 `sessions[launch.id]` 已存在（helper 的 id **不是** `launchID`，因此 **不要**用 helper id 當鍵）。本版 `onLaunch` 設為 `{ _ in }` 或刪除賦值。

`onLaunchUpdate`：可用 helper 的 pid 當提示，但沒有 Swift `launchID` 對應時 **不要** `beginLaunch`。最小：刪除 `onLaunch`／`onLaunchUpdate` 賦值，只留：

```swift
instanceCoordinator.sentinel.onLaunchEnded = { [weak self] id in
    self?.statusItemController.noteHelperDisconnected(id: id)
}
```

`noteHelperDisconnected`：若 `sessions[id]` 不存在（因為組是 Swift `launchID`），直接 return。**禁止**改回 `endLaunch`。

確認 `noteHelperDisconnected` 在找不到 id 時 no-op；在找得到且無 live PID、且 `!starting`（已 activated 且 watched 空）才 `endLaunch`。Swift 建的組 id ≠ helper id，因此 helper 斷線預設 no-op。這正是 spec：「斷線只記 log」。

可在 `noteHelperDisconnected` 開頭加 `CyderDiagnostics.shared.info("sentinel helper disconnected id=\(id)")`（可選）。

- [ ] **Step 4: Keep close-window guards**

維持：

```swift
if self.statusItemController.hasActiveSessions || self.libraryLaunchInProgress {
    NSApp.setActivationPolicy(.accessory)
    return
}
```

`beginLaunch` 在 relay 開始就發生後，關遊戲庫時 `hasActiveSessions` 應為 true，即使 `libraryLaunchInProgress` 已 false。

- [ ] **Step 5: Run tests**

```bash
bash tests/test-cyder-sentinel.sh
bash tests/test-cyder-status-item.sh
bash tests/test-cyder-open-files-lifecycle.sh
bash tests/test-cyder-instance.sh
```

Expected: 全部 `PASS`。

- [ ] **Step 6: Commit**

僅在使用者要求時：`fix(app): create LaunchGroup at Wine relay start`

---

### Task 4: 文件對齊 + typecheck

**Files:**
- Modify: `docs/cyder.md`（約 instance／sentinel 那段）
- Modify: `docs/superpowers/specs/2026-08-19-launchgroup-menu-bar-design.md` 僅在實作與 spec 有意偏離時（預設不改 spec）

**Interfaces:**
- Consumes: 已合併的 LaunchGroup 行為
- Produces: `docs/cyder.md` 不再寫「fifo EOF 代表 launch 結束」或「helper hello 建立選單列 session」

- [ ] **Step 1: Update docs/cyder.md**

把「每次 Wine launch 另開一根可繼承 fifo…連線斷開只表示 helper 已結束…」整段改成與 spec 一致，至少含：

```markdown
每次由 Cyder 啟動的 EXE 在 primary 建立一個 LaunchGroup（穩定 id）。
選單列與 Cyder 進程是否還在，只問「設定／遊戲庫是否開著」或「是否還有未結束的 LaunchGroup」。
根 Unix PID 來自 `CYDER_WINE_PID_FILE` 並用 process-exit／fork 事件監看；後來的視窗 PID
由 Wine／Dock 啟動通知認領，且同一 bottle 兩場啟動不得用 prefix 掃窗互搶。
`--sentinel-connect` fifo 仍可存在，但 EOF／helper 斷線不代表遊戲結束。
`wineserver -w` 只用於 supervisor 的 bottle 排空，不決定選單列。
```

- [ ] **Step 2: Typecheck CyderSwift sources**

Run（檔名順序與 `scripts/create-cyder-app.sh` 的 `SWIFT_SOURCES` 相同）：

```bash
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CACHE="$(mktemp -d)"
swiftc -typecheck -sdk "$SDK" -module-cache-path "$CACHE" -target arm64-apple-macosx11.0 \
  scripts/cyder_diagnostics.swift \
  scripts/cyder_paths.swift \
  scripts/cyder_sentinel.swift \
  scripts/cyder_instance.swift \
  scripts/cyder_uri_handler.swift \
  scripts/cyder_gptk.swift \
  scripts/cyder_settings.swift \
  scripts/cyder_launch_support.swift \
  scripts/cyder_status_item.swift \
  scripts/cyder_profiles.swift \
  scripts/cyder_settings_ui.swift \
  scripts/cyder_game_library.swift \
  scripts/cyder_bottle_shortcuts.swift \
  scripts/cyder_game_icon.swift \
  scripts/cyder_game_library_ui.swift \
  scripts/cyder_app_main.swift
STATUS=$?
rm -rf "$CACHE"
exit $STATUS
```

Expected: exit 0。

- [ ] **Step 3: Re-run contract tests**

```bash
bash tests/test-cyder-sentinel.sh
bash tests/test-cyder-status-item.sh
bash tests/test-cyder-open-files-lifecycle.sh
bash tests/test-cyder-app-payload.sh
```

Expected: 全部 PASS。

- [ ] **Step 4: Manual test build（可另開一步）**

```bash
bash scripts/release-cyder.sh --channel test
```

Expected: `==> Test build ready: /Users/jjc/ogom/dist/Cyder.app`

手動：雙擊 Cyder → 遊戲庫開遊戲 → 關遊戲庫 → icon 仍在；同 bottle 第二個遊戲兩行；點選單不轉圈。

- [ ] **Step 5: Commit**

僅在使用者要求時：`docs: describe LaunchGroup menu-bar lifetime`

---

## Self-review

| Spec | Task |
|------|------|
| §1 LaunchGroup 用 id、pid 檔附加 | Task 2–3 |
| §2 關庫留 icon；無組才 terminate | Task 3 step 4（既有 guard）+ Task 1 既有 `hasActiveSessions \|\| libraryLaunchInProgress` |
| §3.1 啟動當下建組、禁止 prefix 當附加鍵 | Task 3 step 1–2 |
| §3.2 kqueue（現有 `watchPID`） | Task 2 附加後 `watchPID`；不重寫 watcher |
| §3.3 認領四步 | Task 2 `exactlyOneStartingGroup` |
| §4 helper 不斷組 | Task 3 step 3 |
| §5 文案 | 不改繪圖／字串（已鎖定） |
| §6 docs | Task 4 |
| §7 測試清單 | Task 1 + 3 step 5 + 4 step 3 |
| 非目標：引擎 B／Wine 內 C | 無對應 task（刻意） |
