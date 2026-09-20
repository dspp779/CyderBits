# Cyder 環境存續與啟動監控 Implementation Plan

> 2026-09-21 實作授權：本任務已進入 A–F 實作與隔離測試。下文「只做文件／不建置／不操作 Wine／待使用者實測」均為先前階段歷史紀錄，不再限制本任務；依 goal prompt 先真實實測，受阻後採明確標示的替代驗證。允許任務分支上的 Conventional Commits；不 push、merge、發布或覆蓋正式安裝。進度及證據另記於 `docs/superpowers/reports/2026-09-21-cyder-lifecycle-evidence.md`。

> **最新實作入口：2026-09-21。** 請先讀 [實作批次與驗收](2026-09-21-cyder-lifecycle-rollout.md)。本文件保留 Task 1–28 的追溯資料；歷史步驟與勾選不代表新版已完成，禁止照原順序重跑。最新規格為 spec §12–23，衝突時依其明確修訂。

**Goal：** 受管理 prefix 環境決定選單存續，程序／視窗依證據提供內容；所有 UI 路徑非阻塞，退出 Cyder 與停止環境分離。

**Architecture：** 單一 LifecycleStore 產生快照，RequestCoordinator 持久接管／去重，prefix waiter 與程序／視窗 observer 只送事件；UI 不自行判定環境結束。server PID 為可選實例證據，wineserver -w 不作個別遊戲壽命判據。

**Tech Stack：** AppKit、Dispatch、既有 native Unix socket 與背景持久 journal；具體新型別／儲存實作於批次 A／C 決定。

## Global Constraints

- 平台：macOS 11+ native `CyderSwift`；不改 Catalina shell-only 路徑。
- 不進 `cyder-wine-engine` 做 `--wait-children`。
- 不新增依賴；不把 Cyder 升成 Dock（禁止 `setActivationPolicy(.regular)`）。
- 選單文案依 spec §13–14、§21、§23；背景程序不預設稱為等待退出，未知不假報結束；退出與停止使用不同命令。
- 字串契約測試只作輔助；必須有非同步行為、事件追蹤與實際 UI 效能驗證，不能以字串存在宣稱無卡頓。
- 嚴格遵守下方 Apple 官方依據及 spec §9；主執行緒不得執行程序樹、視窗掃描或同步等待背景觀測。
- Commit 用 Conventional Commits；**僅在使用者要求 commit 時執行 git commit**（使用者規則優先於本計畫的 commit 步驟）。
- 測試依最新批次清單，先核對存在性／副作用與契約；不盲跑歷史命令。部分舊字串斷言已不適用，需以新版行為測試取代。

## 歷史 File map（非新版改動範圍）

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

依 spec §3.3 決定歸屬，但所有 `wineProcessTreeIDs` 查詢必須移到背景：

1. 主執行緒僅讀取群組快取，擷取不可變的候選資料與版本。
2. 背景檢查程序樹；不得存取或修改 AppKit 物件。
3. 回到主執行緒驗證群組、版本及程序身分，再套用結果。
4. 歸屬不明不能僅因同 prefix 就收進某組。

**撤銷舊版例外：即使只查一次，也不得在 main 掃描程序樹。** 舊版同步程式範例已移除，避免被複製回實作。

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

Expected: 全部 `PASS`；若有既存失敗，依 Task 9 分開記錄，不得宣稱整套通過。

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

## 2026-09-20 補強：Apple AppKit 選單回應性

### 官方依據與適用範圍

以下 A1–A5 為 Apple 官方文件；查閱日期為 2026-09-20。其餘佇列上限、版本判斷與驗收門檻是 Cyder 的工程決策，不宣稱是 Apple API 強制規範。

