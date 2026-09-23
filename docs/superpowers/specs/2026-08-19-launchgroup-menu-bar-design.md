# Cyder：受管理 Wine 環境存續與 LaunchGroup／程序顯示

> 2026-09-21 實作授權：本任務已進入 A–F 實作與隔離測試。下文「只做文件／不建置／不操作 Wine／待使用者實測」均為先前階段歷史紀錄，不再限制本任務；依 goal prompt 先真實實測，受阻後採明確標示的替代驗證。允許任務分支上的 Conventional Commits；不 push、merge、發布或覆蓋正式安裝。進度及證據另記於 `docs/superpowers/reports/2026-09-21-cyder-lifecycle-evidence.md`。

日期：2026-08-19；最新整合：2026-09-21

狀態：八項設計及 §20–23 整合契約已依 A–F 實作；2026-09-23 的替代驗收界線及未驗證實機範圍見 [交付摘要](../reports/2026-09-23-cyder-lifecycle-delivery.md)。各節「尚未實作」保留為當日設計狀態，不代表目前狀態。實作入口：[分批落地與驗收清單](../plans/2026-09-21-cyder-lifecycle-rollout.md)。
範圍：Cyder app（`ogom`）選單列、啟動接力、sentinel helper 的**壽命語意**

閱讀優先序：早期方案保留作歷史背景；衝突時以 §12 環境存續、§14 選單、§15–17 最新修訂為準。尤其 §17 已允許背景 prefix-level `wineserver -w`，不是每個遊戲的壽命判據。§18 為第 8 項完成設計，§19 為後續整合與落地順序，§20 為統一狀態契約；同一議題以後者明確修訂為準。

相關：

- 本對話核准的方案 A（Unix PID kqueue + 視窗／Dock 認領）
- `docs/cyder.md`（選單列／sentinel 現況敘述；實作後需改成與本文件一致）
- `docs/cyder-session-process-monitoring.zh-TW.md`（LaunchGroup 名稱與「不要用 wineserver -w 當 UI」；Wine 內 monitor 不在本版）
- `docs/superpowers/plans/2026-08-17-cyder-menubar-no-dock.md`（永不進 Dock、立刻掛選單列）

## 目標

