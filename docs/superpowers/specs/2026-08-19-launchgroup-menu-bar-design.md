# Cyder：LaunchGroup 為選單列唯一真相（方案 A）

日期：2026-08-19  
狀態：設計已核准（方案 A；先試 app 端，不做引擎 wait-children）  
範圍：Cyder app（`ogom`）選單列、啟動接力、sentinel helper 的**壽命語意**

相關：

- 本對話核准的方案 A（Unix PID kqueue + 視窗／Dock 認領）
- `docs/cyder.md`（選單列／sentinel 現況敘述；實作後需改成與本文件一致）
- `docs/cyder-session-process-monitoring.zh-TW.md`（LaunchGroup 名稱與「不要用 wineserver -w 當 UI」；Wine 內 monitor 不在本版）
- `docs/superpowers/plans/2026-08-17-cyder-menubar-no-dock.md`（永不進 Dock、立刻掛選單列）

## 目標

1. **一場使用者啟動 = 一個 LaunchGroup。** 選單列、Cyder 進程要不要退出，只問 LaunchGroup 與「設定／遊戲庫是否開著」，不問 fifo、helper socket、lifecycle sidecar、`wineserver -w`。
2. **按下啟動當下就有組。** 不靠 `--sentinel-connect` hello 才建立 session。pid 檔出現後立刻 kqueue；視窗／Dock 啟動事件把後來的 Unix PID 收進同一組。
3. **關掉遊戲庫或設定，只要還有未結束的 LaunchGroup，醒酒瓶必須留下。** 遊戲是 detach 的，關 Cyder 視窗不得當成遊戲結束。
4. **主執行緒不輪詢 `CGWindowList`、不在 menu tracking 跑 Wine 掃描。** 名稱與「有沒有視窗」來自事件。
5. **同一 prefix 兩場啟動互不等待。** `wineserver -w` 只留給 Bash supervisor 的 bottle 排空／session lock。

## 非目標

- 不在 `cyder-wine-engine` 實作 CrossOver `--wait-children`（方案 B）。
- 不在 Wine 內做 Windows PID／`tasklist` monitor（方案 C／8-12 文件）。
- 不改成常駐選單列 daemon：沒有視窗、也沒有 LaunchGroup 時，Cyder 仍結束。
- 不把 Cyder 放進 Dock（維持 `LSUIElement` + `.accessory`）。
- 不把 helper fifo 修成「真正可繼承到 Win32 小孩」；本版承認 bash fifo 不能當壽命。
- 不重做選單列視覺（醒酒瓶、文案列已鎖定，見 §5）。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 壽命真相 | LaunchGroup + 其 `watchedPIDs` 是否還活著 |
| 組何時建立 | `presentExternalLaunchStarting`／`runWineThroughLauncher` 開始時，在 primary 主執行緒 |
| 根 PID | Bash `CYDER_WINE_PID_FILE`；讀到就 `DispatchSource.makeProcessSource`（`.exit` `.fork` `.exec`） |
| 後來的遊戲 PID | `WineAppWillActivateNotification`、`NSWorkspace.didActivateApplicationNotification`／`didTerminateApplicationNotification` |
| 兩遊戲同 bottle | **禁止**用「掃所有視窗比 WINEPREFIX」把 PID 塞進某一組；見 §3.3 |
| Helper socket | 只保留 primary 選舉與 secondary 轉送；`onLaunchEnded` **不得**結束仍有活 PID 的組 |
| fifo | Bash 可暫留，但 UI 當它不存在；EOF ≠ 啟動結束 |
| `wineserver -w` | Supervisor 內部；選單列不讀 lifecycle `stopped` 來拿掉 icon |
| 關遊戲庫 | `setUIVisible(false)`；有 LaunchGroup 則留下 status item，不 `terminate` |

---

## §1 資料模型

Primary 只維護 `LaunchGroup` 陣列（可沿用現有 `CyderStatusItemController.Session`，但語意改成下表，且**建立點改到 Swift 啟動路徑**）。

| 欄位 | 意義 |
|------|------|
| `id` | 每次啟動唯一（UUID）。不是 prefix，不是根 EXE 路徑。 |
| `prefix` | 這次 `WINEPREFIX` |
| `rootDisplayName` | 使用者打開的 EXE 檔名（無副檔名），例如 `GGMWebStart` |
| `displayName` | 目前選單列要顯示的名稱；視窗／Dock 認領後可改成 `MapleStory` |
| `rootPID` | pid 檔上的 Unix PID；尚未出現則為 0 |
| `watchedPIDs` | 正在 kqueue 的 Unix PID（根 + fork 子樹 + 認領的視窗 PID） |
| `foregroundPIDs` | 目前視為「有視窗／Dock 前景」的 PID |
| `state` | `starting`／`running`／`leftover`／`stopping` |
| `leftoverNames` | 前景沒了之後仍活著的有用行程名（黑名單位：wineserver、preloader、wine、Cyder） |

