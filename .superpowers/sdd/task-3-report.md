# Task 3 Report: App 在 relay 開始時建立組，pid 用同一 id，helper 不斷組

## Status

**DONE**

## Summary

`runWineThroughLauncher` 在 `launchID` 產生後、`runLauncher` 之前以 Swift id `beginLaunch(..., pid: 0)` 建立 LaunchGroup；pid 檔以同一個 id `attachRootPID`。Helper hello / update 不再建組；`onLaunchEnded` 只 `noteHelperDisconnected`（找不到 id 則 no-op）。失敗啟動 `defer` 改 `endLaunch(id: launchID)`。關窗仍用 `hasActiveSessions || libraryLaunchInProgress`。

## TDD Evidence

### RED

先改測試（刪除過期 `attachPublishedPID` assert，並加上 `endLaunch(id: launchID)` / 不得 `cancelMonitoring(pid: winePID` / Swift 組 `helperConnected: false`），再跑既有 Task 1 契約：

```
bash tests/test-cyder-sentinel.sh
ASSERT_NOT_CONTAINS failed: helper hello must not create a second LaunchGroup
  unexpected: sentinel.onLaunch = { [weak self] launch in
                self?.statusItemController.beginLaunch(

bash tests/test-cyder-status-item.sh
ASSERT_CONTAINS failed: library and Finder launches must attach the pid file to the LaunchGroup created for that relay
  missing: attachRootPID(id: launchID
```

失敗原因符合缺 production 接線（helper 仍 `beginLaunch`、尚未 `attachRootPID(id: launchID)`），不是 typo。

### GREEN

實作後：

```
bash tests/test-cyder-sentinel.sh              # PASS
bash tests/test-cyder-status-item.sh           # PASS
bash tests/test-cyder-open-files-lifecycle.sh  # PASS
bash tests/test-cyder-instance.sh              # PASS
```

## Changes

### `scripts/cyder_app_main.swift`

1. **Step 1** — `let launchID = UUID().uuidString` 之後、`runLauncher` 之前：`beginLaunch(id: launchID, prefix:, executableName:, pid: 0)`。`presentExternalLaunchStarting()` 仍 `markLaunchStarted()`。
2. **Step 2** — `beginMonitoring(...)` 換成 `attachRootPID(id: launchID, pid: winePID)`；URI `beginWineSession` 保留。`!launchActivated` 的 `defer` 改 `endLaunch(id: launchID)`，取代 `cancelMonitoring(pid:)`。
3. **Step 3** — 刪除 `sentinel.onLaunch` / `onLaunchUpdate` 賦值；只留 `onLaunchEnded` → `noteHelperDisconnected`。
4. **Step 4** — 關窗守衛維持 `hasActiveSessions || self.libraryLaunchInProgress`。
5. 一併帶入工作區既有的 NSWorkspace 啟動／結束通知（取代 waiter 內 CGWindowList / Dock 掃描），與 lifecycle 測試對齊。

### `scripts/cyder_status_item.swift`（Task 2 review + 組壽命）

- `beginLaunch` 的 `helperConnected` 改 `false`：組由 Swift 建立，helper id ≠ `launchID`，不可再等 helper 斷線才 `endLaunch`。
- `updateLaunch` 在 pid attach 後 `refresh()`。
- `noteHelperDisconnected`：缺 id 仍 no-op；開頭 log `sentinel helper disconnected id=`；`!activated && !hasForeground`（starting）不 `endLaunch`。

### `scripts/cyder_sentinel.swift`

Helper 改 kqueue（fifo `makeReadSource`、不再 `usleep(400_000)` / `currentHolders`），讓 `test-cyder-sentinel` 的 helper 契約在此 commit 上為綠。App 端仍不依 helper hello 建組。

### Tests

- 刪除 `assert_contains attachPublishedPID`（與 Task 2 刪除該 API 對齊）。
- 新增失敗啟動 `endLaunch(id: launchID)`、不得 `cancelMonitoring(pid: winePID)`、Swift 組 `helperConnected: false`。
- `test-cyder-open-files-lifecycle.sh`：啟動等待改為不得掃窗，改認 `didActivateApplicationNotification`。