1. **一場使用者啟動 = 一個 LaunchGroup。** 依 §11 補強，無法歸屬但已確認存活的程序另列 ProcessRecord；依 §12 最新定案，UI 存續由受管理 wineserver、未決請求及 Cyder 視窗決定；群組與獨立程序提供顯示內容。fifo、helper socket、lifecycle sidecar、`wineserver -w` 不作為每個群組的存活真相。
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
settingsVisible ∨ libraryVisible ∨ hasPendingLaunchRequests ∨ hasManagedEnvironmentToRetain
```

關掉設定或遊戲庫：

- 只把對應視窗關起來，並 `setUIVisible(false)`。
- 若 `launchGroups` 非空：留下 status item，維持 `.accessory`，**不** `NSApp.terminate`。
- 若為空且這次是「雙擊 Cyder 進設定／遊戲庫」路徑（`terminateWhenSettingsClose`）：可以結束 Cyder。

`onAllSessionsEnded` 不再直接決定 UI 退出；必須依 §12 查明所有受管理 wineserver 已結束、沒有未決要求且沒有 Cyder 視窗。歸屬失敗、helper 斷線或失去焦點不得觸發停止 bottle。

點選單：`menuNeedsUpdate` 只以目前 `launchGroups` 顯示快照準備選單。`menuWillOpen` 不得修改選單結構或項目，只標記 tracking 並暫停動畫。tracking 中模型繼續更新，顯示結構與 status item 移除延後到關閉後處理。動畫 Timer 只加到 `RunLoop.Mode.default`，只在實際需要動畫時使用。禁止再把 Wine 掃描 Timer 加到 `.common`。詳見 §9。

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

此節舊版「同 prefix 恰好一個 starting 群組即可認領」規則已由使用者核准的 §11 取代：

1. 程序身分（PID＋建立時間）已屬於群組時，只更新該群組。
2. 有可信的根程序、建立／父子關係或明確交棒證據時才認領；多義關係維持未知。
3. 同 prefix、時間接近、同名與取得焦點都不足以單獨證明歸屬。
4. 無法歸屬但已確認屬於管理範圍且存活者，另列程序，不丟棄、不硬塞群組。

啟動等待不可只因 prefix 相同就解除；prefix 讀取失敗不得以 waiter.prefix 猜補。觀測查詢在背景執行，保留 §9 的有界收尾；沒有視窗不等於程序退出。

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


## §9 2026-09-20：Apple 官方準則與回應性必要契約

具體來源、工程參數、實作順序與驗收表見 [實作計劃 Task 5–9](../plans/2026-08-19-launchgroup-menu-bar.md#2026-09-20-補強apple-appkit-選單回應性)。本節優先於舊計劃中允許單次 main 程序樹查詢或直接以 defer 結束群組的簡化範例。

1. **選單回呼：** 遵守 Apple `menuWillOpen` 禁止修改選單結構／項目的契約；`menuNeedsUpdate` 僅讀快取。選單展開不觸發觀測、不等待 I/O 或背景工作。
2. **執行緒：** AppKit 物件由主執行緒建立／修改；昂貴程序與視窗查詢離開主執行緒。即使單次或以 main.async 排程也不例外。
3. **模型與顯示分離：** tracking 中繼續追蹤退出／取消，只暫緩選單與 icon 結構變更。關閉後合併更新；action 重新驗證穩定目標。
4. **觀測有界：** 合併同群組請求、限制進行中查詢與待處理量。慢視窗查詢不拖住已知 PID 退出處理。程序事件不等同於每次都必須做完整掃描。
5. **等待有期限：** 非同步收尾、恰好一次完成，觀測 timeout 不是遊戲退出或啟動成功。不可假設 timeout 已取消底層同步呼叫，也不可藉重試無界增加查詢。
6. **防止過期套用：** 觀測帶 launchID／generation／時間及 PID 建立時間；先驗證再套用，群組結束後不可復活。completion 包含真正的認領完成；sidecar 清理由同一收尾流程負責。
7. **重繪最小化：** 靜態 starting／running／background 不週期重畫；只有實際動畫使用 default-mode Timer，尊重 Reduce Motion。
8. **驗收證據：** 字串測試、可控制非同步測試、真正 AppKit tracking、實際遊戲及 Instruments trace 分層完成。Apple 約 100 ms 的指標是粗略互動準則；計劃中的 p95 與 2 秒期限是 Cyder 工程目標，不是 Apple 保證。

本節只規範第 1 項回應性。§3.3 的完整歸屬策略將在後續議題討論；本次不得因查詢逾時放寬成 prefix-only 認領。新增內部 observation unknown 不代表已核准修改選單文案，也不能映射成「已結束」。

## §10 第 2 項定案：統一啟動請求與佇列

狀態：使用者已同意方案；待實作與驗收。詳細步驟見實作計劃 Task 10–13。此為 Cyder 的產品／工程決策；執行緒與 UI 操作仍須符合 §9 的 Apple 準則。

### 請求契約

- Finder、遊戲庫、命令列、secondary 轉送與 URI 都先轉為不可變 `LaunchRequest`，共用佇列、驗證、分流及結果回報。
- 每個請求包含 requestID、來源、目標及類型、參數與設定快照。參數保留 `nil`（沿用儲存設定）與明確空陣列（不帶參數）的差異。
- prefix 可在驗證階段解析；解析結果以獨立、不可變的執行資料傳遞，不能寫回其他請求的共享暫存欄位。
- requestID 表示一次使用者請求，launchID 表示實際啟動群組；未通過驗證的請求不必建立 LaunchGroup。兩者須可關聯以利診斷，不能以路徑或 prefix 取代。
- 同一次收到多檔時，保留回呼陣列次序；不同來源以 primary 接受順序排隊，不宣稱可還原跨程序的原始操作時間。每個檔案都有獨立結果。

### 執行與結果

- 所有支援目標由共同 dispatcher 分流：EXE、MSI、REG、腳本、捷徑、URI。保留各類既有執行語意與環境限制，不把 URI 當檔案或一律轉成 EXE。
- 環境檢查共用。需要準備／修復時明確回報並引導使用者；外部開檔不隱藏執行修復或重建。
- 依序處理啟動階段；前一請求完成啟動交棒、失敗、取消或有界觀測收尾後，推進下一請求，不等待整個遊戲或 bottle 排空。
- 單一請求失敗不丟棄後續請求；每個有效請求都須有完成／失敗／取消等明確結果。尚未確認不得偽報成功。
- 主執行緒只管理快取、佇列狀態和 AppKit；等待／驗證遵守 §9，排隊期間選單保持可操作。

### 去重邊界

- 同一 requestID 的傳輸重送不得再次執行；批次傳輸需保留每個子請求的穩定 ID。
- 使用者再次雙擊同一路徑是新請求、新 ID；不得按路徑、prefix 或短時間窗直接去重。
- 是否允許多開由明確的程式規則處理，不能以傳輸去重代替。
- requestID 的重試保留、記錄生命週期及確認協定需與第 6 項協調。此處不宣稱跨崩潰具有 exactly-once 執行保證，也不自動重播結果不明的啟動。


## §11 第 3 項：證據歸屬、獨立程序與視窗／焦點

### 已定案與研究範圍

使用者核准：「有證據才認領，無法確認就保留未知，不用同 bottle 推定歸屬。」補充允許不強求 LaunchGroup 歸屬，只顯示仍在運行的程序。這取代 §3.3 舊的唯一 starting 群組推定；本節也優先於舊「只問 LaunchGroup」的存續規則。

視窗標題優先顯示在技術上可行；事件傳輸方式以下列分期為建議，尚未宣稱目前 engine 已提供公開橋接。研究為唯讀，未修改／建置 engine。

### 模型與存續契約

- LaunchRequest、LaunchGroup、ProcessRecord、WindowRecord 分開；ProcessRecord.groupID 可為空。視窗用程序身分＋視窗識別／世代，不能用標題當主鍵。
- prefix 只能決定管理範圍，不能決定 launch 歸屬。不得接管其他未管理 Wine 環境。程序記錄須驗證 PID＋建立時間與 prefix／可信 engine 來源；Windows PID 與 Unix PID 不互相當成同一數值。
- 已確認存活的未歸屬程序顯示在「其他執行中的 Windows 程序」下，可按 bottle 分區；不要把它冒充為另一個遊戲的 helper。
- 群組為空仍有獨立存活程序時保留 Cyder 狀態 UI。視窗關閉、失焦、查詢失敗或歸屬失敗不能導致 `wineserver -k` 或停止 prefix。
- 本次「不自動關閉 wineserver」落實為：不因 UI 判斷誤殺仍運行的環境；不默認把空閒 wineserver 設成永久 persistent。Wine 自己管理程序／服務及 server 排空，兩者不以選單是否有項目互相控制。
- 若日後採 Wine 內 monitor，它本身可能延長 server 存活；必須定義自身退出、服務分類與排空順序，不能用「monitor 還活著」作為業務程序存活證據。
- 目前 macOS 程序樹＋activation 事件不保證發現所有無視窗、重新掛接的 Wine 程序。獨立程序模式必須另驗證發現完整性，不能只加一個選單分區就宣稱完整監控。

### 已確認的事件來源

查閱日期：2026-09-20。App pin 為 `config/cyder-engine-version.txt` 的 `CX26.3.0-W11-Cyder012`；以下本地檢查來自 sibling 的已套 patch source tree，不等於驗證該打包二進位的全部行為。

| 來源 | 能提供的資訊 | 邊界 |
|---|---|---|
| Wine `WineAppWillActivateNotification` | activation 請求、Unix PID、prefix／config dir | 為 Wine 內部 distributed notification；無 HWND、標題或 launchID，不證明成功取得焦點，也不涵蓋全部視窗切換 |
| `NSWorkspace` activation／deactivation | macOS 應用程式層級的前景變化 | 不是每個視窗的焦點事件；使用 workspace 自己的 notificationCenter |
| winemac `WINDOW_GOT_FOCUS`／`WINDOW_LOST_FOCUS` | 驅動內的視窗焦點事件 | 不是跨程序 AppKit 公開通知，Swift 不能直接訂閱；需要明確 engine 橋接 |
| Win32 `SetWinEventHook` | foreground、視窗顯示／隱藏／銷毀、name change 等 WinEvents | 需要在 Wine 中執行 helper 與 message loop；Win32 文件不等於 Wine 版本相容性保證 |
| macOS AXObserver | focused-window／title 等 accessibility 通知與屬性 | 要處理授權、notificationUnsupported、訊息失敗；不可假設 Wine 每個視窗都實作 |
| `CGWindowListCopyWindowInfo` | 原生視窗 ID、owner PID、bounds；可用時的 title | 是快照而非事件；`kCGWindowName` 可能受 screen-recording 授權過濾，`kCGWindowOwnerName` 是應用名而非標題 |

本地證據位置（engine repo）：`dlls/winemac.drv/cocoa_app.m` 的 `tryToActivateIgnoringOtherApps`／`otherWineAppWillActivate`；`cocoa_window.m` 的 `windowDidBecomeKey`／`windowDidResignKey`／`macdrv_set_cocoa_window_title`；`win32u/input.c` 的 `EVENT_SYSTEM_FOREGROUND`、`win32u/defwnd.c` 的 `EVENT_OBJECT_NAMECHANGE`、`win32u/hook.c` 的 `NtUserSetWinEventHook`。程序排空見 `server/process.c` 的 `process_died` 與 `server_shutdown_timeout`，system/user process 分類不等價於「任意 PID 存活」。

### 與 macOS 交互的建議

1. 被動觀測只更新狀態；永不因收到 focus／title 通知再次呼叫 activate。避免 Wine→Cyder→Wine 的焦點迴圈。
2. 分開儲存 native active app、Wine foreground window、視窗可見／最小化和 process alive。切去其他 Mac app 時不能繼續把 Wine 最後一個 HWND 標成目前 macOS 前景。
3. 自動啟動交棒只在有可信目標、有效使用者啟動意圖且 Cyder 確實持有可讓出的 activation 時執行；使用者已切到別的 app 不搶回。無法證明目標屬於本次請求時不自動讓焦點。
4. macOS 14+ 使用 Apple cooperative activation：`yieldActivation(to:)` 與適當 `activate`；yield 本身不啟動對方，activate 回傳允許也不保證真正取得前景。以後續狀態確認，不循環強制重試。macOS 11–13 保留版本分支，只在明確使用者動作下請求 activation。
5. 使用者明確點選視窗時先驗證 WindowRecord 是否仍存在；有可靠 HWND／native window bridge 才宣稱可定位特定視窗。只有 NSRunningApplication 時只能保證送出 app-level activation 請求，不能假裝精準切換多視窗。
6. distributed notification 只當提示，獨立驗證程序身分與管理範圍；不可僅信 userInfo 的 prefix。橋接 payload 需版本、序號、世代與來源驗證；斷線只使狀態未知，不停止程式。

### 視窗標題顯示策略（建議）

- 優先使用已驗證視窗的非空標題；無標題、權限不足或能力不支援時回退到程序／EXE 名稱。
- 同程序多視窗以子項顯示，程序只計一次存活；背景無視窗程序仍以程序名列出。
- 標題只作展示，不能作 launch 歸屬、去重或終止目標。限制長度、整理控制字元；同名視窗用穩定記錄區分。
- 最小化／其他 Space 的視窗仍可能存在，不能因 onscreen-only 快照沒有它就刪除程序或宣稱視窗已銷毀。
- 不為基本啟動／存活監控強制索取螢幕錄製／輔助使用權限。若使用原生權限路徑，權限拒絕或撤銷時正常退回程序名；不繞過 TCC。
- 標題可能有文件／帳號等資訊，預設只保留記憶體顯示，不寫入持久診斷 log。

### 技術分期建議

A. App 端先修正證據認領、獨立程序顯示與純觀察焦點；native title 可取得才顯示，維持程序名 fallback。明確記錄無視窗程序發現的覆蓋範圍。

B. 若要求可靠標題／視窗切換而不依賴跨 app 擷取權限，優先評估由 Wine 自己透過 winemac bridge 傳回自己擁有的視窗標題、焦點、可見性與穩定識別；不使用私有 macOS API，不新增永久 Wine client。需在 engine repo 另開設計與版本能力協議；視窗 bridge 本身仍不解決所有無視窗程序發現。

C. `SetWinEventHook(WINEVENT_OUTOFCONTEXT)` helper 為可評估替代 POC，不注入目標程序；需驗證 32/64 位、virtual desktop、遊戲相容性、事件缺漏、IPC 與自身壽命，不能直接當作預設正式架構。事件後透過 HWND→Windows PID 與 `GetWindowTextW` 取得資訊；Windows→Unix PID 映射須另外驗證。

### 官方來源

- [Wine 上游 cocoa_app.m](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/cocoa_app.m)：activation 通知的內部契約。
- [Apple cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)、[yieldActivation](https://developer.apple.com/documentation/appkit/nsapplication/yieldactivation(to:))、[activate](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:))。
- [Apple NSWorkspace activation](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)、[AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)。
- [Apple WWDC19 window metadata 與權限](https://developer.apple.com/videos/play/wwdc2019/701/)。
- [Microsoft SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)、[WinEvent constants](https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants)、[GetWindowTextW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowtextw)。

### 必測案例：MapleStory 結束後 NGS.exe 留在 tray

情境來源：使用者回報，非本次現場重現；不得把此 `NGS.exe` 與所有版本的 BlackCipher／NGService 視為同一程序。

- MapleStory 程序退出、NGS 程序仍存活：遊戲主程序標為已結束；NGS 顯示「背景執行」，不能因沒有可見視窗判定終止，也不能僅憑持續存活稱為卡死或正在清理。
- 若已有可信歸屬，群組可顯示「遊戲已結束，NGS.exe 仍在背景執行」；若無歸屬，NGS 列在該 bottle 的獨立程序區。UI 及已知程序監控繼續，不呼叫停止 prefix。
- tray icon 是獨立 UI 資訊：其擁有者可能使用隱藏 callback HWND；不能用「沒有可見視窗」推導沒有任何 HWND，也不能用 native tray 宿主 PID 誤認 NGS PID。
- 點 tray 後顯示視窗：以 HWND／native window identity 的已驗證 owner 對到 NGS ProcessRecord，只更新標題、可見性與焦點；不重新建立 launch、不改歸屬，也不因此標回 MapleStory 執行中。
- 使用者在 NGS UI 選擇關閉後，以程序真正退出為完成條件；視窗隱藏、tray icon 消失或關閉按鈕被按下均不足以證明退出。
- 只有其他業務程序也都退出後才進入正常環境排空；若 wineserver 還在，只能說仍未排空，不能僅據此指定 NGS 是唯一原因。
- 基本監控不需要操作 tray。若要讓 Cyder 的「顯示 NGS」等同點 tray，需要另驗證 icon→owner→callback 的 Wine shell 橋接；app-level activate 不保證喚出 tray-only 程序的 UI，不猜測 callback 或模擬未驗證操作。
- 本案例要求程序發現可涵蓋無視窗／reparent 的 NGS：先確認發現，再用程序身分追蹤退出。看不到程序清單或查詢失敗時標為觀測未知，不能把 unknown 當 stopped。

參考：[Microsoft notification area 與 callback window](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area)、[process 結束與 signaled 狀態](https://learn.microsoft.com/en-us/windows/win32/procthread/terminating-a-process)。Win32 契約仍須在目前 Wine binary 上實測。

### 第 3 項完整性複核：尚未定案／驗證的缺口

以下為設計複核結果與補強建議，不等於已實作或已選定引擎介面。

1. **程序發現來源尚未選定（必要前置）：** 必須選定能提供管理範圍內無視窗程序清單、穩定身分及退出資訊的來源。現有 native tree 與視窗 bridge 都不能自動視為滿足；先以 NGS 情境做能力 POC，再選介面。
2. **初始快照與事件的銜接：** 啟動監控時既存程序也須納入，不能只等新事件。介面需避免 snapshot／subscribe 之間漏掉建立或退出（例如先訂閱緩衝，再合併帶版本快照）；缺號／重連／喚醒後重新校準。不把單一不完整快照缺少某 PID 當作退出。
3. **三種未知分開：** group unknown（不知啟動歸屬）、liveness unknown（不能確認是否仍活著）、window unknown（無法取得視窗資料）。只有 group unknown 時可照常顯示「背景執行」；liveness unknown 應顯示待確認，不永久冒充已確認存活。不得用 TTL 直接殺程序或宣稱 stopped。
4. **觀測與顯示／UI 保留條件分開：** ProcessRecord 全部保留真實證據；已驗證的 Wine 基礎設施可在預設清單折疊，但不能僅憑名字隱藏或排除 NGS。系統服務、tray 宿主、監控 helper 是否維持 UI 需有明確分類與能力證據；不能採「任意 Wine PID 都讓 UI 永久存在」。未知類別不可任意排除，亦不可用分類結果停止 bottle。
5. **共享程序不能推定獨佔：** NGS／啟動器可能被多次啟動共用。建立來源不等於唯一依賴關係；ProcessRecord 全域唯一，群組關聯可顯示為已知關聯或 shared，不能複製計數。即使證明某次遊戲建立該程序，也不代表關遊戲便可自動結束它。
6. **監控會話與故障恢復：** 程序／視窗身分另帶 engine/server instance 或等價監控世代，避免 bottle 重啟後舊事件套到新實例。斷線先降級，不清空真實存活記錄；重連需完整校準，非無界重試。完整跨 Cyder 重啟恢復仍屬第 8 項，但第 3 項至少須定義重新連接與既存程序初始發現契約。
7. **「顯示」與「結束」是不同能力：** NGS 的 tray 開窗不保證可由 app activation 取代。初版可只顯示狀態並沿用原 tray；若無可靠單程序正常退出介面，不應把停止整個 bottle 包裝成「關閉 NGS」。精準操作須重新驗證程序／視窗身分。

以上為 §12 定案前的完整性複核。最新順序改為：受管理 wineserver 實例與觀測健康 → 環境存續 UI → 可用的程序資訊 → 視窗標題／焦點 → 可選 tray 交互。完整程序清單不再是選單存續的前置條件；各能力仍需後續實測，現在不執行 Wine 操作驗證。


## §12 第 3 項最終定案：環境決定選單存續，程序／視窗決定內容

狀態：使用者已核准設計；未完成實作與實機驗證。此節優先於本文及舊計劃所有「LaunchGroup／任意程序決定選單存續」規則，包含 §1–2、§11 的早期補強。使用者目前在遠端，明確要求先不執行 Wine／遊戲操作驗證。

- **存續單位：** Cyder 啟動或明確確認接手的 bottle 所使用的 wineserver 實例。依 §17 最新修訂，環境身分包含受管理 bottle、實際 prefix 身分與 server namespace，另記 engine 參照及監控世代；server PID＋建立時間為可得時的實例證據，不是 prefix waiter 的必要前置；不得只比對程序名稱或依賴 Unix 父子關係，也不得接管其他 Wine／CrossOver 環境。
- **共用與重啟：** 同 bottle 多次啟動可共用一個 server，環境只計一次；不同 bottle 各自管理。原 server 退出後舊事件失效，新實例重新驗證，不能僅沿用 PID 或路徑。具體實例辨識機制屬實作待辦，未宣稱已驗證。
- **選單保留：** 有 Cyder 視窗、未完成啟動要求、已確認存活的受管理環境，或該環境仍處於存活待確認狀態時保留。首次握手尚未建立 server 由未決啟動要求覆蓋，不靠假 server 記錄。
- **觀測失聯：** 保留環境記錄並顯示「狀態待確認」，採有界重試／重新校準；失聯不等於存活或退出，亦不得觸發停止 bottle。所有環境確認結束且無視窗／未決要求後，才可自動結束 UI；遵守選單 tracking 延後移除規則。
- **顯示分層：** server 存活不代表 MapleStory、NGS 或任一遊戲存活，也不代表啟動成功。無可靠程序資訊時顯示「Windows 環境仍在運行／程序資訊尚未確認」；有證據才列程序與視窗標題，不強求 launch 歸屬。
- **正常排空：** server 正常延後退出時接受選單延後消失。server 若已設定 persistent 會讓選單持續存在；不得為保持 UI 自行開啟永久 keepalive，也不得因 UI 清理而殺 server。明確的使用者「結束 Windows 環境」才進入停止流程。
- **NGS 情境：** MapleStory 已退出，即使漏掉無視窗 NGS，受管理 server 仍活著就保留入口。若查得 NGS，再補上其背景狀態；NGS 是否共用、歸屬不明或 tray 無法操作，都不影響環境層存續。
- **能力順序：** wineserver 身分與退出觀測是最低必要能力；完整程序發現、標題、焦點、tray 操作是分層增強。視窗／程序監控 helper 若會阻止正常排空，必須修正自身壽命才可採用。

本項設計可定案；「可定案」不等於已解決運行中的轉圈或完成 Wine 相容性驗收。之後測試需另行安排，不在本次遠端討論中啟動。

## §13 第 4 項：狀態分離與使用者理解

狀態：使用者同意「只表達已確認事實；失焦不改存活、逾時不冒充成功、背景存活不稱為清理」。以下 UX 原則與 §14 互動方案已獲使用者同意，尚未做使用者／實機驗證。取代 §5 舊版鎖定文案中把背景程序稱為等待退出的預設；實作前應統一文案，不能新舊規則混用。

### 內部狀態與外部顯示分開

內部保留環境、啟動請求、程序、視窗／焦點四個面向，但不把四套狀態機全部展示。預設選單回答「目前有什麼在執行、為何 Cyder 還在、需要我做什麼」。Windows PID、Unix PID、launchID、未知歸屬等技術細節留在診斷。

- 程序存在且沒有可靠視窗資訊：顯示「執行中」，不能推論成背景執行或未成功。
- 已確認背景／tray-only：顯示「背景執行」。切到別的 app、最小化或在其他 Space 不應自動變成背景清理。
- 目前焦點只作次要標示，切換 app 不重新排序主清單、不改程序名稱、不改存活。
- 主名稱保持可辨識的遊戲／程式；可靠視窗標題列為主要可操作視窗子項或次要文字，不因標題改動而反覆更換整個群組名稱。孤立單視窗可用標題作主要名稱，必要時附程序名。
- 單一環境避免重複顯示多層 bottle／群組／程序；多環境才按使用者可辨識的環境名稱分區。共享程序只列一次。

### 顯示矩陣（文案建議）

| 已知事實 | 建議預設文字 | 補充／操作 |
|---|---|---|
| 請求排隊 | 等待啟動 | 可在詳情解釋前一請求尚未收尾 |
| 準備／啟動尚未完成 | 正在啟動… | 不捏造百分比、不暴露內部子階段 |
| 程序已存活 | 執行中 | 無法確認視窗不應長期顯示「等待視窗」 |
| 已確認 tray／無可見視窗背景程序 | 背景執行 | 不要求使用者必須清除 |
| 遊戲已退出而已知 NGS 存活 | NGS.exe — 背景執行 | 遊戲已結束可作短期上下文，不永久保留像仍在執行的遊戲列 |
| server 存活，程序資料不足 | Windows 環境仍在運行 | 詳情：程式清單暫時無法取得；不可宣稱沒有程式 |
| 觀測不可靠 | 暫時無法更新狀態 | 已知舊資料標為上次狀態；有界重試，不偽裝即時 |
| 已確認啟動失敗 | 啟動失敗 | 一次有用的原因與下一步，避免相同錯誤重複彈窗 |
| 使用者停止環境 | 正在結束… | 拒絕重複停止；逾時提供未完成的結果，不永遠轉圈 |

### 逾時與提示負擔

- 既有 30 秒等待屬觀測期限，不能作通用成功／失敗門檻；無視窗工具正常退出按執行結果完成。
- 程序仍活但未確認視窗時，結束阻塞式啟動等待、允許下一請求；詳情可提示「程式仍在執行，尚未確認視窗」，不持續以 spinner 暗示正在取得保證成功的結果。
- 短暫觀測抖動不立刻彈警告；保留顯示穩定性，但從資訊失效開始不再假稱即時已確認。持續失聯提供一處非阻塞說明與手動重新整理，禁止頻繁通知。
- 待確認不是已退出，也不是已完成啟動；詳情可保留未知原因與最後觀測時間。視窗標題與敏感內容仍不預設寫 log。
- 狀態列的靜態 icon 表示 Cyder 管理入口仍存在，不承諾某個遊戲活著。只有有界進行中的啟動／停止才考慮進度表現；§9 不作無效動畫的規則仍有效。

### 動作名稱與範圍

- 資訊列與可操作視窗區別呈現；沒有可靠開窗能力時不把整列做成看似可點卻無效的按鈕。
- 基本入口為遊戲庫、工作管理員與明確命名的「結束此 Windows 環境…」；多環境的「結束所有 Windows 環境…」須明確區分。
- 停止確認指出會影響的環境及已知程式；清單不完整時不得暗示只會結束已列出的 NGS。不以「關閉」混淆關視窗、退出 Cyder 與停止 Windows 程序。
- 背景執行本身不使用錯誤圖示、不彈催促清理訊息，不因 NGS 長時間存活自動停止它。

理解驗收（未執行）：使用者能判讀「遊戲已關但 NGS 還在」「程式已啟動但尚無視窗」「只有 server 可確認」「監控暫時失聯」，且不誤以為啟動成功、遊戲仍在或必須強制清理。精確文字與資訊密度仍待介面檢視，不宣稱已通過可用性測試。

### 第 4 項補充定案：以使用者體驗為目標，技術能力盡量補足

使用者明確指定本項屬互動設計，目標是良好的使用者體驗，並盡量提供技術可支援的程度。不能以「目前拿不到資訊」直接作為產品設計終點，也不能以未實作的能力承諾操作一定成功。

- 先定義使用者任務：查看正在執行的程式、回到所需視窗、理解遊戲結束後環境為何仍存在，以及有意識地結束指定範圍。
- 預設介面優先呈現可辨識的遊戲／視窗與有用操作；環境、程序與觀測資訊按需要揭露，不把內部四套狀態機原樣展示。
- 技術能力依使用者任務補足：標題與焦點追蹤、可靠的視窗切換、tray-only 程式的開窗、正常退出等都列為應評估能力；若需 engine bridge，在正確 repo 規劃，而不是因現有 app API 不足直接放棄。
- 「暫不支援」必須區分未實作、系統權限限制與經驗證不可行，並記錄下一步或替代方式。程序名 fallback 與原 tray 操作是可用性保障，不代表永久停止改進。
- 選單中的操作必須符合當前可靠能力。沒有精準開窗能力時，可提供明確標示的 app-level 切換或工作管理員入口；不可把它命名為必然開啟指定視窗。沒有單程序退出能力時，不把停止整個環境冒充成退出該程序。
- 使用者動作應立即有回饋，耗時工作背景執行；回饋依序區分已接收、處理中、已確認結果／未完成。避免重複提交，也不以持續 spinner 掩蓋未知結果。
- 授權只在使用者選用需要權限的功能時，以具體用途說明；拒絕後基本啟動、環境狀態及可用替代操作仍可用。不為僅改善標題就預設要求額外權限。
- 正常背景執行不打擾；只有明確失敗或需要使用者決策時才提高提示強度。可用性與不誤導並列，不以「資訊最完整」作為預設資訊量目標。
- 以任務完成與可理解性驗收：能找到程式、回到目標、理解 NGS 背景存活、辨識停止範圍；不能只驗證內部狀態值正確。真實操作與使用者驗證仍待另行安排，本次不啟動 Wine。


## §14 第 4 項互動定案：選單排列與點擊操作

狀態：使用者已同意採用本方案；待實作與後續實機驗收。此節將 §13 的建議具體化，對衝突的早期選單／文案規則優先。不因設計定案啟動 Wine 或進行遠端操作驗證。

### 單一環境的預設排列

```text
正在執行
  MapleStory
  Steam                         ▸