| 依據 | Apple 說明 | Cyder 必須遵守的處理 |
|---|---|---|
| [A1 menuWillOpen](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen(_:)) | 此回呼不得修改選單結構或項目 | 不呼叫 `rebuild`、增刪項目、修改標題或啟用狀態；只記錄 tracking 並暫停動畫 |
| [A2 menuNeedsUpdate](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)) | tracking 開始、選單即將顯示時準備項目 | 從記憶體快照建構；不掃程序／視窗、不讀檔、不等待工作完成 |
| [A3 Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) | 非 UI 工作移出主執行緒；主執行緒不可同步等待背景工作；約 100 ms 為離散互動的粗略指標 | 背景觀測、主執行緒短小套用；100 ms 不是 API 保證，也不是每個回呼可用的時間預算 |
| [A4 Run Loops](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html) | Cocoa common modes 預設包含 event tracking；計時器受 mode 影響 | 動畫只用 `.default`，展開時暫停；不得以改成 `.common` 解決更新延遲 |
| [A5 WWDC21 Understand and eliminate hangs](https://developer.apple.com/videos/play/wwdc2021/10258/) | 使用快取、通知與背景工作；合併密集通知；注意非同步順序與資源成本 | 合併查詢、拒絕過期結果、控制排隊量；AppKit 的建立與修改留在主執行緒 |

### 現況與剩餘差距

已存在工作樹的修正：程序樹歸屬與補查視窗移到 observation queue；新增慢查詢測試；群組不存在時丟棄回傳。這些不是完整驗收。

仍待處理：`menuWillOpen` 重建選單；背景查詢無合併；launch worker 無期限 semaphore 等待；缺少觀測版本；靜態圖示仍週期重繪。現有測試直接呼叫 delegate，不能替代真正的 AppKit tracking 操作。

### Task 5：選單生命週期符合 A1–A2

Files: `scripts/cyder_status_item.swift`、`tests/test-cyder-menu-responsiveness.sh`、`tests/test-cyder-status-item.sh`。

- [ ] `menuWillOpen` 只設 tracking 狀態與停止動畫；移除 `rebuild(menu)`。
- [ ] `menuNeedsUpdate` 以已準備好的不可變顯示快照建構選單；資料未變則避免重複建構。
- [ ] tracking 中持續接收、更新模型，但不改選單結構／項目；只設 dirty flag。這是 Cyder 的穩定操作策略，不是宣稱 Apple 全面禁止動態選單。
- [ ] `menuDidClose` 後合併套用最新快照；群組在 tracking 中結束時，也延後移除 status item 與自動退出，直到 tracking 結束。使用者明確退出走既有安全關閉流程。
- [ ] 選單 action 用穩定識別字重新驗證目標與 stopping 狀態；不能只信畫面上舊的 enabled 值。
- [ ] 測試 `menuWillOpen` 前後項目物件、數量、標題及 enabled 不變；慢查詢時 delegate 可完成；關閉後顯示最新狀態。

### Task 6：限制觀測成本，保留程序事件處理

Files: `scripts/cyder_status_item.swift`、`scripts/cyder_launch_support.swift`；必要時拆出純觀測協調元件並加入建置來源。

- [ ] 昂貴觀測採單一協調入口，初版全域最多一個進行中的視窗快照；同一群組不重複排隊，只保留一個 dirty 狀態與必要 completion 訂閱者。
- [ ] 掃描途中收到新事件，只標記需要補查；完成後最多補排一輪。連續事件不持續延後首次查詢，也不無界追加工作。
- [ ] root／已知 PID 的退出監控與慢速視窗查詢使用不同處理路徑；不能被視窗查詢阻塞。
- [ ] 視窗查詢、程序樹與程序資訊讀取在背景執行；AppKit 物件及 Session 模型由主執行緒持有。禁止多個 queue 同時修改模型。
- [ ] 批次回傳觀測結果，每批只要求一次顯示更新，避免逐 PID 重建選單。
- [ ] 測試密集事件：查詢並行數不超過 1、同群組待補查數不超過 1；查詢阻塞時已知程序退出仍可處理。

### Task 7：非同步完成、期限與過期結果

Files: `scripts/cyder_app_main.swift`、`scripts/cyder_status_item.swift`、相關行為測試。

- [ ] 移除觀測的無期限 `observationFinished.wait()`，以 completion／狀態轉移推進啟動收尾；成功、失敗、取消、期限到達都必須恰好完成一次。
- [ ] 初始工程參數：最後補查的等待期限為 2 秒，使用 monotonic clock 並集中定義、可注入測試。此數字非 Apple 規範，需依實測調整；既有 30 秒 activation 等待不因此延長為無期限。
- [ ] 期限到達先解除啟動佇列的觀測等待；保留最後可信狀態，記錄 observation unknown。不能把 unknown 轉為成功、有視窗或 stopped；終止清理僅依已確認證據。
- [ ] 底層同步系統查詢可能無法取消。邏輯逾時只放棄等待，不冒充取消成功、不無限新增替代查詢。若持續卡住影響其他群組，只降級視窗補查，已知 PID 事件仍有效；另記診斷，是否需獨立 helper 留待量測後決定。
- [ ] 每份觀測攜帶 launchID、generation、擷取時間、程序身分（PID＋建立時間）。群組取消／終止／觀測失效時更新 generation；套用前驗證，不得復活群組或覆蓋較新退出狀態。
- [ ] 確認 completion 真正涵蓋歸屬判斷：若認領另外啟動非同步程序樹查詢，不能提前回報「認領完成」。
- [ ] 更新 early-return／defer 清理：尚有未決觀測時不得刪除其需要的 sidecar 或先 `endLaunch`；收尾所有權集中，避免重複 callback 和清理。
- [ ] 測試逾時、取消、late result、群組退出、PID 重用、completion 順序與佇列釋放；用可控制假時鐘／查詢，不靠長時間 sleep。

### Task 8：最少必要重繪

Files: `scripts/cyder_status_item.swift`。

- [ ] starting／running／background 圖示未變時不重畫、不開動畫 Timer；保留原文案與瓶子外觀。
- [ ] 只有 stopping／attention 需要動畫時使用 `.default` Timer；Reduce Motion 下提供靜態圖示。
- [ ] tracking 暫停視覺刷新，但不暫停模型、程序退出與取消處理。
- [ ] 圖示參數及顯示快照未變時不觸發 AppKit 更新；cache 在實際相關條件變更時失效。

### Task 9：分層驗收，禁止以模擬通過宣稱實機修復

- [ ] 型別檢查使用 `scripts/create-cyder-app.sh` 的當前完整來源清單，驗證 arm64／x86_64 的 macOS 11 deployment target；不複製上方歷史清單造成漏檔。
- [ ] 執行 sentinel、status-item、menu-responsiveness、open-files-lifecycle、instance 契約及行為測試。已知先前 `open-files-lifecycle` 曾因 `collapseEngineVersionSlug` 契約失敗；確認當前結果，分開記錄既存失敗，不刪除斷言來掩蓋。
- [ ] 真正的 AppKit 事件追蹤測試：滑鼠展開、鍵盤導航、關閉選單；在選單開啟時完成掃描、結束群組、退出最後程序。直接呼叫 delegate 的單元測試不足以完成此項。
- [ ] 情境覆蓋：冷啟動、啟動器交棒、同 bottle 多程式、慢／不回傳視窗查詢、密集事件、Reduce Motion。
- [ ] 用 Instruments 的 Hangs／Time Profiler 記錄實際問題。參考 [Apple WWDC23 Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/)。使用支援 Hangs 的系統；macOS 11 相容性另行驗證，不能假設新版工具可在所有支援系統使用。
- [ ] 加入 signpost 或等價輕量量測：menu preparation、background query、snapshot apply；不可在每次 UI 回呼同步寫大量 log。
- [ ] Cyder 初始驗收目標：選單準備／快照套用各 p95 < 5 ms；在所記錄測試機與正常負載下，至少 100 次實際開啟的互動延遲 p95 < 100 ms。記錄最慢值、硬體、OS、負載及量測邊界；delegate 計時不能冒充點擊到顯示時間。
- [ ] 壓力情境不得有應用程式自行造成的無期限主執行緒阻塞；任何轉圈均須保留 trace 分析，不能只靠平均值掩蓋。
- [ ] 測試版打包、實機結果與原始碼檢查分開記錄。使用 test channel，不因更新計劃自動發布、簽署正式版或 commit。

### 本項完成定義

Task 5–9 全部具備證據才可宣稱第 1 項完成；Apple 官方方法契約不得以「目前看起來不卡」豁免。若硬體／測試條件未具備，明確標示尚未驗證。跨入口分流、程序歸屬完整重設、sentinel 重構與重啟恢復仍屬後續議題，不在本次回應性補強中擴大實作。

## 第 2 項：統一啟動入口（方案已定案，待實作）

對應 spec §10。保留第 1 項的所有主執行緒與選單回應性契約。本次定案不代表 Task 10–13 已執行。

### Task 10：請求模型與現況核對

Files: `scripts/cyder_app_main.swift`、`scripts/cyder_instance.swift`、`scripts/cyder_uri_handler.swift`、`scripts/cyder_launch_support.swift`；必要時新增請求模型檔並加入建置來源。

- [ ] 再核對冷啟動 `docPaths[0]`、常駐佇列預設 `.exe`、共享 pending 參數的當前行為，記錄可重現的入口差異。
- [ ] 建立不可變 LaunchRequest，包含 requestID、來源、目標／類型、參數及設定快照；保留參數 nil 與空陣列語意。
- [ ] 定義驗證後的執行資料與 requestID→launchID 關聯；prefix 在既有規則解析後固定於該次執行，不再讀取其他請求的 pending 欄位。
- [ ] 以行為測試固定相同目標、參數、設定從不同入口進入時的等價性；不要求不同來源的互動 UI 完全相同。

### Task 11：共用佇列與類型 dispatcher

- [ ] 所有入口只轉換輸入並 enqueue，包括冷啟動、常駐、遊戲庫、CLI、secondary 與 URI。
- [ ] 同批檔案逐一建立請求，依陣列次序排隊；跨來源依 primary 接受順序。不得靜默丟棄第一筆之外的檔案。
- [ ] 共用環境驗證及類型 dispatcher；保留 MSI／REG 的既有互斥限制、腳本／捷徑的執行方式、URI 的解析與參數規則。
- [ ] 啟動階段採單一排程所有者；成功交棒、失敗、取消、觀測期限到達都恰好完成一次佇列推進。不等待遊戲結束，也不得重入啟動同一請求。
- [ ] 個別失敗只結束該請求，保留後續；外部啟動缺少環境時明確回報，不隱藏修復。未決觀測依 Task 7 保留不確定狀態。

### Task 12：傳輸去重與結果歸屬

- [ ] requestID 在第一次接收使用者操作時產生，傳輸重試保留原 ID；多檔批次每筆 ID 亦保持穩定。
- [ ] 已接受／處理中／完成的同 ID 重送不再執行；回傳或查詢原結果，不把重送當使用者新操作。
- [ ] 同一路徑的新使用者操作取得新 ID，不採路徑、prefix、時間窗去重；有多開限制時使用獨立、明確規則。
- [ ] 每筆結果及診斷帶 requestID，實際啟動時帶 launchID；不把送達成功與啟動成功混淆。
- [ ] 與第 6 項確認 ACK、去重記錄保存範圍及崩潰後結果不明的處理，再驗收跨程序重送；不以記憶體去重宣稱跨崩潰 exactly-once。

### Task 13：入口一致性驗收

- [ ] 冷啟動／常駐／遊戲庫／CLI／轉送各適用入口，對 EXE、MSI、REG、腳本、捷徑使用相同 dispatcher；URI 在冷啟動、常駐、轉送中使用相同 URI 處理器。
- [ ] 一次三個檔案都有個別結果；第二個失敗或取消時，第三個仍被處理。
- [ ] 接連收到不同參數與設定的請求，包含 nil、空陣列、空白與非 ASCII 路徑，驗證無資料串用。
- [ ] 同 ID 在排隊、啟動中及完成後重送，實際 spawn 次數不增加；同路徑不同 ID 不被傳輸去重攔截。
- [ ] 環境不完整時各入口得到一致判斷，不發生隱藏重建；一個請求失敗不清空佇列。
- [ ] 長啟動、交棒及失敗收尾期間，選單仍可操作；回歸第 1 項測試，完整 Swift 型別檢查與既有 launch／instance／URI 測試。
- [ ] 保留測試結果與實際入口驗證證據；未完成的 ACK 協定或平台驗證明確記錄，不宣稱第 2 項已完成。

## 第 3 項：證據認領與獨立程序（核心規則已定案）

對應 spec §11，取代歷史 Task 2 的「唯一 starting 群組即可認領」。使用者允許歸屬困難時直接列出存活程序，不強求群組。視窗事件／標題橋接仍是經文件與原始碼確認可行後的技術建議，須經版本實測才能定案實作方案。

### Task 14：取消推定認領，新增獨立程序存續

- [ ] 以 PID＋建立時間辨識程序，groupID 允許 nil；prefix 只決定 Cyder 管理範圍。明確驗證 Windows PID／Unix PID 映射，不能混用。
- [ ] 移除 prefix-only waiter 完成、唯一 starting 即認領及讀不到 prefix 時補 waiter.prefix 的邏輯。
- [ ] 有明確父子／根程序或交棒證據才認領；焦點、標題、時間接近不足以單獨認領。
- [ ] 未歸屬存活程序列在獨立區域，按 bottle 分區；不重複計數同程序的多個視窗。群組結束但程序仍在時保留 UI。
- [ ] 檢查自動退出、關視窗與 `applicationShouldTerminate` 路徑：自動清理 UI 不得誤走停止 prefix；只有明確「結束 Windows 程序」使用既有停止流程。
- [ ] 建立管理範圍內的程序發現契約，補測無視窗、reparent、非直接子程序；若僅靠現有事件不能完整發現，明確列出限制與所需能力，不宣稱完整清單。
- [ ] 測試同 bottle 兩遊戲、舊程序搶焦點、PID 重用、prefix 不可讀及所有群組已空但仍有獨立程序。這些情況不得自動停止 wineserver。

### Task 15：焦點觀察與啟動交棒分離

- [ ] NSWorkspace activation/deactivation 只更新 native app 前景；Wine 通知只作 activation 提示，驗證來源及 scope 後才處理。
- [ ] 分開儲存 process alive、window visible/minimized、Wine foreground 與 macOS active app；失焦不改程序歸屬或存活。
- [ ] 只有有效使用者意圖與可信目標才做 cooperative activation；觀察事件不反向觸發 activation，使用者切換其他 app 後不搶焦點。
- [ ] macOS 14+ 遵守 yield／activate 契約、檢查可用性；11–13 走明確版本分支；收到允許不冒充取得前景。
- [ ] 驗證多視窗、其他 Space、全螢幕、最小化、選單 tracking 與 launcher 交棒。App-level activation 與精準視窗切換分開驗收。

### Task 16：視窗名稱與事件來源能力驗證

- [ ] 顯示優先序採非空 window title→程序／EXE 名；標題不當主鍵、不作歸屬證據、不預設寫 log。多視窗列子項，無視窗程序仍列程序名。
- [ ] 先做能力矩陣：目前 pin 的實際 engine、兩個 Windows 位元架構、macOS 最低／目前版本、權限允許／拒絕／撤銷、標題空白／變更、視窗銷毀與 handle 重用。
- [ ] 原生 CGWindow title 受權限限制時回退；AXObserver 須處理不支援／未授權／訊息失敗，不阻塞 main，不要求基本功能必須有額外權限。
- [ ] 若原生能力不足，優先提出 winemac 自有視窗 metadata bridge 的獨立 engine 設計，包含公開 macOS API、版本能力、事件序號、Unix PID／window identity、來源驗證與 IPC 斷線降級。不得在 app repo 直接修改 engine。
- [ ] WinEvent helper 僅作替代 POC：out-of-context hook、message loop、事件過濾、必要初始快照、32/64 位與 desktop 範圍測試；helper 結束策略與 server drain 必須先驗證，避免監控自己永久維持環境。
- [ ] 區分視窗事件覆蓋率與程序發現覆蓋率；視窗 bridge 不能冒充全程序 monitor。原始碼存在事件不代表 shipped binary／實際遊戲事件必然完整。
- [ ] 保留程序名 fallback，通過實測再決定正式事件來源；本次不新增永久 wineserver keepalive，不把監控失敗變成遊戲退出。

### 第 3 項新增驗收：NGS tray-only 背景程序

- [ ] 實際重現使用者回報：MapleStory 結束、NGS.exe 無可見視窗但仍在執行。記錄程序身分與來源，不靠 EXE 名稱特判。
- [ ] 分別驗證有歸屬／無歸屬／父程序已退出重新掛接；NGS 均保持可見的程序項目與退出監控，Cyder 不停止 bottle。
- [ ] 點原有 tray 開啟 NGS 視窗，驗證同一 ProcessRecord 更新可見性與可用標題，不產生假 launch 或恢復 MapleStory 為執行中。
- [ ] 區分關閉視窗回 tray 與真正退出；只有退出證據才移除程序。保留另一個同 bottle 程序時，NGS 退出不得結束整個環境。
- [ ] 程序查詢失敗顯示未知、不誤報已退出；wineserver 延後結束不倒推 NGS 存活或唯一持有者。
- [ ] 若新增「顯示 NGS」操作，必須另測 tray callback 能力；未支援時不把一般 app activation 標示為可靠的開啟視窗功能。

### 第 3 項前置 Gate：完整性複核待辦

對應 spec §11「完整性複核」。依最新 §12，此 Gate 改為程序／視窗內容增強的驗收，不再阻擋 wineserver 環境存續方案定案；使用者要求先不執行 Wine／遊戲驗證。

- [ ] 用 NGS 無視窗、父程序已退出、監控較晚啟動三種情境，驗證同一程序資料來源可發現並追蹤退出；記錄實際 pinned engine 行為。
- [ ] 驗證初始快照／事件交錯、事件缺號、重連及睡眠喚醒；補查不會產生幽靈程序、遺漏退出或復活舊程序。
- [ ] 將歸屬未知、存活未知、視窗未知分開測試；單次失敗或不完整清單不等於 stopped，不因未知關閉環境。
- [ ] 定義基礎設施／業務／未知程序的展示與 UI 保留規則；測試只有 Wine 基礎服務、只有 monitor、只有 NGS 的不同結果。禁止程序名字黑名單決定真實存活或停止。
- [ ] 同 bottle 多場遊戲共用 NGS／launcher 時不重複列程序、不推定獨佔，不因其中一場結束自動終止共享程序。
- [ ] 監控 epoch 與 server instance 變更後拒絕舊事件；跨 app 重啟恢復的完整實作與第 8 項協調。
- [ ] 初版顯示／開窗／正常退出／強制停止能力分開標示；無 tray callback 支援時保留原 tray 操作，不提供會誤導的「顯示視窗」或「關閉 NGS」。


### Task 17：第 3 項最新定案的最低實作範圍（待實作，不執行 Wine 驗證）

此 Task 與 spec §12 取代早期以群組／任意 PID 決定 UI 壽命的規則。程序發現仍有價值，但不再是保留選單的必要前置。

- [ ] 建立 ManagedEnvironment：bottle、engine、server 實例身分、監控世代與 starting／alive／unknown／exited；保留多 bottle 與同 bottle 共用語意。
- [ ] 設計可靠 server 身分辨識與退出通知，排除其他 Wine 環境，處理已存在 server、PID 重用與重新建立；不可只用 pgrep、程序名或父程序歸屬。
- [ ] 更換所有自動 UI 結束判斷，包含 onAllSessionsEnded、關窗、啟動收尾；統一查詢 ManagedEnvironment＋Cyder 視窗＋未決要求，避免舊 LaunchGroup 判斷提前退出。
- [ ] 明確區分 UI 自動退出與使用者停止環境；前者不得調用 kill-prefix／wineserver -k。unknown 保留入口並顯示待確認，有界重試，不以逾時偽報退出。
- [ ] server 已活但程序資料不足時提供環境層顯示，不偽造遊戲存活或啟動成功。已知程序與視窗採原 §11 的證據、標題 fallback 與被動焦點規則。
- [ ] 更新現有測試：NGS 未被發現但 server 存活仍保留、兩 bottle 只退出其一、正常排空延遲、persistent server、監控失聯、server 重啟、未決啟動、tracking 中退出。
- [ ] 後續才安排實際 Wine／NGS／tray 相容性驗收；目前僅文件定案，不建置／啟動／停止 Wine，也不宣稱遠端完整操作成功。

### Task 18：第 4 項狀態與顯示分離（設計已定案，待實作）

對應 spec §13。僅更新設計，依使用者要求不執行遠端 Wine 操作驗證。

- [ ] 拆開環境、請求、程序、視窗／焦點狀態；移除把 PID 存活或 activation timeout 同時設為 hasForeground 的轉換。
- [ ] 建立獨立顯示投影，將多個內部狀態轉為少量明確文案；檢查背景執行、未知視窗、觀測失聯各自語意。
- [ ] 無視窗工具正常退出不誤報失敗；程序存活但視窗未確認時有界收尾、不持續顯示等待視窗、不偽報取得前景。
- [ ] 穩定遊戲／程序識別、視窗標題層級與清單順序；未歸屬或共用程序不重複列出，多 bottle 才增加必要環境分區。
- [ ] 區分暫時資料失效與啟動錯誤，限制重複提示；過期資料不冒充即時。重新整理有界、僅在使用者明確要求時觸發手動補查。
- [ ] 檢查資訊列／動作列的可操作性與停止範圍；未支援 tray 開窗不提供假操作，環境停止不可偽裝為關閉單一 NGS。
- [ ] 以 §13 情境矩陣做文案與狀態轉移測試；真正使用者理解與遊戲操作驗收留待另行安排。

### Task 18 補充：使用者任務與技術能力對照

- [ ] 先建立「查看程式／切回視窗／開啟 tray-only UI／正常退出／停止環境」的互動流程，再對照可用 API 或所需 engine bridge。
- [ ] 能力表區分：已支援、待實作、需授權、尚待驗證、已驗證不可行；每個缺口列替代操作與後續工作，不以 fallback 取代支援目標。
- [ ] 為實際動作設計即時回饋、背景處理、去重與可確認結果；未完成時回報原因，不偽報成功、不無限轉圈。
- [ ] 先以靜態情境檢視資訊量、名稱穩定性、可操作性與停止範圍，再於使用者可驗證時安排實機任務測試。遵守目前不操作 Wine 的限制。


### Task 19：落實第 4 項選單互動（§14 已核准，待實作）

- [ ] 實作單環境扁平清單、多環境分區、有視窗在上／背景在下、穩定排序與必要的背景子選單；能力不足時顯示環境資訊，非空白或虛構程序清單。
- [ ] 單視窗點擊切到最前；多視窗用標題子選單；最小化恢復、Space／全螢幕遵循系統允許的方式。操作綁穩定程序／視窗身分。
- [ ] 依已驗證能力決定資訊列或操作列；tray 未支援不提供假按鈕，另有 app-level fallback 時明確標示。
- [ ] 一般成功不彈面板；慢操作提供非阻塞回饋，合併重複點擊、限制等待，失敗／退出／未知提供相符文案，不重啟程序冒充切換。
- [ ] 停止操作區分此環境／全部環境、顯示影響範圍與清單不完整提示；單程序正常退出需可靠能力，強制結束留在工作管理員。
- [ ] 補充靜態情境與行為測試：MapleStory 單視窗、Steam 多視窗、NGS tray-only、程序於選單展開後退出、權限拒絕、狀態失聯、重複點擊；實機驗收另行安排，現在不操作 Wine。

### Task 20：第 5 項啟動交棒（§15 已核准，待實作）

- [ ] 根程序退出與後繼程序存活分離；正常根退出允許交棒，可信後繼仍活時非零根退出不能直接宣告遊戲未啟動。
- [ ] 以單一 monotonic deadline 實作初始 30 秒觀察上限，不因根退出／無關通知延長；結果涵蓋已確認、已結束、失敗、取消、未確認。
- [ ] 到期解除面板與佇列等待，監控受管理環境不停止；每請求恰好推進一次，sidecar／觀測清理與 Task 7 協調。
- [ ] 晚到程序依證據附加或獨立顯示，不重新啟動、不搶焦點、不重複完成請求；取消、server 世代更新後拒絕過期操作。
- [ ] 用可控制事件與時鐘測試：根先退、後繼晚到、非零根退出但後繼存活、無視窗工具正常完成、同環境其他遊戲仍在、觀察到期後發現程序、取消與交棒競態。
- [ ] 實際 launcher／MapleStory 驗收另行安排；目前只文件定案，不操作 Wine。

### Task 21：第 6 項可靠轉送與最少干擾（§16 已核准，待實作）

- [ ] 對照 Apple HIG Alerts／Feedback／Progress／Writing 與 AppKit openFiles 契約；建立單一 request feedback owner，正常轉送不另彈窗或系統通知。
- [ ] 定義 submit／status／cancel／ACK 的版本化訊息，requestID＋payload digest、batch 子 ID、primary epoch、launchID 與持久結果；以相同 ID 重試。
- [ ] 在背景建立單一寫入者 journal 與崩潰可恢復的 accepted／dispatching 轉換；避免 ACK 後丟要求、刪檔前處理未接管與舊 ID 重播。
- [ ] 核對 primary 獨佔所有權：原程式 hung／暫時無回應不可解除鎖或自行成為第二 primary，移除無法協調時仍照常執行的雙主風險。
- [ ] 移除 `waitUntilNoPendingRequests` 主執行緒阻塞、全目錄清空 ACK、10 秒靜默過期與 main common-mode I/O 輪詢；通知只作喚醒提示。
- [ ] 非同步有界重連／查原 ID，接收後 primary 統一處理結果；握手中止不冒充尚未執行。能力有缺口時不以更換 transport 名稱宣稱解決。
- [ ] 定義取消／dispatch 的線性順序、tombstone、結果未明時的取消意圖；不得顯示取消成功後又晚到啟動。明確新操作才能使用新 ID。
- [ ] 保護 URI／argv payload、驗證來源與 schema；定義 journal／tombstone 保留和退休 ID 拒收策略，不永久保留敏感啟動資料。
- [ ] 處理 Finder 批次回覆、混合 URL／檔案要求、nil／空參數與 UI-only request；ACK 和遊戲結果分開，不回覆兩次、不因某種輸入先處理就丟掉其他輸入。
- [ ] fault-injection 行為測試：ACK 遺失、重複 request、同 ID 不同內容、磁碟失敗、primary hung／crash、dispatch 前後 crash、取消競態、延遲要求、不同 secondary 同時送出、socket 假失聯、journal 清理後舊 ID。
- [ ] UX 情境檢查：一般零額外問題、短重連無干擾、長延遲有行動入口、批次只一份結果、不要求停止其他遊戲、不用成功通知刷屏。
- [ ] 本次只文件設計；不啟動 Wine，實作測試與實機驗收另行安排。跨崩潰 exactly-once 不列為不實保證。


### Task 22：第 7 項責任分離與程序事件（§17；待實作）

責任分離已同意；socket／DispatchSource 選型為本次補強建議。不得把文件核對視為實機驗證。

- [ ] 統一 sentinel、supervisor、environment monitor、observer 與 UI 的責任及 ID；盤點 FIFO／helper 消費者後再移除重複監控。
- [ ] 先完成 Task 17 的可信 server 身分取得，再用背景 DispatchSourceProcess 觀察退出；不把 Windows PID 當 Unix PID。
- [ ] 定義初始快照、註冊交接、再次驗身分與 unknown fallback；若需直接 kqueue 處理註冊錯誤，維持單一權威，不重複觀察。
- [ ] 以實例／建立時間／epoch 防止 PID 重用及晚到回呼；修正 kill(pid, 0) 所有錯誤皆當退出的路徑。
- [ ] socket EOF／timeout 只更新通道狀態，與程序退出、健康、啟動結果分開；不以探活新增 Wine 客戶端或私有協定依賴。
- [ ] 以可控事件測試：註冊前退出、註冊期間 PID 重用、EPERM、註冊失敗、socket 單獨中斷、程序掛住但未退出、舊回呼、新 server 接替、多 bottle、喚醒後重核、NGS 未被列出但 server 仍活。
- [ ] UI 維持快照驅動、無高頻輪詢、tracking 時延後移除；主程序重啟接管與第 8 項對齊。
- [ ] 目前僅文件更新；後續另行安排實作與 x86 Wine／NGS 實機驗收。


Task 22 缺口複查補充（待確認）：

- [ ] 在實作前明訂可信 server receipt／接管證據；無證據不得認領。註冊 ready 與身分確認分開，註冊等待有界。
- [ ] 取消來源不觸發程序退出；socket FD 唯一 owner 在所有來源完成取消後釋放，晚到 UI 回呼驗世代。
- [ ] fork／exec 觸發的耗時補查移出事件 queue；限制併發與合併事件，快照版本防止結果倒退。
- [ ] 定義 unknown 重試耗盡的靜態 UI、恢復觸發與保留遊戲的退出監控流程；後者連同第 8 項定案。
- [ ] 停止與新啟動序列化；測試外部重啟 server、prefix 範圍停止與 timeout，禁止危險自動重送。
- [ ] 補測取消與退出交錯、FD 重用、掃描卡住／事件爆量、舊快照晚到、server 退出但已知程序仍在、待派送要求與退出同時發生。


Task 22 最新修訂（prefix waiter 優先；取代必須先取得 server PID 的前置）：

- [ ] 以使用者＋實際 prefix 身分合併環境監控，明確 engine／namespace；同 prefix 不以不同 engine 建立假隔離。
- [ ] 每環境一個非同步 wineserver -w waiter；用 Process terminationHandler，移除 UI／共用 queue 的同步 wait 與輪詢，stderr 有界非同步收集。
- [ ] 補齊 starting→監控交接、過早返回、prefix 替換、cancel／signal／spawn failure、新要求與舊 waiter 完成競態；無限存活 waiter 不套啟動逾時。
- [ ] 明訂完成校準證據：本機 -w 忽略 wait_for_lock 的 fcntl 回傳，不可僅憑 exit 0 宣告停止；不能以再跑一次 -w 代替修正。必要引擎變更另在 engine repo 規劃。
- [ ] 取消僅指向持有的 waiter，不殺 server；NGS／persistent server 繼續等待、UI 無 spinner。程序歸屬仍不使用同 prefix 推定。
- [ ] 本次僅文件／原始碼核對，不執行 Wine；此修訂與 Task 17、§12 的環境模型對齊，server PID 降為可選的具體實例觀測資訊。


### Task 23：第 8 項重新開啟後接回（§18 設計已完成，待實作）

- [ ] 分離 AppKit UI restoration、環境重新校準與 request journal 恢復；首屏不等待掃描，依開啟入口選 UI。
- [ ] 確認 primary 所有權後才接管；多 prefix 限併發恢復、不認領未管理的 Wine，重新驗 prefix 身分與 engine。
- [ ] 非同步重建每 prefix waiter 與程序／視窗快照；舊 PID／HWND 不直接操作，實作 §17 完成證據門檻。
- [ ] queued 經核對後提供一次繼續／取消；dispatching uncertain 不自動重播，同時處理此次新 request。
- [ ] 版本化私有持久紀錄、交易寫入與清理；損壞不當未執行，跨 OS 開機失效舊身分。
- [ ] 落實已定案的退出／停止分離：選單退出、Command-Q 與一般 app 終止入口只關閉 Cyder／監控，不停止 Wine、不要求先結束遊戲、不每次詢問保留／停止。退出先停止接收／派送，保全 accepted 要求，不以 kill-prefix 或程序群組終止清理 observer。
- [ ] 將上次異常退出的無需即時決策警告改非模態入口，成功接回不通知、不搶焦點。
- [ ] 按 §18 情境矩陣驗收；本次僅完成文件設計，不執行 Wine／遊戲。


Task 23 完成設計補充：

- [ ] recovering／running／ended／unknown 分離，背景校準初值 5 秒、耗時併發 2，與無期限 waiter 分開；跨 monitor／boot 世代拒絕舊回呼。
- [ ] 正常退出將未派送要求保存 awaitingUserResume；closing 握手、唯一 executor 鎖及 dispatch 凍結正確交接。
- [ ] AppKit 非同步退出回覆恰好一次；初始 3 秒收尾預算，不等遊戲／server，不以 default-mode timer 推進必要收尾；持久化錯誤提供具體退出選擇。
- [ ] engine 路徑驗可信登錄、缺失 payload 不重播、損壞紀錄有限讀取；engine 更新不混接運行中 prefix。
- [ ] 停止中退出只保存／核對，不在重開時補送停止命令；退出所有分支不得隱含終止 Wine。

### Task 24：下一階段整合（spec §19；尚未開始實作）

- [ ] 將八項決策整理為共用模型與單一狀態權威，清除實作中 LaunchGroup-only 退出判斷；歷史文件以最新修訂為準。
- [ ] 順序：狀態契約 → UI 回應性／退出隔離 → 入口與可靠傳輸／監控 → 互動與恢復 → 分層驗收。
- [ ] 優先補明 -w 完成校準證據，不用 exit 0／再跑 -w 冒充可靠結束判斷。
- [ ] 先規劃無 Wine 的替身與事件測試；實機驗收維持延後，不啟動／停止 Wine、不建置或發布產品。


### Task 25：統一狀態契約落地（spec §20；本次已完成設計，未實作）

- [ ] 定義 Request／LaunchGroup／Environment／Process／Window／Operation 與 app lifecycle；環境存在、監控健康、停止進度分離。
- [ ] 單一序列化 Store 只做轉換，journal／掃描／程序／socket 全部以帶 token 的非同步 effect 完成事件接回；未 committed 不 ACK／spawn。
- [ ] 定義事件 epoch／revision／scan token 淘汰與冪等完成，過期快照不復活目標，main menu tracking 不重放中間版本。
- [ ] 落實 active 下單一 keepStatusItem 政策；歷史 uncertain／awaitingUserResume 不單獨永久留 app，明確退出不受環境存活阻擋。
- [ ] 遷移 Session／hasActiveSessions／onAllSessionsEnded／onSessionEnded，移除同 prefix 單群組推定歸屬，拆 requestQuitAndStop。
- [ ] 先用無 Wine 的事件序列驗證壽命與競態，再替換實際 producer；過渡期只有一套退出決策。


### Task 26：回應性與退出隔離（spec §21；已完成路徑設計，待實作）

- [ ] 最小快照／退出 adapter 先接上，取消舊 Session-only 收尾權威；不得雙方各自退出。
- [ ] menuWillOpen 與 menuDidClose 都不修改選單；menuNeedsUpdate 只讀快照，callback 返回且離開 tracking 後再處理 deferred 更新／移除並重核 revision。
- [ ] secondary ACK、launch observation、runner completion 全部非同步；取消 observationFinished.wait、main sleep／I/O，逐個核對 runLauncher caller。
- [ ] 將退出與停止所有入口分離；移除 quitWhenSessionsEnd 混用、停止時隱藏 UI／切 activation policy、停止結果 exit 0 直接標 stopped。
- [ ] runner completion exactly once，pipe 有界排空、取消按操作分類，不把取消觀測傳遞成殺遊戲；不可取消掃描限制 in-flight。
- [ ] 測試慢掃描／ACK 遺失／永久 pending observer、menu 關閉即重開、退出與 dispatch 競態、停止部分失敗；明確退出不發任何停止環境指令。
- [ ] 另安排 supervisor／父程序退出不傷遊戲及真實 AppKit tracking 驗收，目前不執行 Wine。


### Task 27：啟動轉送／監控／交棒整合（spec §22；設計完成，待實作）

- [ ] delivery ACK、launch observation、environment end 分開完成與記錄，不共用成功旗標。
- [ ] 定義 framing／容量／版本／來源、submit-query-cancel 與版本化回覆；journal 提交先於 ACK，同 ID 跨 outbox／socket consumer 不重派。
- [ ] receipt 明訂 Bash／supervisor／Windows root 證據層級，launchID 關聯；取消與 dispatch 授權序列化。
- [ ] primary crash 後檢查仍活執行者／晚到 spawn，不因新 primary 取得鎖便重播舊 dispatch。
- [ ] 分離排程 slot、環境變更互斥權、持續監控；單環境停止／變更只限制該環境必要操作。
- [ ] 期限依 §22 分層，30 秒觀察不被 root exit 重設；到期釋放觀察而非殺程序，waiter 無運行時長期限。
- [ ] 以事件矩陣驗證跨模組交接；校準證據門檻維持，未執行 Wine／實機驗收。


### Task 28：互動／能力降級／恢復接線（spec §23；設計完成，待實作）

- [ ] MenuSnapshot 分開資訊／操作／子選單與 available／checking／暫不可用／需權限／不支援，不以 running 啟用全部命令。
- [ ] action 送穩定 target 並重驗；焦點意圖去重與取代，舊目標消失不重啟或任意切另一視窗。
- [ ] 回饋集中既有 UI 或選單結果入口；0.5 秒延遲進度／3 秒切換觀察為初值，不重開選單、不搶焦點。
- [ ] 加入獨立退出項目、停止分隔、適當省略號；Command-Q 不做全域攔截。工作管理員走明確 launch pipeline，不當純監控。
- [ ] 恢復重新取得 capability，不重放舊 UI 意圖；awaitingUserResume 提供集中入口但不永久保留 app。
- [ ] 原生鍵盤／VoiceOver、完整可及標籤與非單靠顏色狀態；測試能力拒絕、目標退出、快速改焦點及恢復中退出。
- [ ] 分離替身驗收與 Wine／Space／tray／VoiceOver 實機驗收，目前不操作 Wine。