結束條件（必須同時成立才 `remove` 該組）：

1. `rootPID != 0` 之後，所有 `watchedPIDs` 都已收到 `.exit` 或 `kill(pid,0) != 0`；**或**啟動失敗、根本沒有 pid 檔且 `runWineThroughLauncher` 已失敗返回。
2. 若 `rootPID == 0` 且啟動仍在進行（launcher 執行緒未返回），組必須保持 `starting`，即使 helper 已斷線。

Helper 斷線、fifo EOF、lifecycle `background`／`stopped`、`wineserver -w` 返回，都**不是**結束條件。

---

## §2 選單列與 Cyder 進程

醒酒瓶存在：

```text
settingsVisible ∨ libraryVisible ∨ !launchGroups.isEmpty
```

關掉設定或遊戲庫：

- 只把對應視窗關起來，並 `setUIVisible(false)`。
- 若 `launchGroups` 非空：留下 status item，維持 `.accessory`，**不** `NSApp.terminate`。
- 若為空且這次是「雙擊 Cyder 進設定／遊戲庫」路徑（`terminateWhenSettingsClose`）：可以結束 Cyder。

`onAllSessionsEnded`：僅當 `launchGroups` 已空，且兩個視窗都沒開，才 `terminate`。不得在「helper 斷線但 PID 還在」時觸發。

點選單：`menuNeedsUpdate` 只重建目前 `launchGroups` 快取字串。動畫 Timer 只加到 `RunLoop.Mode.default`。`menuWillOpen` 暫停動畫。禁止再把 Wine 掃描 Timer 加到 `.common`。

---

## §3 啟動與 PID 歸屬

### 3.1 建立組

遊戲庫、Finder EXE、URI、佇列中的下一場，凡進入 `runWineThroughLauncher` 或同等 `presentExternalLaunchStarting`，都在 **main** 建立 LaunchGroup（`starting`，名稱 = EXE 檔名）。同一場不得再靠 sentinel `beginLaunch` 建第二組。

`beginMonitoring(prefix)` 若已有該次啟動的組，只把 pid 檔的 PID **附加**進該組並開始 watch，禁止 `return` 掉。不得用「同 prefix 已有組」當成「這次 PID 可以忽略」——同 prefix 可能已有另一場遊戲；pid 檔屬於**這一場** launcher，應附加到**這一場**的 `id`，不是掃 prefix。

實作上：`runWineThroughLauncher` 建立組時就帶 `id`，pid 檔寫入後用同一個 `id` 附加 PID。不要再用 `isMonitoring(prefix:)` 當唯一鍵。

### 3.2 監看

對每個新進入 `watchedPIDs` 的 PID：`DispatchSource.makeProcessSource` `.exit` `.fork` `.exec`，queue 不得是 main。

- `.fork`／`.exec`：一次 `wineProcessTreeIDs(root:)` 把活著的小孩放進 `watchedPIDs` 並接著 watch。允許在**這個事件**上做一次 `wineOnscreenWindows(ownedBy: watchedPIDs)`（非 main），有視窗則當認領。禁止 `wineOnscreenWindows(matchingPrefix:)` 定時或在點選單時呼叫。
- `.exit`：移出 `watchedPIDs`／`foregroundPIDs`。若 `foregroundPIDs` 空了但還有 watched：`leftover`，名稱見 §5。若 watched 也空了：結束該組。

根 PID 若是短命 launcher，`.exit` 不得在 MapleStory 已被認領進 `watchedPIDs` 時結束整組。

### 3.3 視窗／Dock 認領（兩遊戲同 bottle）

收到 Wine 或 `NSWorkspace` 啟動、且 `isWineMacApplication`：

1. 若 PID 已在某一組的 `watchedPIDs`：只更新那一組為 `running`／前景名稱。
2. 否則若目前有**恰好一個** `starting` 組，其 `prefix` 與 `winePrefix(forProcess: pid)` 相同：收進該組。
3. 否則若某組的 `watchedPIDs` 子樹（一次 `wineProcessTreeIDs`）含此 PID：收進該組。
4. **否則不認領。** 不得「這個 prefix 有組就把 PID 塞進去」。

結束啟動面板（`hideSetup`）與 `WineActivationWaiter` 只在認領成功、或該 waiter 的 prefix 對上這次事件時觸發。不得在主執行緒 0.2s 輪詢 `wineProcessHasOnscreenWindow`／`wineHandoffOnscreenWindows`／`wineRegularAppsLaunched`。activation 等待執行緒只等 semaphore 與 pid／result 檔；30s 逾時且行程仍在則維持現況：視為已啟動、組改 `running`，不結束組。

---

## §4 Helper、fifo、Bash