背景程式
  NGS.exe
  steamwebhelper.exe
──────────────────
遊戲庫…
工作管理員…
偏好設定…
──────────────────
結束 Windows 環境…
```

以上只是排列示意，項目依實際程序與能力產生；不能憑名稱推定 NGS 可點或 steamwebhelper 不可點。

- 有視窗程式在上方；已確認背景程序在下方。視窗狀態未知但程序已確認存活時，保留「執行中」而不錯分背景。
- 群組／程序順序穩定，焦點改變不重新排序。共享程序只計一次。
- 背景項目較多時收進「背景程式（數量）」子選單；門檻可在介面實作時調整，計數只含實際已知項目，不冒稱全部程序。
- 經驗證的 Wine 基礎服務預設不佔主清單，在工作管理員中查看；隱藏顯示不影響環境存續，不以任意名稱黑名單排除未知程序。
- 單環境不加多餘 bottle 子選單；多環境才依可辨識名稱分區，每個環境的工作管理員與停止動作帶穩定 environment ID。全域停止命名為「結束所有 Windows 環境…」。
- 沒有可靠程序清單但 server 存活時保留環境狀態列；沒有運行環境而 Cyder 視窗仍開啟時隱藏空的程序區，停用不適用動作。

### 點擊規則

| 情況 | 行為 |
|---|---|
| 一個可操作視窗 | 點程式名稱，將該視窗帶到最前面 |
| 視窗最小化 | 嘗試恢復並帶到最前面 |
| 多個視窗 | 程式列顯示子選單；點具體視窗標題切換，不任意挑一個視窗 |
| 其他 Space／全螢幕空間 | 透過系統允許的方式請求切換，不自行搬動視窗或破壞全螢幕 |
| tray-only | 有可靠支援時喚出原介面；未支援時為資訊列，保留原 tray／工作管理員路徑 |
| 沒有可用介面或可靠開窗能力 | 資訊列不呈現假可操作性；若另提供 app-level 切換，須明確標示能力範圍 |

所有操作先驗證目前程序／視窗身分，不信任展開時快照。配合 §9，選單 tracking 中不因背景變化重建項目；動作執行時再處理已退出或能力改變的情況。

### 名稱與多視窗

程式名稱作穩定入口，視窗標題用於子選單（例如 Steam→商店、好友清單、下載）。單視窗可使用「程式名稱 — 視窗標題」，避免無意義的同名重複。過長標題截短且限制選單寬度；識別始終依穩定記錄而非文字。未知標題回退程序名，不強制索取權限。

### 回饋與失敗

- 正常切換成功不顯示多餘進度面板，以目標視窗出現作為回饋；API 接受請求不能單獨當成顯示成功。
- 處理較久才提供短暫、非阻塞的「正在顯示視窗…」；同目標重複點擊合併，操作具期限，逾時給結果而非永遠轉圈。
- 暫時找不到視窗可有界重新確認一次；若程序已退出，更新資料。不重新啟動已退出的程式來冒充切換。
- 程序仍存活但無法顯示時，一次簡短提示「無法顯示視窗，程式仍在執行」；存活也未知時改為「暫時無法顯示視窗或確認程式狀態」。不連續彈出警告。
- 需要權限只在選用對應功能時說明用途；拒絕或撤銷後仍有基本啟動、環境顯示與替代入口。純觀測永不主動搶焦點。

### 結束操作

第一版主選單提供環境層的明確停止操作；可靠支援正常退出單程序時才提供該能力，強制結束留在工作管理員。停止確認列出影響環境與已知程式；清單不完整時說明還可能包含其他背景程式。不能把停止 bottle 包裝成「關閉 NGS」。

NGS 的目標體驗為：點 NGS→喚出原介面→使用者在原介面選擇關閉。tray 橋接尚未可靠支援時，沿用原 tray，不發送猜測的 callback 或以環境停止替代。

完成定義：第 4 項的設計已定案；程式實作、能力矩陣和真實任務驗收未完成，不能因此宣稱操作已可用。

## §15 第 5 項定案：有界交棒觀察與晚到程序

狀態：使用者同意；待實作與另行安排的實機驗收。目前不操作 Wine。

- 啟動器退出不等於遊戲退出。啟動器正常退出且受管理環境仍在時，進入有限時間的交棒觀察，不立即報錯。
- 有可信後繼程序／視窗證據才完成對應交棒；僅發現新程序但無歸屬證據者獨立顯示，不以 prefix、時間接近或焦點推定。
- 初始沿用現有 30 秒啟動觀察上限；這是整次觀察的期限，不在根程序退出時另加 30 秒，也不因不相關事件反覆重設。使用 monotonic clock；後續依實測調整，不把期限當成成功／失敗判準。
- 到期結束啟動面板與佇列的觀察等待，保留環境監控；結果是未確認而非成功／失敗。必要時一次非阻塞說明，晚到程序出現後自然更新清單，不重啟、不重複通知、不搶焦點。
- 啟動器正常退出且環境也確認結束時，記錄該次執行已結束；無視窗工具不因此誤報失敗。不能據此宣稱遊戲曾出現可用畫面。
- 錯誤按階段處理：無法建立程序為啟動失敗；啟動器已建立可信後繼程序後非零退出，不覆蓋後繼程序的存活事實，另外保留啟動器錯誤。根程序錯誤不停止其他存活程序。
- 根程序尚未出現、觀察進行中、觀察已結束、後續獨立發現分開管理；每個請求只推進佇列一次。晚到資訊不能重新完成請求或復活已結束的程序身分。
- §12 的環境身分／監控世代及 §9 的過期結果處理仍適用。使用者已取消或停止環境時，晚到事件不得再次觸發啟動或焦點交棒；新 server 實例須重新驗證。

## §16 第 6 項詳細方案：低干擾的啟動轉送與可靠收件

狀態：使用者已同意本節詳細方案，設計定案；尚未實作／驗證。不執行 Wine 或遠端遊戲操作。requestID 去重延續 §10，啟動結果延續 §15；Apple API 契約與 Cyder 自訂協定分開標示。

### Apple 官方依據（2026-09-20 查閱）

- [HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)：警告會打斷工作，只在必要且有用的情境使用，不為一般資訊或正常啟動顯示警告。
- [HIG Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)：將狀態回饋整合進介面；打擾程度須符合資訊重要性，不需每次成功都額外確認。
- [HIG Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)：進度僅在工作進行時存在、位置一致；不虛構進度，能安全停止時提供取消。
- [HIG Writing](https://developer.apple.com/design/human-interface-guidelines/writing)：錯誤靠近相關操作，用直接、不責怪使用者的文字，說明可採取的行動。
- [AppKit openFiles](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:openfiles:))：依成功、失敗或取消呼叫 `reply(toOpenOrPrint:)`；內部 ACK 不自動等於這個 API 的成功結果。
- [NSXPCConnection interruptionHandler](https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler)、[invalidationHandler](https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler)：通訊中斷與不可恢復失效需分開處理；重建通道不代表先前工作未執行。
- [DistributedNotificationCenter suspension behavior](https://developer.apple.com/documentation/foundation/distributednotificationcenter/suspensionbehavior)：通知可能合併或丟棄；不能以一次通知作可靠收件證據。

下列 journal、ID、重試預算及取消規則是 Cyder 工程設計，並非 Apple 指定的實作。

### 使用者流程

1. 使用者開檔或按啟動，在既有遊戲庫／啟動狀態位置立即表示已接到操作；不顯示「傳送中／ACK／主程序」等內部術語，不另開轉送成功通知。
2. 內部將該次操作轉成不可變 request。多檔用 batchID＋每檔 requestID，所有入口進共同排程；UI-only 要求另作冪等的顯示介面操作，不當成遊戲 launch。
3. 唯一 primary 背景驗證、保存 request 與次序後才 ACK。secondary 收到屬於自己的 ACK 後移交 UI／結果責任，正常退出，不等遊戲窗口或 wineserver 排空。
4. primary 統一顯示「等待啟動／正在啟動／結果」，不可 primary、secondary 各彈一次錯誤。同筆 request 的 feedback owner 與去重狀態須可追溯；接管確認後 secondary 不再報該 request 的遊戲錯誤。
5. 短暫通訊問題先自動重連並查詢原 ID，正常恢復不打擾。查到 accepted／queued／dispatching／結果就接回原工作，不能再次 spawn。
6. 持續無法恢復才在原操作位置顯示可行動結果；沒有主視窗的 Finder 開檔可使用單一非模態狀態小窗。背景晚到結果不搶焦點、不重複打開視窗。已在其他 app 工作時保留選單中的狀態入口。
7. 明確失敗／未知結果使用不同文案和動作。普通成功不另發系統通知；同批失敗集中為一份結果，不連續彈窗。

### request 狀態與責任

| 狀態 | 定義 | 可否執行／重送 |
|---|---|---|
| submitted | 本地已保存待交付要求，尚無接受確認 | 用相同 ID 交付或查詢，不能換 ID 隱性重試 |
| accepted / queued | primary 已可靠接管，尚未跨啟動邊界 | 查詢回既有狀態；依正常佇列執行 |
| dispatching | 已保存即將執行記錄，可能已跨外部 spawn 邊界 | 不因重送再次執行 |
| observing | 已取得可信 spawn receipt／正在 §15 觀察 | 回既有 launchID／結果，不等待遊戲結束才 ACK |
| completed / failed / cancelled | 該次請求已收尾 | 重送回原結果，不重播 |
| uncertain | 執行邊界後崩潰或缺少足夠結果證據 | 自動只做查詢／校準，不自動再次啟動 |

completed 只依實際目標語意表示啟動請求完成，不能一律等同遊戲畫面已準備好；觀察到期可保留未確認結果，不偽裝成功。

### 傳輸、保存與單一執行者

- 建議初版沿用現有 native Unix socket 作具版本的 request／reply／status／cancel 通道，配持久 request journal；避免為修復協定立刻新增常駐服務。若後續採 NSXPCConnection，需另定 listener 發現、簽署與部署；XPC 本身不替代去重與 journal。
- 現有 distributed notification 最多作喚醒提示；不得用目錄清空／檔案消失當 ACK。檔案與 journal I/O、socket 連線、backoff 全在背景，移除 main 上 sleep 與 common-mode 目錄輪詢。
- journal 提供單一寫入者、交易化狀態變更與崩潰恢復；先保存 accepted 才回 ACK，先保存 dispatching 才跨 spawn 邊界。持久化失敗明確拒收，不先 ACK 再丟失要求；提交與回覆都不能卡住 main。
- request ID 附內容摘要；同 ID 不同內容回協定錯誤，不能改寫原操作。nil／空參數、順序與 settings snapshot 完整保留；限制 payload 大小及 schema 版本，確認本機使用者與 app/engine namespace。
- primary 選舉必須有 OS 持有且生命週期明確的獨佔所有權。暫時無回應不能視為 primary 死亡，不能只因連線 timeout 刪 socket 後接管；舊 primary 恢復時也不能與新 primary 同時執行。ownership 不可確認時不啟動第二個 executor。
- crash 在 journal 與 spawn 之間仍可能結果不明；需要 launchID 對應 supervisor receipt／程序身分協助校準，不能以同路徑或同名程序當確定證據。協定不宣稱跨崩潰 exactly-once。
- 每次使用者重新雙擊產生新 ID；同一按鈕尚在處理的快速重複提交可暫停該操作控制項，不能用路徑／短時間窗合併不同 Finder 操作。
- journal payload 不記一般診斷 log；含 URI／參數的敏感資料以使用者私有檔案保存、完成後清除不再需要的內容。保留最小去重 tombstone；ID namespace 退休後舊 ID 明確拒收，不因記錄清掉就當新請求重播。

### 重試、期限與取消

- 初始 transport 自動恢復預算建議 5 秒，退避如 0.2／0.5／1 秒後以剩餘預算限制；使用 monotonic clock 與次數上限。數值為待實作量測的工程初值，不是 Apple 規範。此預算與 §15 的啟動觀察期限分開。
- 超過 transport 預算不等於請求取消、未執行或已失敗。只轉為可理解的延遲／未確認結果，終止無界重試，不偷偷改 ID 再送。
- 對 submitted／queued 的取消保存 cancellation tombstone，primary 在 claim 與 dispatch 邊界再次查驗；取消和 dispatch 由同一權威次序裁決。只有確認未跨 dispatch 邊界才能顯示「已取消」。
- 若已 dispatch，不能用「取消啟動」偷偷殺遊戲；明確說明已開始或結果未明，提供狀態入口／明確環境停止動作。取消等待、關閉提示與取消要求不得混稱。
- primary 完全不可達時，可保存取消意圖供恢復後處理，但不能承諾已取消。原 primary 可能已執行，此時不開啟第二個 executor、不自動終止 Wine。
- 若使用者在 uncertain 狀態選擇再次啟動，先確保原要求不會從 queued 延遲執行；舊 executor 狀態無法確認時，不提供會雙重執行的立即重試。能繼續時以新 ID 建立顯式新操作並保留 supersedes 關係；若原程序可能已啟動，說明可能另開一份。
- App 重啟後不自動執行年代不明或結果不明的舊啟動要求。恢復紀錄後可一次提供繼續未開始項目的選擇；已跨 dispatch 者只核對。傳輸重試去重與完整 session 恢復（第 8 項）分工但共用 ID 契約。

### AppKit 開檔結果

`application(_:openFiles:)` 的回覆按原始開檔操作管理，每次回呼的批次只回覆一次，且在 main 執行；不同入口的 API 不照搬此方法。不可在檔案剛寫入 outbox 就回 success。對 Cyder 的啟動式文件入口，成功接管並接受開檔操作與遊戲已啟動仍是兩個層級；實作時明確對應 AppKit 的成功／失敗／取消契約，轉送接收者尚未完成接受時不虛報成功。批次部分失敗提供逐筆結果並一致彙總，不重複回覆或靜默丟檔。

### 文案與操作（建議）

| 情況 | 使用者文字 | 動作／限制 |
|---|---|---|
| 正常或短暫重連 | 沿用「正在啟動…」或「等待啟動」 | 不另加傳輸提示 |
| 確定未接管且原要求已撤銷／拒收 | 無法啟動「名稱」 | 再試一次、關閉；重試前確保舊要求不會晚到執行 |
| primary 仍無回應且執行狀態未知 | 暫時無法確認「名稱」是否已啟動 | 查看執行狀態（有可靠入口才提供）、關閉；先自動核對，不把危險重播設成預設 |
| 已可安全重啟一筆，但原程序可能已在 | 再次啟動可能會開啟另一份程式 | 僅在使用者選擇再次啟動時說明，不在正常流程詢問 |
| queued 取消已確認 | 已取消啟動 | 不另彈成功通知 |
| 批次部分失敗 | 部分程式未能啟動 | 同一處逐筆結果；只重試已確認可安全重試的項目 |

不再要求使用者「關閉所有 Cyder 程序後重試」作為一般錯誤處理；不以強制結束現有遊戲恢復轉送。取消／再次啟動的條件必須符合協定真實能力，文案不能先於證據。


## §17 第 7 項：監控責任與事件驅動存活判定

狀態：使用者同意責任分離；以下 socket／程序事件選型為本次補強建議，待討論確認與實作。只核對文件及原始碼，不操作 Wine。

### 責任邊界

- sentinel／primary：唯一協調者、request 接管與狀態通道；連線壽命不是遊戲壽命。
- supervisor：啟動 receipt、可信根程序身分及退出結果；根程序退出不是整個環境退出。
- environment monitor：依 §12 管理 wineserver 實例，作為環境存活權威。
- process／window observer：提供有證據的程序、視窗與標題；查詢失敗不推翻環境存活。
- UI：僅消費快照與送出操作，不另掃描或自行推論退出。
- 共用 requestID／launchID／environmentID 與世代，不讓 helper 自創無法對應的 ID。確認消費者與收尾責任已遷移後，才移除重複 per-launch helper／FIFO；不直接刪除全部 sentinel。

### Apple API 依據與選型（2026-09-21）

- [DispatchSourceProcess](https://developer.apple.com/documentation/dispatch/dispatchsourceprocess) 監控指定 Unix PID 的程序事件；優先用此高階介面，在背景 queue 處理已確認身分的 server／程序退出。
- [ProcessEvent.exit](https://developer.apple.com/documentation/dispatch/dispatchsource/processevent/exit) 表示程序已退出，不能單靠此旗標分辨正常完成與崩潰，也不表示後繼程序全部結束。
- [Apple kqueue／kevent 手冊](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kevent.2.html) 的 EVFILT_PROC／NOTE_EXIT 可監控退出；socket 的 EV_EOF 表示連線方向關閉，並非程序死亡。若高階介面不足以處理註冊錯誤，才評估直接使用 kqueue；不為同一目標平行建立兩套權威。
- Unix socket 保留作 Cyder 控制通道與 ACK／狀態查詢。socket 檔案存在不是存活證據；斷線、timeout 或 heartbeat 無回應不等於程序退出。通道對端身分及回覆須驗證；回覆只證明當時對端可回應。
- API 選型是 Cyder 工程決策，並非 Apple HIG 強制規定。macOS 程序事件針對 OS PID，不要求被觀察程序為 arm64；x86 Wine 的 Unix 程序可採此方向。Windows PID 不能直接當 Unix PID 使用，實際對應仍待驗證。

### 身分、註冊與校準

1. 先辨識受管理 server：environmentID、bottle／engine、Unix PID、建立時間與監控世代。kqueue 不負責發現 server，也不證明其歸屬；可靠身分來源仍是 Task 17 的實作前置。
2. 取得初始身分快照，建立並啟用事件來源，於註冊交接後再次確認同一實例。處理查詢至註冊間退出／PID 重用；此流程不是 OS 提供的 PID＋建立時間原子綁定，不可宣稱完全無競態。
3. 回呼帶實例與世代 token；舊 source 的晚到事件不可刪除同 PID 的新 source 或結束新環境。每個實例只收尾一次，取消與資源釋放序列化。
4. 現有 watchPIDOnQueue 已使用 DispatchSource 的 exit／fork／exec，但 kill(pid, 0) 非零就當退出須修正：ESRCH 表示查詢時該 PID 不存在，EPERM 表示權限不足，其他錯誤保留未知；成功也只是當下存在，不代表可回應或遊戲成功。
5. 事件註冊不能確認、身分查詢失敗或監控中斷時標示 unknown；背景有界重試／校準，保留環境入口。無事件不自動升級為已確認存活；重新接管、喚醒及明確重新整理時重核身分，無界高頻輪詢不可作常態。
6. fork／exec 通知只提示補查，可能合併；不保證列全瞬間產生並退出的子程序，也不恢復丟失的歸屬證據。程序樹追蹤不是 server 身分的替代品。
7. 程序尚在但掛住仍屬存活；健康／可回應性是另一維度。不為探活任意連 Wine 私有 socket、啟動 Windows helper 或新增會維持 wineserver 的客戶端。

### 對使用者的結果

MapleStory 結束、NGS 仍在時，只要受管理 wineserver 仍確認存活便保留入口；找到 NGS 才顯示它，否則顯示環境仍在運行。socket 斷線只啟動內部恢復；持續失聯才依 §13 顯示狀態暫時無法更新。確認舊 server 退出後收尾該實例，另依未決啟動／新實例及 §12 決定是否移除選單，不直接退出全部 Cyder 或停止其他 bottle。primary 本身退出後的重新接管留給第 8 項。


### 第 7 項缺口複查與補強建議（2026-09-21；待確認）

1. **server 身分來源仍未完成選型**：事件來源不提供 bottle／engine 歸屬。實作前須明訂可信啟動 receipt、已存在 server 接管證據及無證據時的 unknown 路徑；不能把候選 PID 當成已認領實例。此項為最低實作的阻擋條件，不能以換成 kqueue 宣稱解決。
2. **註冊／取消是非同步交接**：使用 registration handler 作事件來源 ready 的交接點，再校準實例；它不證明歸屬或存活。設定有界註冊等待，未完成即 unknown，不能無限等回呼。取消觀察不等於被觀察程序退出；cancelled 與 exited 是不同事件。已排入 UI 的更新仍要驗證 epoch。socket read/write source 共用 FD 時，須等所有使用者完成取消才由唯一 owner 關閉，避免 FD 重用；程序 source 的 PID 不是要 close 的 FD。
3. **監控 queue 不能被補查塞住**：現有 fork／exec handler 會掃描程序樹。事件 queue 只更新狀態與排程；程序樹／視窗／外部命令放獨立 observation queue，有界執行、合併 dirty 通知及限制併發。每份快照帶世代與版本，過時掃描不得覆蓋已退出狀態；事件爆量不得延遲 server exit 收尾。
4. **unknown 的恢復與使用者出口**：重試预算用完即停止該輪自動重試，保持靜態「暫時無法更新狀態」，不留 spinner 或重複警告。重新接管、系統喚醒、可信通道恢復及使用者「重新檢查」可開新一輪有界校準；單純開選單只讀快照。允許明確「退出 Cyder，保留執行中的程式」作結束監控的出口；須在關閉流程確保不落入停止 Wine 的路徑，此退出與停止分離的語意已於 §18 定案。無法確認時不可假裝環境已結束。
5. **停止期間的新要求／新 server**：將同環境停止與啟動要求序列化。停止開始後不再派送該環境的新啟動；新操作保留為明確等待或可取消要求。停止命令前重核目標；若底層只能停止整個 prefix，僅事前檢查 PID 無法保證不殺到外部建立的新 server，必須明示整個環境的範圍，不能承諾只停止舊實例。不因 timeout 自動重送可能影響新 server 的 kill 命令。
6. **server 退出與全部程序／UI 消失分開**：server 確認退出後，已知仍存活的程序若有，改列「環境已結束，仍有程序執行」而非宣稱全部結束；不重新啟動 server。環境入口收尾依 §12，Cyder 仍開啟時可保留診斷資訊。尚有待派送要求或新 server 正在確認時先完成狀態歸約再決定選單壽命，避免瞬間退出 app 又重開。程序資訊不完整不得顯示「所有程序已結束」。

官方補充：[registration handler](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setregistrationhandler(handler:)) 說明事件來源底層設定非同步；[dispatch_source_create](https://developer.apple.com/documentation/dispatch/dispatch_source_create) 明示程序在建立來源前退出的競態；[cancel handler](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setcancelhandler(handler:)) 說明取消後資源清理時機。上述 UI、序列化及恢復規則是 Cyder 設計建議，非 Apple 指定實作。


### 第 7 項修訂：以 prefix 為範圍的背景 wineserver -w（2026-09-21）

依使用者指正重新核對上游 Wine 與本機 CX26 原始碼。本節取代 §17 將 server PID 身分取得列為環境結束監控必要前置的說法；逐程序歸屬仍遵守證據原則。

**已確認語意**

- 本機 `server/request.c` 的 create_server_dir 以使用者 UID 與實際 prefix 的 device／inode 決定 server 目錄；同一使用者、同一實際 prefix 在相同 server namespace 中使用同一個 server 鎖／端點。不同 engine 路徑不是同 prefix 的隔離保證；不允許據此並行混用不相容 engine。symlink 別名應合併，prefix 被替換則視為不同環境身分。
- `server/main.c` 的 -w 分支呼叫 wait_for_lock 後退出，不走 server 初始化。wait_for_lock 以 F_SETLKW 等待 server lock；它不建立 Windows client，也不因等待本身維持原 server 存活。沒有 server 持鎖時可立即返回，不能提前執行一次 -w 就宣稱未來啟動的 server 已結束。
- 細節限制：本機程式在 wait_for_lock 回傳後固定 exit(0)，沒有傳遞 fcntl 的失敗回傳；因此退出碼 0 不是所有情況下的可靠停止證明。啟動失敗、被取消／signal 終止及可能的等待錯誤須分流，不使用 `|| true` 吞掉監控錯誤。
- 原始碼依據：本機 `/Users/jjc/cyder-wine-engine/build/cx26/sources/wine/server/main.c` 的 case 'w'，及 `server/request.c` 的 create_server_dir／wait_for_lock；上游 [main.c](https://github.com/wine-mirror/wine/blob/master/server/main.c)、[request.c](https://github.com/wine-mirror/wine/blob/master/server/request.c) 同具此核心流程。這是原始碼核對，不宣稱已驗證出貨 binary 行為。

**非阻塞設計建議**

1. 每個受管理實際 prefix 最多一個背景 waiter，使用該環境記錄的 engine、明確 WINEPREFIX 與 launch／monitor epoch。環境監控不必先找 server PID；DispatchSourceProcess 保留作已知程序監控或補充佐證，socket 保留作控制通道。
2. 以 Foundation Process 非同步啟動並接 terminationHandler；不得在 main 或共用監控 queue 使用 waitUntilExit、semaphore.wait、sleep／kill-0 輪詢。waiter 在 OS 鎖上等待可以長期存在，不等於 UI blocking，也不佔用 Swift 工作執行緒做同步等待。stderr 有界且非同步收集，避免管線塞滿；不新增維持 Wine 活著的 helper。
3. 先記錄 starting／pending launch，再開始派送；waiter 的建立時機需與 server 已開始的可信證據交接。waiter 過早返回只代表當時沒有鎖，不撤銷仍在啟動的要求，也不在緊密迴圈重開 waiter。啟動觀察按 §15 有界，未知保留可理解的靜態狀態。
4. waiter 完成送到單一環境狀態 queue，先驗 epoch、prefix 身分、取消原因及未決新要求，再做一次背景校準；只有完成證據充分才結束環境。正常完成不能證明等待曾經阻塞，也不綁定特定 server PID。單靠再次執行 -w 仍無法修補忽略 fcntl 錯誤的限制；校準證據需在實作時明訂，可用已驗身分的程序退出／引擎提供的可信結果。拿不到足夠證據保留 unknown，不假裝完整解決。若需修改引擎的錯誤傳遞，另在 engine repo 規劃，這次不改引擎。
5. 監控本身沒有「遊戲執行太久就失敗」期限；只有啟動、重連、停止操作有各自的回饋期限。NGS 或 persistent server 仍維持環境時，waiter 繼續等待，UI 顯示環境／已知程序，不顯示持續轉圈或停止逾時。
6. 取消監控只取消我們持有的 waiter，絕不以名稱搜尋並終止 wineserver，也不呼叫 -k。waiter 的 PID 與實際 server 的 PID 必須區分；取消或異常終止回呼不轉換為環境 exited。
7. 停止／新啟動序列化，舊 waiter 回覆不能結束新的 launch 世代；waiter 返回與新 server 建立之間沒有跨外部工具的原子保證，不宣稱有。Cyder 不自行停止未經使用者授權的共享環境。
8. 一般運行沒有額外警告或設定。開選單只讀快照；掃描在獨立 queue 合併執行。重試耗盡顯示靜態「暫時無法更新狀態」與重新檢查，通道恢復／喚醒再背景核對。使用者仍可切換其他程式；需要處理的停止延遲只在原操作位置呈現，不鎖住整個 app。

環境共用與遊戲歸屬是兩件事：同 prefix 可以共用等待者，但不得因此把 NGS 或其他程序推定屬於某一遊戲。第 8 項接管需恢復 prefix 監控，不要求找回原 waiter 程序。


## §18 第 8 項完成設計：重新開啟後自動接回環境

狀態：依使用者要求完成本項設計；退出與停止分離已明確核准，其餘細節採下列工程決策。尚未實作／實機驗證。第 7 項設計已可進入本項，但 -w 返回後的可靠校準證據仍是實作門檻，不在此宣稱已解決。

### 目標與 Apple 依據

恢復 Cyder 的介面與監控，重新核對外部 Wine 的真實狀態；不把歷史快照當存活、不重播舊啟動。使用者重開後即可操作，不必先選擇「恢復工作階段」。

- [HIG Launching](https://developer.apple.com/design/human-interface-guidelines/launching)：迅速提供可互動介面，恢復先前介面狀態，避免使用者重走步驟。
- [HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)：避免一啟動就用警告打斷，可使用快取／佔位內容及非干擾提示。
- [AppKit state restoration](https://developer.apple.com/documentation/appkit/restoring-your-app-s-state-with-appkit)：可恢復 Cyder 自身視窗／選取狀態；不負責恢復外部 Wine 程序，也不授權自動重啟遊戲。以下環境與 journal 協定是 Cyder 的設計。

### 非阻塞接回流程

1. 先顯示此次入口應有的 UI：直接開 Cyder 顯示遊戲庫；Finder 開檔沿既定啟動回饋入口，不額外展開所有舊視窗。既有環境快照標為正在確認，不冒充正在執行；不用全畫面等待。
2. 在背景確認 primary 獨佔所有權。既有 primary 可用就轉送；僅無回應不可成為第二個 executor。可先呈現唯讀 UI，依賴權威的動作個別等待／顯示延遲，不鎖住整個 app。
3. 讀取使用者私有且具 schema 的環境紀錄及 §16 journal；候選限已管理的 bottle 及可信登錄，不全機認領同名 Wine。重新驗證 prefix 實際身分、權限、engine 與 namespace。以目前可信 bottle 目錄資訊補查缺漏記錄，仍不能因此推定遊戲歸屬。
4. 每 prefix 獨立非同步校準並重建一個 waiter；既有 waiter 不作接管前置，也不依程序名清除孤兒 waiter。只有可證明由舊監控持有的 waiter 才能清理；不可誤殺真正 server。-w 等待中／exit 0 都不能單獨填補 §17 的證據缺口。
5. 已確認環境存活就自然恢復選單內容，不提示「恢復成功」、不搶遊戲焦點；程序／視窗以新觀察重建，舊 PID、HWND、視窗標題只作歷史線索，不直接啟用操作。原先單視窗／多視窗點擊規則繼續適用。
6. 已確認不在的環境移出執行清單；不自動啟動 Wine 來修復監控。未知則靜態「暫時無法確認執行狀態」，提供重新檢查；多環境並行但限併發，單一環境卡住不拖延其他環境。
7. 這次使用者明確的新啟動照 §16 新 request 處理，不因恢復到同名遊戲就擅自吞掉，也不因舊 journal 存在就拒絕所有新操作。只在同環境停止中、舊 dispatch／executor 權威尚不確定等必要範圍暫緩，提供原位置的狀態與安全取消。

### 舊要求與持久化

| 舊紀錄 | 恢復行為 |
|---|---|
| 已確認派送／觀察中 | 只核對，不再次 spawn；無證據則 uncertain |
| 確認未派送且唯一 executor 已接管 | 原位置一次顯示「上次有 N 個項目尚未啟動」；提供繼續／取消，不自動執行 |
| 已完成／失敗／取消 | 保留必要去重結果，不重新執行、不重複通知 |
| 損壞／版本不支援／權威未知 | 保留診斷及未確認結果；不可把缺紀錄當未執行，不自動重播 |

恢復不是歷史工作自動重做。繼續未派送要求須先確認未曾跨 dispatch 邊界，使用原 requestID 並序列化取消；不將 uncertain 混入「繼續全部」。持久化與 ACK 沿 §16 交易順序，平時增量保存，不能等退出時才寫。環境紀錄包含版本、管理環境識別、prefix 實際身分、engine 參照及 epoch；跨系統開機後舊 PID／世代不可沿用。最小化保存，視窗標題不作持久身份，敏感 argv／URI 按 §16 清理。

### 關閉、退出與異常

- 關閉 Cyder 視窗：環境／要求仍需監控時保留選單；不停止遊戲。
- **已定案：「退出 Cyder」與「停止 Windows 環境…」徹底分離。** 退出只結束 Cyder 介面、協調與監控，保留執行中的 Windows 程式；不因遊戲仍在執行而拒絕退出，不順帶呼叫 wineserver -k、kill-prefix 或以程序群組終止遊戲。選單退出、Command-Q 及一般 app 終止入口採相同語意。停止環境是獨立明確操作，維持已定案的影響範圍與必要確認；不能把停止環境當退出的必要步驟。不每次彈出保留／停止遊戲的二選一詢問，若需說明可用非模態短文字。
- 退出時停止接受新要求，將已接受但尚未派送的要求保存為 awaitingUserResume，阻止延後派送；退出不冒充使用者取消要求。已派送者保留追蹤紀錄。正常收尾非同步，只有會遺失已接受操作且不能安全完成時才呈現具體問題，不偷偷放棄要求。
- Cyder crash 不承諾外部遊戲一定存活；重新開啟時確認。既有 showPreviousCrashIfNeeded 的啟動模態警告建議改成遊戲庫／診斷入口的可關閉非模態訊息，只有與本次操作相關且需立即決策的故障才另行提示。
- 不為接回新增登入常駐或自動重啟服務；使用者下次開啟再接回。OS 重新開機後不自動重跑上次遊戲。engine 缺失／prefix 移動／無權限時保留未知並指出受影響環境，不自動 wineboot、重建或替換 engine。

### 情境驗收（未執行）

涵蓋遊戲仍在、只剩 NGS、環境已結束、兩 bottle 其中一個失聯、Cyder 強制退出、系統重開機、prefix 替換、engine 更新／缺失、journal 損壞、spawn 前後 crash、重開時 Finder 新要求、舊 primary 仍活但無回應、恢復途中退出。驗收重點：即時可操作、不重播、不亂認領、不搶焦點、不使 watcher 維持 Wine、不因未知停止遊戲；實機操作留待使用者可驗證時安排。


### 第 8 項補齊的執行契約

- **恢復狀態**：每環境 recovering → confirmedRunning／confirmedEnded／unknown；單次背景校準預算初值 5 秒，限同時 2 個環境做耗時補查，均為可調工程值。到期只終止該輪工作並顯示 unknown，不終止 server，也不套用到長期 waiter。新一輪校準使用新 token；有效長期 observer 仍可提供事件，過期掃描不得覆寫。
- **顯示與操作**：恢復期間可瀏覽遊戲庫、開設定、退出；舊項目標為正在確認。取得新視窗證據才啟用切換。無法確認環境範圍時暫不可停止；已確認的環境可依既定停止流程操作。完成以局部快照更新，menu tracking 中延後結構變更。
- **兩種 epoch**：app monitor epoch 在每次接管時建立，用於排除舊回呼；environment identity／可得的 server instance evidence 用於判定同環境或新實例。更換監控 epoch 不等於遊戲重啟。OS boot 身分不同時丟棄舊程序身分。
- **正常退出與 queued**：所有入口先進入 quiescing，停止 claim／dispatch；已 accepted 的未派送要求保存為 awaitingUserResume，下次由使用者繼續或取消。只關閉該提示不代表取消，項目留在待處理入口，不每次開選單重問。保留 batch 次序；取消須保存 tombstone。dispatch 邊界已跨越或不明者只留結果／uncertain，不放入可一鍵繼續清單。
- **退出途中的新要求**：primary 明確回 closing／未接管，secondary 保留相同 requestID，依 §16 有界重試，不虛報接受；待舊 primary 釋放所有權後才可由新 primary 接管。正常退出前保持所有權直到派送已凍結、紀錄交接完成，不能先釋放鎖再寫資料。
- **退出回覆**：優先利用平時持久化縮短退出工作。必要非同步收尾使用 AppKit terminateLater／reply(toApplicationShouldTerminate:)，每次終止交易只回覆一次，主執行緒不 wait。Apple 此流程進入 modal run-loop mode，不承諾此階段所有 app 互動都正常；不靠 default-mode timer／同步派送維持收尾，不等待遊戲或 wineserver 結束。工程收尾預算初值 3 秒；逾時若原 accepted／dispatch 紀錄已安全持久化即可以非乾淨恢復標記退出，不能因可丟棄快照或 waiter 不退而困住使用者。無法保存必要操作狀態時結束等待，取消此次退出並提供儲存錯誤與明確仍要退出選項；任何分支都不停止 Wine。OS 強制終止／登出不保證有收尾機會，恢復依日常持久紀錄而非最後回呼。
- **缺紀錄／資料錯誤**：schema 不支援或損壞資料保留以便診斷，讀取限大小與筆數，拒絕不可信任欄位。紀錄內 engine 路徑不能直接當可執行授權，須對照目前可信安裝登錄；prefix 不可因同路徑就接受替換後目錄。缺失 payload 不能提供會失真重播的繼續動作。
- **升級與缺失**：優先保留仍在使用的 engine 參照；缺失時不以另一 engine 混接既有 prefix。已確認存活的程序不因 engine 缺失改報退出，顯示可確認部分與環境監控受限。只影響該環境，不阻止其他環境使用。
- **已開始的停止操作**：退出不撤回已送出的明確停止命令，也不再補發停止。保存停止中／結果未明；重開只核對，避免對新 server 重送舊停止命令。

Apple 退出契約：[terminateLater](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater)、[reply(toApplicationShouldTerminate:)](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:))。以上時間／併發值及 journal 策略為 Cyder 設計初值，並非 Apple 規範。

## §19 下一階段：八項設計整合與實作順序

原八項已完成設計討論；本節是後續整合階段，不另宣稱原清單存在第九個問題。本次不啟動程式碼實作或 Wine 驗證。

1. **統一狀態及權威**：建立 request、managed environment、process、window、monitor epoch 的共用模型，集中判定選單存續與退出；§12／§17／§18 優先於原始 LaunchGroup-only 歷史規則。保留 -w 返回後可信校準證據的實作門檻，先完成靜態方案再依條件安排驗證。
2. **回應性與退出隔離先落地**：先移除主執行緒掃描／等待及退出隱含停止；快照 UI、事件 queue 與耗時 observation queue 分離。以可控制替身驗證，不依賴啟動遊戲。
3. **可靠啟動與監控**：共用入口、journal／ACK／取消、prefix waiter、交棒期限與錯誤語意一併接上，避免只改 UI 文案卻保留矛盾壽命判定。
4. **互動與恢復**：完成視窗切換、tray 能力降級、非模態回饋及跨重開恢復；能力未證實的動作不可先顯示可用。先完成 app 層支援，需 engine bridge 的部分另列 engine 工作。
5. **分層驗收**：先靜態核對及可控事件測試，再 source typecheck／必要行為測試；使用者可操作時才驗收 Wine／NGS／tray／實際 menu tracking／Instruments。設計完成、程式碼完成與實機驗收分開記錄，不因文件完整宣稱行為已成功。

整合必過情境：啟動立即開選單、NGS 長留、同 prefix 多程式、多 bottle、啟動中退出、停止中退出、Cyder crash 後重開、舊事件晚到、新 request 與恢復同時進入。核心條件為 UI 不阻塞、不重播、不亂歸屬、退出不停止 Wine、unknown 不假報結束。


## §20 統一狀態模型與判定權責（2026-09-21）

狀態：八項設計的實作契約；本次僅整理文件，未變更 runtime。以下名稱是建議型別／模組名，可配合現有程式命名，但不得合併不同語意。此節消除歷史 Session 同時代表啟動、環境、程序與畫面的歧義。

### 資料模型

| 記錄 | 身分與內容 | 狀態／限制 |
|---|---|---|
| LaunchRequest | requestID、batchID／順序、不可變 payload、來源與設定快照；接受後關聯 launchID | submitted／queued／dispatching／observing／completed／failed／cancelled／uncertain／awaitingUserResume；accepted 是已持久接管的邊界，queued 為其待派送狀態 |
| LaunchGroup | launchID、requestID、顯示名稱、environmentID、已證實的程序關聯 | 提供一次啟動的呈現與觀察期限；不決定環境或 Cyder 壽命 |
| ManagedEnvironment | environmentID 與受管理證據、UID／namespace／實際 prefix device＋inode、可信 engine 參照 | existence = unconfirmed／alive／exited；monitorHealth = attaching／healthy／degraded；兩軸獨立。starting／recovering 是操作階段，不偽造 alive |
| ProcessRecord | boot 身分＋Unix PID＋建立時間（或同等可信 token）、名稱、存活證據 | alive／exited／unknown；environmentID 與 launchID 關聯各自可空、各自附證據。prefix 共用不推定 launch 歸屬 |
| WindowRecord | 有來源的 window token、有效的 process identity、當前標題及能力 | 可見／最小化／焦點等獨立屬性；無視窗、未知與 tray-only 不混為一談，Windows HWND 不当作 Cocoa window ID |
| EnvironmentOperation | operationID、environmentID、用途、世代、期限 | attach／reconcile／stop 等操作各自完成；stop = idle／requested／executing／unconfirmed／finished／failed，stopping 不覆蓋 existence |
| AppLifecycle | primary ownership、monitor epoch、boot 身分、退出交易 | active／quiescing／terminated；使用者明確退出優先於自動保留政策 |

環境 ID 與 app 監控 epoch 分開；同一 prefix 跨 server 重建仍可保留邏輯環境 ID，但執行世代必須更新。若不能證明是否為同一 server，不沿用舊的程序／操作資格。engine 參照不構成同 prefix 隔離。

### 唯一寫入者與模組責任

- `LifecycleStore`：以一條序列化背景狀態 queue 接收事件、檢查證據／世代、執行狀態轉換並產生遞增 revision 的不可變快照。不是持有整段 I/O 的大鎖；不得在 queue 上等待 scan、journal、socket 或外部程序。
- `RequestCoordinator`：派送及取消的唯一協調者，發出持久化指令並等待非同步 commit 事件；未 committed 不 ACK、不跨 spawn 邊界。帶 transaction token 的晚到 commit 不得在 quiescing 時觸發派送；已無法確認的 spawn 邊界保留 uncertain。
- `EnvironmentMonitor`：每 prefix 建立 waiter／校準並回報 evidence，不自行終止 UI。所有 waiter 完成先送 WaiterFinished，絕不直接當 EnvironmentExited；校準通過才送對應結論。
- `ProcessWindowObserver`：只提供帶來源的程序／視窗資料；掃描在獨立 observation queue，限制併發、dirty 合併及期限。不直接修改群組、環境存在與 UI。
- `EffectRunner`：執行狀態轉換產生的非同步指令，包含 journal、spawn、停止、重新校準；每指令带 operationID 及目標世代。只有明確 StopEnvironment 意圖可產生環境停止指令；退出與 observer cleanup 不能產生它。
- `StatusItemController`／AppKit：main 上呈現快照、轉送使用者意圖，不掃描程序、不自行清空 Session 決定 app 終止。菜單操作送穩定 ID，執行前由協調者重新驗目標。
- `AppLifecycleCoordinator`：根據唯一快照決定安裝／移除選單或提出 AppKit 退出；退出交易沿 §18，不等待外部遊戲結束。

### 事件契約與排序

每事件攜帶來源、monitorEpoch、目標 ID、可得的實例證據、operationID／scanToken 及來源序號。timestamp 用於診斷／期限，不以不同來源 wall-clock 大小猜因果。來源未提供序號時，adapter 指派本地交接序號並以操作 token 淘汰舊結果，不假稱捕獲完整 OS 事件。

- 開始校準先配置 token，再執行背景工作；新輪次、退出、環境被替換會使舊 token 失效。
- 程序退出可立即使該實例不可操作；較早開始的掃描即使稍後回傳也不能復活它。重新發現相同 PID 必須新實例證據。
- 相同完成事件重複送達只收尾一次。來源取消只更改監控健康，不表示目標退出。
- main 只接受較新 snapshot revision；menu tracking 期間保留已呈現的結構，點擊再核對 ID，關閉選單後套最新快照，不重播中間每份快照。
- 每次狀態更新後統一計算 UI 壽命，不能以「處理 exit 到一半」的中間空集合觸發退出。已有未決新 launch 時舊 waiter 完成不使 app 結束。

### 重要轉換

| 輸入 | 合法結果 | 禁止推論／動作 |
|---|---|---|
| 已驗證當前受管理環境活著 | existence = alive，紀錄證據；按觀察能力更新 health | 不把任一遊戲設成功／有焦點 |
| WaiterFinished | 排程一次有界校準，保存等待結果與取消原因 | 不因 exit 0 直接設 exited |
| 當前環境已結束的可信證據 | existence = exited，廢止該世代操作；再統一歸約 UI | 不清空其他 bottle；不宣稱未知程序全退 |
| 通道中斷／校準失敗 | health = degraded；舊 alive 只保留為最後已知事實，UI 標示未確認 | 不停止環境、不重啟遊戲 |
| 根程序退出 | 記錄根實例退出，依 §15 處理交棒 | 不結束環境或全部 LaunchGroup |
| 視窗關閉／失焦 | 更新該 WindowRecord | 不改程序／環境存活 |
| launch 觀察到期 | 收尾觀察、釋放排程一次，結果可未確認 | 不無限等待、不停 server |
| QuitCyder | quiescing、保存未派送要求、取消自有監控、退出 | 不產生 StopEnvironment |
| StopEnvironment | 驗證明確目標後序列化停止指令與新啟動 | 不終止 Cyder 作為成功條件；不影響其他環境 |

### 選單與 app 自動存續的單一政策

僅在 app 為 active 時判斷：`keepStatusItem = hasVisibleCyderUI || hasActiveRequestWork || hasManagedEnvironmentToObserve`。

- hasActiveRequestWork：正在接受／派送／觀察或處理當前操作；包括尚未解決的開檔批次回覆。已持久保存的 awaitingUserResume、歷史 uncertain 或結果紀錄本身不永久維持 app；使用者打開其 UI 時由 hasVisibleCyderUI 覆蓋。
- hasManagedEnvironmentToObserve：已管理且確認 alive，或曾被管理而此次狀態仍待確認／正在恢復。普通未運行 bottle 不因存在於遊戲庫就算入；純錯誤路徑不建立假環境。未知保留入口但沒有 spinner，使用者仍可直接退出。
- 無任何保留理由才可自動移除／退出；menu tracking 延後執行，實際退出前重新核對最新 revision 與未決入口，不用舊快照決定。
- 明確 QuitCyder 不受上述保留條件阻止。停止環境後若遊戲庫仍開著，Cyder 照常保留；兩種操作不互相代理。

### 現有程式的遷移點

1. `CyderStatusItemController.Session` 拆分為上述記錄；`hasActiveSessions` 不再作 app 壽命／環境存活總開關。
2. `onAllSessionsEnded` 不直接 `NSApp.terminate`，改用單一政策；`onSessionEnded(prefix)` 不代表整個 prefix 已结束。
3. `adoptWindowedProcess` 的「同 prefix 恰有一個 starting group」分支移除推定歸屬；無 launch 證據即獨立 ProcessRecord。
4. `onStopPrefixes → requestQuitAndStop` 拆成環境停止路徑；停止成功不能強制退出仍開著的 Cyder UI。`quitWhenSessionsEnd` 與一般退出邏輯依同一政策重整。
5. 主執行緒快照 adapter 先接上，逐步替換 producer；過渡期間只允許一個壽命決策者，不讓舊 Session 與新 Store 各自發出退出。

驗收以事件序列及可控制時鐘為主：同 prefix 兩 launch、舊 scan 晚於 exit、未知環境明確退出、只有歷史要求時自動收尾、停止後 UI 仍開、NGS 未發現但 server 仍活。§17 的 waiter 校準證據尚須在實作時補實；此模型不以抽象事件名稱掩蓋該缺口。


## §21 主執行緒回應性與退出隔離：改造契約（2026-09-21）

狀態：已完成靜態路徑盤點及設計，尚未實作。依 §20 模型遷移，不重新引入 Session-only 退出判斷。本節補正先前「選單關閉後更新」：不是在 menuDidClose 回呼內重建。

### Apple 選單契約

[menuWillOpen](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen(_:)) 與 [menuDidClose](https://developer.apple.com/documentation/appkit/nsmenudelegate/menudidclose(_:)) 均明示不得在回呼內修改選單結構或項目。[menuNeedsUpdate](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)) 才是可加入／刪除／修改項目的更新入口。快照仍需廉價可取得；不能把同步掃描搬到 menuNeedsUpdate 就稱為修復。

- menuNeedsUpdate：只以已準備的不可變 MenuSnapshot 更新 NSMenu；不做磁碟、程序、視窗、socket 或同步跨 queue 查詢。項目 validation 同樣只讀快照。
- menuWillOpen：只記 tracking 狀態並停用自身動畫排程，不調 rebuild／refresh，也不以開選單觸發同步補查。
- menuDidClose：只清理 tracking 記錄並標記 dirty；更新排到回呼返回後、確認已離開 tracking 的 main default-mode 工作，或下次 menuNeedsUpdate。每次執行仍檢查 tracking 世代／最新 revision；不能只 async 一次就假設沒有重新開啟選單。
- tracking 期間不移除 status item、不自動退出、不改點擊目標。已排好的退出／移除指令在真正執行前再查統一政策；新 launch 可撤銷舊的自動收尾。
- 背景建立排序、名稱 fallback 與可操作性投影；AppKit 物件只在 main 建立／修改。大量程序採既定分組／子選單，避免無限主選單項目；初始無快照仍提供遊戲庫、設定、退出及簡短確認狀態。

### 現有路徑與替換方式

| 目前路徑 | 問題／限制 | 替換契約 |
|---|---|---|
| status item 的 menuWillOpen → rebuild | 修改回呼內選單 | 移至快照驅動 menuNeedsUpdate |
| menuDidClose → refresh → rebuild | 同樣違反回呼修改限制 | 僅標 dirty，離開回呼及 tracking 後再處理 |
| finishIfEmpty／removeStatusItemIfUnused | Session 空就可能移除，未統一 tracking／環境政策 | 交給 LifecycleCoordinator；真正移除前重核 |
| secondary 的 waitUntilNoPendingRequests | sleep＋目錄掃描，且清空不代表自身 ACK | §16 背景 requestID ACK；結果以 completion 回 UI |
| keepLaunchGroupIfLiveOrClaimed 的 observationFinished.wait | 雖在 worker，仍無界等待 main／掃描，會卡住啟動收尾 | 延續式 completion 與單一 observation deadline，逾時只結束觀察，遲到不再次完成 |
| activation 的 semaphore／sidecar sleep 迴圈 | 占用 worker、期限與錯誤收尾分散 | 事件＋monotonic timer；legacy sidecar 過渡 adapter 在背景有界讀取，不在 reducer 內睡眠 |
| runLauncher 的 waitUntilExit | 共用同步介面，須逐個 caller 核對；不宣稱全部在 main | 以非同步 runner／terminationHandler 收尾，結果解析與 log I/O 放背景，completion 恰好一次 |
| applicationShouldTerminate／quitFromMenu | 將退出導向 requestQuitAndStop | 統一 QuitCyder → quiescing，絕不派送停止環境 |
| onStopPrefixes → requestQuitAndStop | 停止時隱藏 UI、設定退出旗標 | 獨立 StopEnvironment，不強制關視窗／退出 Cyder |

所有耗時呼叫需檢查呼叫端上下文；單純 grep 有 wait 不足以證明 main hang。也不把所有 modal UI 一概刪除：使用者主動選檔、不可逆停止的必要確認保留合理系統互動；一般進度、觀測失聯、上次 crash 不走同步警告迴圈。

### 非同步 runner 的資源與取消

1. 建立 operationID 與 completion owner 後才 spawn；可能的立即退出、spawn error、deadline、cancel 都進同一序列化收尾，恰好一次交付結果。不得只把同步方法包進 global queue 就視為完成遷移。
2. 外部程序執行、輸出排空、解析、日誌修剪全不在 main 或狀態 queue；若用 pipe 須並行排空並限制記憶體，讀完與退出分開協調，若用檔案也避免在 main 讀 tail。取消來源／關 FD 依 §17。
3. 取消 policy 按操作類型區分：觀測可取消 Cyder 自有 waiter；派送後 launch 的「停止等待」不殺遊戲或 supervisor 程序群組；使用者明確停止環境才允許對應停止命令。取消 Task／completion 不等同可安全 terminate 任意 subprocess。
4. 使用者反覆點同一待完成控制項合併該 action；不同 requestID 不合併。慢操作在原位置顯示進度，其他操作仍可用；逾時回未確認不偽報成功。
5. observer 卡住時廢止 token、不再累積無界工作；若是不可取消的 OS 呼叫，限制同時 in-flight 工作與重試，新請求不開更多卡住的執行緒。必要隔離 helper 的範圍另經設計，不把「設定 deadline」誤當底層呼叫真的停止。

### 退出與停止的實際路徑

- 選單退出／Command-Q／AppKit 終止請求 → 同一個 QuitCyder transaction。初次事件即凍結新派送，正常持久化與 observer cleanup 非同步；依 §18 有界回覆 AppKit。重複退出合併，不重開詢問。
- 退出過程取消自身動畫／查詢／waiter，不解除未結束子程序必要的資源或向其傳送終止訊號；實作需檢查 supervisor／pipe／父程序死亡對遊戲的影響，不能只移除 -k 就宣稱遊戲一定存活。
- 停止環境 → 確認明確範圍 → 非同步執行停止 → 校準結果。一次多環境操作按環境獨立回報，單一失敗不把其他環境重新標為存活；不因命令 exit 0 或 UI callback 就把 prefix 直接標 stopped。
- 去除 quitWhenSessionsEnd 對使用者退出／停止的混用。停止不 orderOut 遊戲庫／設定，不為停止而切 activation policy。操作完成後的自動 UI 壽命仍由 §20 判斷。
- 文案統一為「退出 Cyder」與「停止 Windows 環境…」，不再使用「結束所有 Cyder 程序…」混指 Windows 程序。

### 第一批實作切分與驗收

A. 先建立 §20 必要狀態快照及退出意圖 adapter；允許舊 observer 暫作 producer，但關閉其獨立移除／退出權限。不能為小改動繼續用舊 Session 空值推論環境已退。
B. 修正選單回呼與 deferred removal，消除 main 轉送等待；依賴 §16 的 ACK 實作一起切分，不保留「檔案刪掉就是已接管」捷徑。
C. 拆 QuitCyder／StopEnvironment，遷移 runner 和 launch completion，移除觀察無界等待；逐個 caller 檢查取消及錯誤傳播。
D. 用替身控制掃描、journal、ACK、程序退出及時鐘，驗證 main 能繼續處理事件；不以假資料宣稱 Wine 相容性。

驗收條件：

- 掃描不回覆、ACK 遺失、runner 延遲時，選單 callback 不等待背景完成；正常回呼不得呼叫阻塞 API。型別／來源檢查只是補充，另驗實際事件交錯。
- menuWillOpen／menuDidClose 內零結構／項目修改；展開期間零 status item 移除；快速關閉重開仍只套用允許的最新快照。
- QuitCyder 各入口產生零 StopEnvironment／kill-prefix／-k 指令；StopEnvironment 不產生 QuitCyder，不強制隱藏視窗。
- 退出與 queued／dispatch／停止同時發生，accepted 不遺失、不重播、不重複回覆；遊戲是否不受實際 supervisor 清理影響留實機驗收。
- 無新證據不得以 scanner timeout、waiter cancel 或 exit 0 設環境 exited。期限耗盡結束進度提示，保留正確的未知狀態。

本輪可做的工作為文件及靜態檢查；實作後另安排替身／型別檢查，使用者可驗證時才安排 Wine／NGS／AppKit 真實 tracking／Instruments。不要將「快照 callback 看似很短」當成原始轉圈問題已修復。


## §22 可靠轉送、監控與交棒的整合契約（2026-09-21）

狀態：完成設計整合，尚未實作／執行 Wine。沿用 §15–17、§20–21；本節補齊模組交界，避免各模組各自正確卻產生重播或無限等待。

### 三種完成，三個生命週期

- delivery 完成：primary 已持久接受 request，回 accepted ACK；secondary 可交接結果呈現責任。不是遊戲已啟動。
- launch observation 完成：已確認本次啟動結果，或到期限保留未確認；只結束該次觀察與釋放其排程占用，不等待環境排空。
- environment 完成：受管理環境有可信結束證據，才更新環境存續。背景 NGS／其他 launch／persistent server 仍在時繼續監控。

三者各自有完成 token，重複事件不重做。completed 不可作跨層通用成功旗標；結果附 confirmedStarted／finishedWithoutWindow／failed／unconfirmed／cancelled 等原因，UI 依任務語意呈現，不將無視窗完成顯示為遊戲已出現。

### 端到端交接順序

| 階段 | 背景動作與必要條件 | 使用者回饋 |
|---|---|---|
| 接到操作 | 建立不可變 requestID／batch 順序與設定，先在記憶體反映操作，持久化／傳送背景執行 | 原位置立即回饋；不能先宣稱已可靠接管 |
| primary 接管 | 驗來源、版本、內容摘要、權威；提交 queued 後回 accepted ACK | 等待啟動，不另彈傳送成功 |
| 派送前 | 檢查取消／quiescing／同環境停止；配置 launchID、環境參照，保存 dispatching | 正在啟動 |
| 啟動執行者 | 非同步 spawn；receipt 關聯 requestID、launchID、executor epoch 與實際根程序身分 | 等待結果，UI 可操作 |
| 有界觀察 | 記錄根結果、可信後繼／視窗事件，同時建立 prefix 環境監控 | 有證據才更新程式清單 |
| 觀察收尾 | 持久結果，單次釋放排程；後續 observer 繼續更新實際程序 | 去除啟動進度；未確認不偽裝成功 |
| 環境結束 | waiter 完成觸發背景校準，核對新要求／世代後更新環境 | 依統一快照政策收尾，不強制關 Cyder 視窗 |

shell 成功、supervisor 已建立、Windows 根程序已建立與視窗可用須分開記錄。receipt 必須說明它證明哪一層；僅取得 Bash PID 不能填入遊戲 PID 或 confirmedStarted。

### 協定與持久資料的最小契約

- socket 訊息包含 protocolVersion、requestID、payloadDigest、sender／primary epoch、message kind；回覆帶對應 requestID 與狀態版本。status 查詢無副作用，不得順便啟動程式。
- stream framing、訊息大小／佇列容量、讀寫 deadline、截斷訊息與無效版本須明確處理；容量不足在 accepted 前拒收，不無界堆積。socket 路徑不是來源身分；peer 與私有目錄驗證沿 §16。
- 最小訊息為 submit／query／cancel；結果為 accepted、existingStatus、rejected、closing、cancelled 或 cancellationTooLate。ACK 指向持久提交版本；舊回覆不能使 UI 狀態倒退。
- journal 至少保存 request、dispatch intent／receipt、結果、取消 tombstone 與 awaitingUserResume；寫入由單一 owner 排序。內容先落地才 ACK；磁碟失敗不能刪除 secondary 的唯一未交付副本。
- 結果呈現由 primary 承擔；secondary 未收到 ACK 時只可呈現「接管尚未確認」，不能額外報同一 launch 的執行錯誤。結果窗口本身不可靠交付，不因顯示過就刪去去重紀錄。
- 同 ID 重送只查回原紀錄；不同 payload 明確拒絕。讀取舊 outbox 時保留原 ID；禁止遷移成新 UUID 造成重播。

### 派送競態與隔離範圍

- queued → dispatching 的授權點與 cancel／QuitCyder 共用狀態順序。尚未授權的 effect 在 quiescing 時失效；已授權並可能跨 spawn 的 effect 即使尚無 receipt，也只能標為 dispatching／uncertain，不顯示取消成功。
- executor／supervisor 可能在 primary crash 後仍工作。不能只取得新的 primary 鎖就假設舊執行者不會再 spawn。接管需核對該 launch 的既有 receipt／執行者；無法排除晚到執行者時，不自動重播或讓使用者對該舊 request 立即重試。重建監控本身可繼續。
- 對每個 launch 明訂 supervisor 只執行一次的契約與回執；不以 root PID／檔案名稱相同替代去重。跨 journal 與外部 spawn 仍有崩潰間隙，不承諾 exactly-once；未確認結果是正常需要表示的狀態。
- 同環境的停止／初始化／會改變共用設定的操作，必須與啟動協調；不能因觀察到期就釋放仍由實際執行者持有的環境變更互斥權。排程 slot、環境變更權及遊戲存活是不同資源。
- 一般 launch 不等 wineserver 結束才讓後續要求進入；同批保持次序，互相獨立的環境可前進。某環境在停止／變更未確認時，只限制該環境相關操作，不阻塞設定頁或其他安全工作。

### 期限與使用者取消

| 工作 | 初值／期限 | 到期的真正意義 |
|---|---|---|
| submit／重連 | §16 的 5 秒自動恢復預算 | 停止該輪重試，接管可能仍未知；不另開新 ID |
| launch 交棒觀察 | §15 的 30 秒，於開始觀察時記單一 monotonic deadline | 結束觀察，環境與晚到程序仍監控；根退出不重設期限 |
| 環境校準 | §18 的 5 秒 | 健康降級／未知，不結束 Wine |
| prefix waiter | 無遊戲運行時長期限 | 長期等待是正常，不顯示持續進度 |
| 明確停止環境 | 沿用目前 15 秒作初值，另行實測調整 | 顯示停止結果尚未確認，不自動重送停止命令 |

上述時間是 Cyder 初值，不是 Apple 規定。排隊不消耗尚未開始的觀察期限；spawn／準備階段也須有自己的可見進度與有界狀態查詢，不能把 30 秒觀察假裝覆蓋所有前置工作。持續執行中的安裝／初始化不能僅因 UI 等待到期強殺，依其操作契約處理。

取消按鈕只在能安全取消待派送要求時標為「取消啟動」；已派送後可關閉回饋，不稱取消成功。觀察完成的晚到程序自然加入清單，不重新完成 request、重開提示或搶焦點。同 prefix 的新程序仍需獨立歸屬證據。

### 遷移與驗收邊界

- 先接同一 RequestCoordinator，再替換 outbox／socket 接收；過渡版不得同時讓舊目錄 consumer 與新 socket consumer 各自派送同一要求。舊無 ID 或年代不明要求不得自動轉成新要求執行；已接受紀錄按相容策略核對／提示。
- `WineActivationWaiter`、supervisor sidecar 與 waiter 均轉成帶 ID 的事件 adapter；同一 launch 的 observation completion 只由 Store 裁決。
- 不混用「waiter PID 還活著」與「server 已確認活著」。可靠校準結果仍需 §17 的實作證據，這一整合不消除該技術門檻。
- 最小事件驗收：ACK 遺失重送；cancel 與 dispatch 交錯；primary crash 但 supervisor 晚到；根退出後子程序晚到；觀察到期但 NGS 仍在；同 prefix 第二次啟動；停止時新要求；舊 waiter 完成新 server 已建立；一個環境卡住其他環境可操作。
- 下一整合步驟：將選單操作、能力降級與重開恢復接到此契約，之後整理一份可執行的分層驗收清單。仍不操作 Wine。


## §23 選單操作、能力降級與恢復接線（2026-09-21）

狀態：完成整合設計，待實作。沿用 §14 的排列／點擊語意、§18 恢復、§20 狀態快照與 §21 tracking 限制。此節是 UI 與操作協調者的介面契約，不新增遊戲歸屬推論。

### 顯示與能力分開

MenuSnapshot 每列包含穩定 rowID、標題、簡短狀態、類型（資訊／操作／子選單）、actionID、目標 ID、能力與不可用原因。能力至少區分 available、checking、temporarilyUnavailable、permissionRequired、unsupported；不能只用 isRunning 決定所有按鈕是否能點。

- 環境存在已確認、視窗能力未知：顯示環境／已知程序，暫不提供虛假的切換操作。
- 有能力但目前目標消失：保留適用的標準命令並停用，原因在相關狀態位置呈現。永不支援的動作不為每個程序建立一長串灰色項目；程序資訊本身仍可顯示。
- tray-only 列為資訊，除非已確認可喚出原視窗；不能因圖示存在就聲稱可以操作。
- 開啟選單及背景恢復不觸發權限提示；使用者選用確需權限且已驗證可用的功能時才提供用途說明與授權入口。拒絕後不重複要求，也不把授權描述成一定能解決 Wine 相容性。

Apple [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) 要求表達命令不可用狀態，省略號用於還需輸入／選擇的動作；不是所有開視窗的命令都加省略號。本選單為一般 status item menu，不套用 context menu 一律隱藏不可用命令的規則。

### 操作矩陣

| 操作 | 執行前條件與指令 | 完成／失敗呈現 |
|---|---|---|
| 點單視窗程式 | 最新 process／window identity 與可操作能力；ActivateWindow | 真正可確認顯示才完成；目標消失不重啟程式 |
| 點多視窗子項 | 精確 window token，不依標題找第一個同名視窗 | 單一目標結果，不把另一個視窗出現當成功 |
| 顯示 tray 介面 | 可驗證的 tray capability；ShowTrayWindow | 不支援就資訊列，提供已知原 tray／工作管理員入口 |
| 重新檢查 | managed environment ID；Reconcile，與同目標 pending 工作合併 | 有限重試、局部更新；不啟動 Wine 探活 |
| 工作管理員 | 可信 prefix／engine 及可派送條件；OpenTaskManager | 這是使用者明確啟動 Windows 工具，走 request pipeline；可能維持環境存活，不算純監控 |
| 停止此環境… | 明確環境範圍、確認後再驗 target／generation；StopEnvironment | 不混入退出 Cyder；延遲在原環境顯示、不自動重送 |
| 退出 Cyder | QuitCyder，不以環境存在／視窗能力為門檻 | 保存要求、結束自身監控，保留外部程式 |

工作管理員可用時提供替代入口，但不能承諾它能代替 tray 開視窗或安全關閉每一個程序。沒有受管理執行環境時不為檢查狀態自動建立環境；使用者明確啟動工具的其他入口另按其任務語意處理。

### 每次點擊的完整流程

1. main 從快照取 actionID／穩定 target，立即交給協調者；不在選單 selector 掃描或等待。
2. 協調者以最新狀態驗證目標／世代／能力，再發操作。若展開時單視窗已變多視窗且舊目標仍活，仍操作使用者點擊當下綁定的目標；若原目標已無效，不擅自改切另一個。
3. 相同目標 pending action 合併；使用者改點另一視窗時取代舊的焦點意圖，廢止尚未送出的舊 activation。已送到 OS 的要求不宣稱可撤回，晚到回呼不得再發第二次切換。
4. 視窗切換回饋初值為超過 0.5 秒才顯示「正在顯示視窗」，最多觀察 3 秒；這是工程初值而非 Apple 規定。到期即收尾、不持續搶焦點。使用者已切到其他 app 時不再主動補送 activation。
5. 成功不另開視窗／通知。失敗且使用者已在其他 app 時不搶焦點顯示警告，保留 Cyder 狀態入口；同一 operation 只呈現一次結果。

### 回饋放在哪裡

- 遊戲庫／狀態視窗已開：在對應程式／環境旁顯示進度或結果；不另建立第二個面板。
- 只有 status item：在下一次選單開啟時呈現簡短結果列，必要時提供「查看詳細資訊」入口；不自動重開選單、不彈出搶焦點的 toast。結果須保留至已呈現或使用者關閉，不在選單關閉期間悄悄過期。
- 正常狀態不列內部 ACK、PID、epoch 或 raw error。診斷資訊只在使用者主動查看的詳細頁提供，文字仍須說明可採取行動。
- 未知存活：「暫時無法確認執行狀態」；已確認存活但切換失敗：「無法顯示視窗，程式仍在執行」；已確認退出：「程式已結束」。不能以舊存活快照套用第二種文案。

### 最終單環境選單示意

```text
正在執行
  MapleStory — 視窗標題
  Steam                        ▸