## Commit

```
c77fabc fix(app): create LaunchGroup at Wine relay start
```

Files: `scripts/cyder_app_main.swift`, `scripts/cyder_status_item.swift`, `scripts/cyder_sentinel.swift`, `tests/test-cyder-sentinel.sh`, `tests/test-cyder-open-files-lifecycle.sh`.

未納入：`docs/cyder.md`（Task 4）、retire-cx25 / logo 文件、`.superpowers/sdd/task-2-report.md`。

## Self-Review

| Check | Result |
|-------|--------|
| relay 開始 `beginLaunch(id: launchID, pid: 0)` | ✓ |
| pid 檔 `attachRootPID(id: launchID)` | ✓ |
| helper hello 不再 `beginLaunch` | ✓ |
| `onLaunchEnded` 只 `noteHelperDisconnected`，禁止 `endLaunch` | ✓ |
| 失敗 `defer` `endLaunch(id: launchID)` | ✓ |
| 關窗 `hasActiveSessions \|\| libraryLaunchInProgress` | ✓ |
| 四支 brief 測試 PASS | ✓ |
| Conventional Commits subject | ✓ |

## Concerns

- `updateLaunch` 在 app 端已無呼叫者（`onLaunchUpdate` 已刪）；保留 API 以免 helper 日後對上同一 id，但目前為死碼。
- `beginLaunch` 仍設 `fromSentinel: true`（僅欄位名；`fromSentinel` 無其他讀取）。
- `beginMonitoring` 仍在 status item 作為 `pid:` fallback，app 主路徑已不再呼叫。
- 未跑 `swiftc -typecheck`（屬 Task 4）。
- `docs/cyder.md` 尚未對齊（Task 4）。

---

## Review fix: starting keep-alive after root PID exit

### Finding

**Critical:** `beginLaunch` 設 `helperConnected: false`。根 Unix PID 在視窗認領前退出時，`finishSessionIfIdle` 立刻 `endLaunch`。Spec 要求組在 relay 仍等 handoff（GGMWebStart → MapleStory）時維持 `starting`。

**Important:** `tests/test-cyder-sentinel.sh` 把 `helperConnected: false` 當成 keep-alive 契約，會擋住生產修正。

### Fix

`finishSessionIfIdle`：無 live PID 且 `!session.activated` 時 refresh/return，不 `endLaunch`。僅在無 live PID **且已 activated**（leftover 排空）時結束組。失敗啟動仍靠 `runWineThroughLauncher` 的 `defer { if !launchActivated { endLaunch(id: launchID) } }`，不依賴 `helperConnected`。

測試改鎖 starting keep-alive：`finishSessionIfIdle` 在 `!session.activated` 時不得 `endLaunch`。刪除強制 `helperConnected: false` 的 assert。

### TDD

#### RED

改測試後、改 production 前：

```
$ bash tests/test-cyder-sentinel.sh
ASSERT_CONTAINS failed: finishSessionIfIdle must not endLaunch while the LaunchGroup is still starting
  missing: if !session.activated {
            session.hasForeground = false
            session.leftoverNames = []
            sessions[id] = session
            refresh()
            return
        }
        endLaunch(id: id)
```

失敗原因是 production 仍用 `if session.helperConnected`，不是 typo。

#### GREEN

`finishSessionIfIdle` 改為 `if !session.activated { refresh(); return }` 後：

```
$ bash tests/test-cyder-sentinel.sh
PASS test-cyder-sentinel

$ bash tests/test-cyder-status-item.sh
PASS test-cyder-status-item

$ bash tests/test-cyder-open-files-lifecycle.sh
PASS test-cyder-open-files-lifecycle
```

三支均 PASS。

### Files

- `scripts/cyder_status_item.swift` — `finishSessionIfIdle` keep-alive 改看 `!session.activated`
- `tests/test-cyder-sentinel.sh` — 鎖 starting keep-alive，移除 `helperConnected: false` 契約

未改 `docs/cyder.md`、retire-cx25 檔。