| 元件 | 本版 |
|------|------|
| Unix socket bind | 保留：primary 選舉、secondary 轉送 EXE／「顯示 Cyder」 |
| `CyderSwift --sentinel-connect` | **本版保留**（少一次大拆除），斷線只記 log。**禁止** `onLaunchEnded` → `endLaunch` 清掉仍有 PID 或仍 `starting` 的組。組由 Swift 啟動路徑建立，不由 hello 建立第二份 |
| `mkfifo` / `exec 3<>` / `cyder_sentinel_close_write` | 不作為 UI 契約。本版不必為了壽命去改 Wine 繼承 fd |
| `CYDER_WINE_PID_FILE` | 保留，且是根 PID 的主來源 |
| lifecycle sidecar / `wineserver -w` | 保留給 supervisor 與既有 clean-exit 判斷（視窗工具、啟動失敗）；選單列不在 `state=stopped` 時因為 sidecar 而拿掉仍有 PID 的組 |

不得退回 `mkdir .native-instance-*.lock`。刪除 sentinel-connect 行程本身不在本版。

---

## §5 選單文案（鎖定）

| 狀態 | 一行 |
|------|------|
| `starting` | `{rootDisplayName} — 正在啟動` |
| `running` | `{displayName} — 執行中` |
| `leftover` 且有有用名稱 | `{上次前景名} — 等待 {背景名} 退出` |
| `leftover` 且沒有有用名稱 | `{上次前景名} — 已結束，等待背景程序退出` |
| 使用者確認結束 | `{名} — 正在結束 Windows 程序` |

有用名稱：`cyderUsefulWindowOwnerName`／`cyderWineArgvName` 既有黑名單（wine、preloader、wineserver、Cyder）。

啟動浮動面板文案維持「正在啟動程式…」，在**這一場**第一次成功認領（或 30s 逾時且行程仍在）後關閉。

---

## §6 要改的程式（範圍）

| 檔案 | 變更 |
|------|------|
| `scripts/cyder_status_item.swift` | Session = LaunchGroup；用 `id` 附加 PID；關視窗不靠 sessions 空才算；禁止 prefix-only `isMonitoring` 當附加鍵 |
| `scripts/cyder_app_main.swift` | 啟動當下 `beginLaunch(id:)`；pid 檔用同一 id 附加；helper ended 不結束組；關庫／設定用 §2；認領用 §3.3；activation 等待不掃窗 |
| `scripts/cyder_sentinel.swift` | 斷線 ≠ 結束啟動；helper 可不當壽命來源 |
| `scripts/cyder-common.sh` | 不把 fifo EOF 當成 UI 結束；pid 檔契約不變 |
| `docs/cyder.md` | 刪「fifo EOF／helper 連線代表 launch 結束」的過時句，改指向 LaunchGroup |
| 契約測試 | `test-cyder-sentinel.sh`、`test-cyder-status-item.sh`、`test-cyder-open-files-lifecycle.sh` |

不改引擎 repo，不改選單列繪圖。

---

## §7 測試與手動驗證

契約測試必須鎖住：

- 選單列 Timer 不得 `forMode: .common`。
- `cyder_app_main.swift` 不得在等待迴圈呼叫 `wineProcessHasOnscreenWindow(pid: winePID)`、`wineHandoffOnscreenWindows(since:)`、`wineRegularAppsLaunched(since:)`。
- 必須有 `didActivateApplicationNotification`。
- 關掉視窗路徑必須在有 LaunchGroup 時不 `terminate`。
- `beginMonitoring`／附加 PID 不得再 `if isMonitoring(prefix:) { return }`。
- sentinel `onLaunchEnded` 不得是唯一／直接的 `endLaunch`。

手動（test channel `dist/Cyder.app`）：

1. 雙擊 Cyder → 遊戲庫開遊戲 → 關掉遊戲庫 → 醒酒瓶仍在，選單仍有該遊戲。
2. 同一 bottle 再開第二個遊戲：兩行，互不等待。
3. 點選單不轉圈。
4. GGMWebStart → MapleStory：名稱變成 MapleStory，不是「等待背景」。
5. 關掉遊戲視窗後，若防作弊還在：leftover 文案；icon 仍在直到那些 PID 結束。
6. 沒有遊戲、關掉遊戲庫／設定：Cyder 結束、icon 消失。

---

## §8 明確拒絕的替代讀法

- 「helper 還連著 = 遊戲還在」：否。Wine 常關多餘 fd，fifo 會在 spawn 後立刻 EOF。
- 「同 prefix 已有 session 就不要 beginMonitoring」：否。那會把這一場的 PID 丟掉。
- 「同 prefix 的視窗都算進最後一場啟動」：否。兩遊戲會併成一組或搶名稱。
- 「lifecycle stopped 就拿掉選單列」：否。那是 prefix／根程式視角，不是 LaunchGroup。