背景程式
  NGS.exe                      （資訊列或已確認可用的動作）
──────────────────
遊戲庫
工作管理員
設定…
──────────────────
停止 Windows 環境…
──────────────────
退出 Cyder                     ⌘Q
```

此排列補入已定案的獨立退出入口；空分區不顯示。實作採 macOS 版本適用的原生設定名稱／慣例；遊戲庫與直接開工作管理員不因開視窗就加省略號。多環境操作按 §14 帶環境名稱，停止全部必須明確命名。停止與退出之間有分隔，停止不配置易誤觸的全域快捷鍵；Command-Q 僅是 Cyder 在適用系統選單上下文的退出快捷鍵，不註冊會搶遊戲按鍵的 global hotkey。

### 與重新開啟的接線

- 恢復期間立即建立可用的一般入口；舊程序列標 checking，不能沿用舊的可操作 capability。新證據到達後按 revision 局部啟用。
- 程式名稱／穩定順序沿用可驗證資料，視窗標題及焦點重新觀察。恢復不重放舊 ActivateWindow、StopEnvironment、OpenTaskManager 等 UI 意圖。
- awaitingUserResume 在遊戲庫待處理區集中顯示；若只有選單則提供「待處理啟動（N）」入口。關閉說明不是取消，使用者不理會也不自動派送。它本身不永久保留 app，沿 §20。
- 恢復中使用者明確點新啟動，走新 request；觀測更新不吞掉新要求。明確退出立即廢止恢復操作 token，晚到結果不得重新掛出 status item。

### 可及性與驗收

使用原生 NSMenu 項目保留鍵盤／VoiceOver 行為；狀態文字不只靠顏色、旋轉或 hover tooltip。標題截短時輔助使用標籤仍能辨識完整目標；同名視窗用可見區別文字，識別不靠名稱。進度不每個 tick 作語音公告；只在有意義的變更提供回饋。參考 Apple [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) 與 [Color](https://developer.apple.com/design/human-interface-guidelines/color)。

驗收矩陣：單視窗／多視窗／同名視窗／最小化／其他 Space、tray 支援與未支援、權限拒絕／撤銷、選單展開後程序退出、切換途中使用者改焦點、恢復途中退出、工作管理員使環境繼續存在。先用能力與事件替身驗證 UI 決策，Wine／Space／VoiceOver 真實操作留待實機驗收。下一步是整理可執行的分層驗收與實作批次，避免繼續新增重複設計章節。
