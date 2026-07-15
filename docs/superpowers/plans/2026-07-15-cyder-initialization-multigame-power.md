# Cyder 初始化、多遊戲相容性與能源模式工作計畫

> 日期：2026-07-15  
> 基準：`main` @ `a08b565`（Cyder v0.3 後）  
> 用途：確認現況、記錄架構決策，並切成可交付給多個 Agent 的任務  
> 狀態：核心功能已實作，進入整合與實機驗收（2026-07-16 更新）

## 0. 目前開發狀況（2026-07-16）

| 任務 | 狀態 | 已完成 | 尚待處理 |
|---|---|---|---|
| T00 Swift 拆分 | 完成 | Paths、Settings、Launch support、Settings UI 已拆檔，build source 與 harness 已更新 | Universal app 最終打包驗收併入 T10 |
| T01 wineboot 診斷 | 程式完成 | 獨立／輪替 log、last-wineboot、exit／signal／timeout／產物缺失分類、失敗清理 | Intel Mac 真實失敗重現與對話框驗收 |
| T02 Prefix lifecycle | 程式完成 | staging、artifact probe、安全重建、backup／rollback、active session 保護 | 真實 Wine 損毀後 rollback 實機驗收 |
| T03 App 啟動／修復 UI | 程式完成 | 啟動前準備與檢查、失敗重試／重建／診斷、進階重建入口 | Intel 與 Apple Silicon 手動操作驗收 |
| T04 差異套用 | 完成 | 未修改確認 no-op、逐欄位 prefix ledger、部分失敗續跑、force 重套、移除 BlueCG 全域硬編碼 | ledger 採 bottle 內 `.cyder-settings-applied.tsv`，不再另做 settings.json 的 `appliedByBottle` |
| T05 Template／Profile backend | 程式完成 | pristine／recommended versioned template、APFS clone fallback、path-based Profile、staging publish、legacy shared import | security-scoped bookmark／EXE 移動後重新綁定 |
| T06 遊戲設定與路由 | 核心完成 | Profile 清單、同名路徑區分、獨立 bottle、DPI／sync／Retina／字體／能源／env／args，安全逐項傳遞 | bookmark、launcher＋game 多 EXE 共用 Profile、實機 UX 驗收 |
| T07 Recipe | 框架完成 | 已知遊戲 recipe、validate／plan／offline apply、目標 bottle 隔離 | cnc-ddraw 與 LF2 元件仍需固定來源、授權、checksum 與可重入安裝器 |
| T08 Session guard | 程式完成 | 同 bottle 模式衝突阻擋、不同 bottle 並行、stale lock 回收、Native bridge | 真實多遊戲並行與 MSync 回歸 |
| T09 能源模式 | 完成 | 標準／省電 UI、`taskpolicy -c background`、量測腳本與 BlueCG 報告 | Intel、M1／M1 Pro／Max 與更多遊戲長時間回歸 |
| T10 發布驗收 | 進行中 | schema 1／shared bottle 相容、主要自動測試、指定 CX26 引擎的 Universal app 打包與本機簽署驗證 | Intel／Apple Silicon smoke test、release notes 與正式發佈簽署 |

目前不把 T07 的外部元件安裝與 T05/T06 的 bookmark 宣稱為完成。它們需要來源／授權決策或 macOS security-scoped bookmark 的資料遷移設計，應另開後續任務，避免阻塞本輪核心功能實機驗收。

## 1. 建議結論

本輪建議先完成 **A：初始化可靠性**，再建立 **B：每遊戲 Profile／Bottle**，最後把 **C：能源模式**接入正式 UI。

核心架構建議如下：

1. 將 Wine 環境的生命週期明確分為 `missing → creating → ready → unhealthy → rebuilding`，不可再只靠 `.cyder-bootstrap-v1` 判斷健康。
2. 初始化、健康檢查、設定套用、遊戲啟動各自使用獨立 operation log；`last-launch.log` 不再承擔初始化診斷用途。
3. 從單一 `bottles/shared` 改為「一個遊戲 Profile 對應一個 bottle」。Profile 以執行檔的標準化路徑／security-scoped bookmark 等穩定 ID 識別，檔名只作顯示與 Wine `AppDefaults` 鍵值，不可作唯一 ID。
4. 建立兩層模板：`templates/pristine` 只完成 wineboot；`templates/recommended` 由 pristine clone 後套用 Cyder 共通元件與預設。一般 Profile 從 recommended 建立，特殊 Profile 可選 pristine 或 recipe 指定的基底。
5. APFS 複製明確使用 `cp -cR -p`（clonefile），而非假設 `cp -pr` 必然 CoW。若來源與目的地不在同一支援 clone 的檔案系統，允許退回一般 copy，但 UI 必須顯示空間與進度。
6. MSync／ESync 與 QoS 都視為 **bottle session 設定**。同一 bottle 的 wineserver 存活期間不可混用；不同 bottle 才能安全同時使用不同模式。
7. 能源模式是每 EXE 設定，UI 提供「標準」、「省電」兩個選項；內部分別對應 normal、background。BlueCG 量測顯示 utility 收益不明顯，因此不進入正式 UI；M1 系列明確標示為不建議使用省電模式。

## 2. 現況盤點

### 2.1 已具備

| 項目 | 現況 | 主要位置 |
|---|---|---|
| 分階段錯誤診斷 | v0.3 已有 session state、stage、operation log、錯誤碼與錯誤對話框 | `scripts/cyder_diagnostics.swift`、`scripts/cyder_app_main.swift` |
| 遊戲啟動 log | 每次建立獨立 `wine-launch` log，`last-launch.log` 為最近一次的 symlink | `runDirectWine()`、`cyder_run_wine_exe()` |
| bootstrap 失敗保存 | shell 的 `--bootstrap-only` 失敗會保存 `Logs/bootstrap-error.log`；Swift 另保存 session operation log | `scripts/cyder_launcher.sh` |
| 初始化進度 UI | 已有 indeterminate progress bar，可切換「準備執行元件／遊戲環境／套用設定」文字 | `CyderSetupPanel` |
| 初始化失敗對話框 | 子程序非 0 或 signal 時會顯示錯誤、stage、log tail，可開啟記錄位置 | `presentFailure()` |
| 進階設定 | 已有 MSync、ESync、Retina、DPI、字體、字體平滑及重設預設 | `CyderSettingsWindowController` |
| 設定持久化 | `settings.json` schema 1；Swift 與 shell 都可讀 | `CyderSettingsStore`、`cyder_load_saved_settings()` |
| Prefix | 固定使用 `~/Library/Application Support/Cyder/bottles/shared` | `CyderPaths`、`cyder_init_paths()` |
| Sync 互斥 | UI 互斥；launcher 以 MSync 優先 | `wineEnvironment()`、`cyder_run_wine_exe()` |

### 2.2 尚缺或行為不符需求

| 需求 | 缺口 |
|---|---|
| A1 wineboot log | 成功的 bootstrap 沒有固定 `last-bootstrap.log`；`bootstrap-error.log` 只保留最後一次失敗；wineboot、Mono、tar、顯示設定仍混在同一 bootstrap operation log。 |
| A1 Intel Mac 閃退 | 現有 Swift 能處理子程序非 0／signal，也能在下次啟動提示上一 session 未正常結束；但缺 wineboot 專屬錯誤碼、engine/CPU 資訊摘要與「wineboot 回傳成功但產物不完整」驗證。 |
| A2 重建 | 只有 engine 升級時內部呼叫 `cyder_reset_shared_prefix()`；沒有使用者入口、備份、復原或執行中保護。 |
| A3 啟動流程 | 直接開 Cyder 會先顯示進階設定，按「確認」才初始化；與「先準備成功再進主介面」相反。 |
| A3 每次健康檢查 | 目前只有 wine executable、engine 版本與 bootstrap marker；marker 存在但 registry／kernel32／wineserver 壞掉仍可能誤判 ready。 |
| A4 差異套用 | 每次確認都執行所有 `reg add/delete`，也固定重寫 BlueCG ddraw override 與全部字體 replacement。 |
| B 多遊戲 | 所有 EXE 共用 shared bottle；registry、元件與 wineserver session 互相影響。 |
| B2 per-EXE | 沒有 Profile、參數、環境變數或 exe 對應 UI。現有 `AppDefaults\\bluecg.exe` 只是單一硬編碼例外。 |
| C 能源模式 | 已完成 BlueCG 初步量測；每 EXE 可選標準（不包 taskpolicy）／省電（`taskpolicy -c background`）。每 bottle 的 wineserver session 隔離仍須隨 Profile 架構完善。 |

### 2.3 對舊版 log 問題的判定

舊版 `last-launch.log` 只有 `wine: could not load kernel32.dll, status c0000135`，確實可能無法判斷它來自初始化還是後續 EXE。現版的遊戲啟動與 bootstrap 已使用不同 operation log，因此「同一檔案被下一個 EXE 截斷覆蓋」已大致排除；現在應補的是可發現性與完整性，而不是再把所有輸出合併回單一 log。

建議固定索引：

```text
Logs/
  sessions/<session>.log
  operations/<timestamp>-wineboot.log
  operations/<timestamp>-bootstrap.log
  operations/<timestamp>-health-check.log
  operations/<timestamp>-settings-apply.log
  operations/<timestamp>-wine-launch.log
  last-wineboot.log -> operations/...
  last-bootstrap.log -> operations/...
  last-health-check.log -> operations/...
  last-launch.log -> operations/...
  last-error.json
```

每次操作都先建立新檔，完成後再以原子方式更新 `last-*` symlink。成功與失敗都保留，並依數量／日期輪替。

## 3. A：遊戲引擎初始化改進

### 3.1 wineboot 記錄與錯誤

方向可行。wineboot 應成為獨立 operation，不能只在 bootstrap 大階段中寫一行 stage。

建議流程：

1. 建立 staging bottle，不直接寫正式目錄。
2. 記錄 engine 版本、macOS、CPU architecture、Wine binary、prefix、命令與時間；路徑需套用既有隱私遮罩。
3. 執行 `wineboot -u`，保留 stdout、stderr、exit status、termination reason。
4. 等待 wineserver 完成，再檢查必要產物：`system.reg`、`user.reg`、`drive_c/windows/system32/kernel32.dll` 等。
5. 執行一次最小 probe，確認 Wine 能啟動 Windows 行程並回傳 0。
6. 全部成功才將 staging 原子 rename 為正式 bottle 並寫入 manifest／marker。
7. 任一步失敗都保留 staging 診斷資訊、顯示原生錯誤對話框，提供「重試」「開啟記錄」「重建環境」。

不要把 `c0000135` 單獨寫死為唯一判斷；它應是 log pattern 與使用者提示線索，真正成功條件仍是 exit status 加產物／probe 驗證。

### 3.2 Prefix 重建名稱與操作

一般使用者文案建議：

- 選單：**重建 Windows 遊戲環境…**
- 說明：**重新建立執行 Windows 遊戲所需的環境。遊戲檔案不會被刪除，但在此環境中安裝的 Windows 元件與自訂設定需要重新套用。**
- 技術詳細資訊才使用 Bottle／Prefix。

安全流程：

1. 偵測該 bottle 是否有 wineserver／EXE 執行中；有則禁止重建，或讓使用者明確選擇關閉。
2. 建立新 staging bottle並完整驗證。
3. 將舊 bottle rename 到 `Backups/<profile>-<timestamp>`。
4. 將 staging rename 成正式 bottle。
5. 重新套用 Profile recipe 與使用者設定，再做健康檢查。
6. 成功後保留一份限時備份；失敗則自動復原舊 bottle。

不建議先刪除舊 prefix 再建新的；Intel Mac 的原始問題若再次出現，使用者會同時失去可分析與可復原的環境。

### 3.3 開啟 Cyder 時先準備與檢查

此需求可行，且現有 progress panel、`ensureEnvironment()` 可重用；需要反轉 app lifecycle：

```text
開啟 Cyder.app
  → 靜態檢查 engine／template／manifest
  → 必要時建立或升級
  → prefix 未被使用時執行主動 health probe
  → 成功後顯示主視窗
  → 失敗則留在修復畫面，不進遊戲選單
```

每次啟動都做兩層檢查：

- 快速靜態檢查：檔案、版本、manifest、marker，應在數十毫秒內完成。
- 主動 probe：以目標 bottle 執行最小 Windows 命令；設定 timeout。若 bottle 已有遊戲執行，不啟動／關閉第二個 wineserver，只回報「環境使用中，略過完整檢查」。

不建議每次都跑 `wineboot -u`；它不是單純 read-only health check，會增加延遲，也可能修改 prefix。

### 3.4 只套用變更欄位

可行，建議把「已儲存」與「已套用」分開：

```json
{
  "schemaVersion": 2,
  "revision": 12,
  "desired": { "retinaMode": true, "dpi": 192 },
  "appliedByBottle": {
    "profile-id": {
      "revision": 12,
      "values": { "retinaMode": true, "dpi": 192 }
    }
  }
}
```

Apply planner 比較 desired 與該 bottle 的 last-applied 值，只產生必要操作。若某步失敗，不更新該欄位的 applied state，下次可重試。

勾選項文案建議：**重新套用所有設定（疑難排解）**。預設不勾選；只在 registry 被外部工具修改、狀態不一致或使用者除錯時使用。

第一版不用為每次確認先讀回整份 registry；讀回會慢且 Wine 的預設／缺值語意不完全等同 UI。以 desired/applied ledger 為主，完整重套用作修復機制。

## 4. B：多遊戲相容性

### 4.1 每遊戲 Bottle 與 APFS CoW

方向可行，也是解決 registry、Winetricks 元件、sync 與同時啟動衝突最乾淨的方案，但應從「每個 exe 檔名一個 bottle」修正為「每個遊戲 Profile 一個 bottle」。一個遊戲可能有 launcher 與真正遊戲 EXE，兩者通常應共享 bottle；不同資料夾也可能各有同名 `game.exe`。

建議目錄：

```text
~/Library/Application Support/Cyder/
  templates/
    pristine/<engine-id>/
    recommended/<engine-id>-<recipe-revision>/
  profiles/<profile-id>/profile.json
  bottles/<profile-id>/
  staging/
  backups/
```

建立順序：

1. 安裝／驗證 engine。
2. `pristine`：wineboot 完成、wineserver 已退出、通過 probe，未套 Cyder 遊戲特化。
3. `recommended`：從 pristine 以 `cp -cR -p` clone，安裝共通元件並套預設設定，通過 probe。
4. 新遊戲建立 Profile；依 recipe 從 recommended 或 pristine clone 到 staging。
5. 套用遊戲 recipe、驗證後原子 rename 到 `bottles/<profile-id>`。

限制需明確記錄：

- CoW 只保證初始共享實體 blocks；遊戲安裝、registry、cache 更新後仍會逐步增加空間。
- clone 通常要求同一支援 clonefile 的檔案系統。必須檢查 exit status，不能以耗時推測是否成功。
- 複製前模板不可有運行中的 wineserver；避免複製 socket／半寫入 registry 狀態。
- engine 升級不應直接刪除所有 Profile；以 manifest 標示需要 migration／rebuild，先提供備份。

### 4.2 Profile 與可執行檔規則

建議資料模型：

```json
{
  "schemaVersion": 1,
  "id": "uuid",
  "name": "皮卡丘排球",
  "primaryExecutable": {
    "bookmark": "base64-security-scoped-bookmark",
    "lastKnownPath": "/path/to/game.exe",
    "basename": "game.exe"
  },
  "executableRules": [
    {
      "basename": "game.exe",
      "arguments": [],
      "environment": {},
      "syncMode": "off"
    }
  ],
  "bottle": "profile-id",
  "recipe": "pikachu-volleyball@1",
  "powerMode": "normal"
}
```

規則：

- Profile 選擇依 bookmark／標準化完整路徑，不依 basename。
- Wine `AppDefaults` 仍只能依 Windows image name 使用時，才用 basename 寫 registry。
- 環境變數使用 key/value dictionary，命令列參數使用 string array；不可保存可直接交給 shell eval 的字串。
- UI 需顯示最後解析出的完整路徑，讓同名 EXE 可辨識。
- 每個 Profile 可包含多個 executable rules，共用 bottle 與已安裝元件。

### 4.3 已知遊戲 recipe

先把已知需求資料化，不要繼續硬編碼在 `cyder-apply-settings.sh`：

| Recipe | 建議設定／元件 | 注意事項 |
|---|---|---|
| Age of Empires II | Retina off | DPI、renderer 仍需實機矩陣確認。 |
| Metal Slug／越南大戰 | DPI 96 | 避免畫面超出螢幕；Retina 需獨立驗證。 |
| Richman 4／大富翁 4 | cnc-ddraw | 不能只寫 DLL override；必須確認 `ddraw.dll` 的合法來源、版本與放置位置，並做安裝／移除流程。 |
| Pikachu Volleyball | MSync off、ESync off | 已有專案實測文件；不同 sync 必須由獨立 bottle session 隔離。 |
| BlueCG／水藍魔力 | 建議 Retina on、DPI 192；不用 cnc-ddraw；保留現有 BlueCG ddraw 規則的遷移測試 | A6 engine 已針對 Retina resize 驗證。 |
| LF2 | `vcrun2005`、`wmp9`、`quartz`、`devenum`、`vb6run` | Winetricks 動作需 pin 版本／checksum、可重入、可離線或明確提示下載；wmp9 另需確認授權與目前 engine 可用性。 |

recipe 應包含 `id`、`revision`、適用 engine、base template、registry patch、元件 installer、DLL、sync、顯示設定與驗收 probe。UI 可先提供「Cyder 建議」preset，再允許使用者覆寫；recipe 更新不應在未確認時自動改壞已可運作的 bottle。

### 4.4 MSync／ESync 與同時啟動

同一 prefix 的行程共享 wineserver，因此 sync 不能可靠地當成單一 EXE 的自由環境變數。現有 CX26 binary 可直接看到：

```text
Server is running with WINEMSYNC but this process is not,
please enable WINEMSYNC or restart wineserver.
```

因此設計規則是：

1. `syncMode` 的有效作用域為 bottle session。
2. 第一個啟動該 bottle 的行程決定 session mode。
3. 之後同 bottle 的 EXE 要求相同 mode 才允許加入。
4. 若要求不同，顯示「此遊戲環境正以另一種同步模式執行」，提供關閉該 bottle 全部遊戲後重開，或建立獨立 Profile／Bottle。
5. 不同 bottle 有不同 wineserver，可同時使用不同 sync。

即使 ESync 的實作細節與 MSync 不同，也應採相同保守規則，避免 server/client mode 不一致。

## 5. C：能源模式

### 5.1 「標準／省電」的技術對應

BlueCG 定點量測中，`utility` 與標準模式的 Wine CPU 能耗接近；`background` 則使 Wine CPU 能耗約降低九成，因此正式 UI 只保留兩個可明確區分的選項。這是單一遊戲與場景的 process-level 結果，不等於整機耗電或續航也改善九成。

| UI 選項 | 內部模式 | 啟動方式 | 定位 |
|---|---|---|---|
| 標準 | `normal` | 不包 `taskpolicy` | 一般遊玩，維持目前行為 |
| 省電 | `background` | `taskpolicy -c background` | 掛機或低互動情境；可能降低能耗，但畫面與操作可能變慢 |

正式啟動命令：

```bash
taskpolicy -c background \
  /usr/bin/arch -x86_64 /path/to/wine game.exe
```

macOS `taskpolicy` 文件顯示子行程會繼承 policy，而 `-c` 支援 `utility`、`background`、`maintenance`。沒有 `user-interactive` 選項；標準互動模式應是不包 taskpolicy 的原始啟動方式。

建議 UI：

- **標準**：目前行為，適合遊玩。
- **省電**：`taskpolicy -c background`，適合掛機或低互動情境；明確警告遊戲啟動、載入、畫面更新與操作可能變慢，並註明量測結果不保證可直接換算成整機續航。

### 5.2 限制與量測

`taskpolicy` 只調整 CPU／I/O 排程，不能保證遊戲降低 FPS 或 GPU 使用率。若遊戲仍無限制重畫，真正耗電來源可能不會顯著下降；因此「省電」是產品模式名稱，不代表每個遊戲都有固定節能比例。後續可研究遊戲內 FPS 限制、renderer present pacing 或最小化行為，但不可在未驗證時宣稱實際節能數值。

QoS 也與 wineserver 有 session 問題：若 wineserver 已由標準模式啟動，後開的 background client 不代表既有 server 一併改變。第一版規則與 sync 相同：power mode 在 bottle 無行程時決定，session 存活期間不可切換；切換需關閉該 bottle 全部 EXE 後重開。

原型驗收至少記錄：

- 相同場景 10–15 分鐘的 CPU、Energy Impact、GPU、平均／低百分位 frame time。
- 網路連線、計時器、音訊與掛機功能是否持續。
- 正常、utility、background 三組比較（已完成；正式 UI 淘汰 utility）。
- Intel 與 Apple Silicon 各一台；Intel 是本輪主要風險機型。

量測已確認 utility 節能差異不明顯，因此不提供該模式。background 作為「省電」選項，仍須持續針對不同遊戲、機型、畫面、音訊與網路掛機穩定性回歸。

## 6. 任務切分

### T00 — Swift 檔案拆分與測試入口（先行）

**目的**：降低多 Agent 同時修改 `cyder_app_main.swift` 的衝突；行為不變。

**範圍**：

- 拆出 `CyderPaths`、Settings model/store、Settings UI、Environment service、Launch service、AppDelegate。
- 更新 `create-cyder-app.sh` 的 Swift sources。
- 建立可在無 UI 狀況測試 state／planner／profile model 的 Swift test harness。

**驗收**：Universal build 通過；既有 shell／diagnostics 測試通過；手動流程與 v0.3 相同。

**依賴**：無。  
**建議檔案所有權**：只處理 Swift 結構與 build script，不改功能。

### T01 — wineboot／bootstrap operation log 與錯誤分類

**目的**：讓 Intel Mac 初始化失敗可還原完整現場並一定顯示錯誤。

**範圍**：

- wineboot 獨立 log、`last-wineboot.log`、`last-bootstrap.log`。
- 保存成功與失敗、原子更新 symlink、rotation。
- 增加 wineboot exit／signal／timeout／產物缺失錯誤碼。
- 錯誤對話框直接指向該 operation log。
- log 加入 engine、OS、CPU architecture，但維持 home path redaction。

**驗收**：模擬 `c0000135`、exit 1、signal、timeout、exit 0 但缺 `system.reg`，都會保留 log 並顯示對話框；後續遊戲 launch 不會改寫 wineboot log。

**依賴**：T00 可並行尾段整合。  
**主要檔案**：diagnostics、launcher/common shell、diagnostics tests。

### T02 — Prefix lifecycle backend、健康檢查與安全重建

**目的**：建立狀態機、staging、probe、backup／rollback。

**範圍**：

- 新增 prefix manager，提供 `status`、`create`、`probe`、`rebuild`、`rollback`。
- manifest 取代單一 marker 成為主要狀態來源，暫時相容舊 marker。
- active wineserver 防護與 timeout。
- 所有新 prefix 在 staging 完成後才原子切換。

**驗收**：中途失敗不留下 ready marker；重建失敗會復原；有遊戲執行時不破壞 bottle；損毀 marker／registry／kernel32 可被偵測。

**依賴**：T01 的 operation logging contract。  
**主要檔案**：建議新增 `cyder-prefix-manager.sh` 及獨立 tests，減少與其他 Agent 衝突。

### T03 — App 啟動流程與「重建 Windows 遊戲環境」UI

**目的**：直接開 Cyder 時先準備／檢查，成功才顯示主介面。

**範圍**：

- 啟動 state machine 與 progress 文案。
- 失敗修復畫面：「重試」「重建」「開啟記錄」。
- 進階選單加入「重建 Windows 遊戲環境…」及完整風險說明。
- 不再要求第一次先進設定並按確認才初始化。

**驗收**：fresh install、自動升級、healthy、corrupt、active-game 五條流程；UI 不阻塞主執行緒；失敗時不進 EXE 選單。

**依賴**：T00、T02。  
**主要檔案**：App lifecycle／main window／prefix service Swift files。

### T04 — 設定 schema 2、diff apply planner 與完整重套用

**目的**：確認時只寫變動欄位。

**範圍**：

- desired／applied ledger 與 schema 1 migration。
- 每欄位獨立、可重入的 registry operation。
- `--apply-fields` 或等價的結構化介面；禁止 eval。
- UI 加入「重新套用所有設定（疑難排解）」勾選項。
- 移除每次都硬編碼重寫 BlueCG override 的行為，交給 recipe。

**驗收**：只改 DPI 時不寫 Retina／字體／ddraw；部分失敗只保留未套用欄位；force 模式完整重寫；未變更按確認不啟動 Wine。

**依賴**：T00；資料模型需預留 T05 的 `appliedByBottle`。  
**主要檔案**：Settings model/store、apply planner、`cyder-apply-settings.sh`、settings tests。

### T05 — APFS template、Profile store 與 per-game bottle backend

**目的**：落實 pristine／recommended 模板和每遊戲隔離。

**範圍**：

- Profile ID、bookmark／path identity、multi-executable rules。
- template manifest 與 engine/recipe revision。
- `cp -cR -p` staging clone、fallback copy、空間提示資料。
- shared bottle migration：第一版可匯入成一個「舊版共用環境」Profile，不自動拆分。

**驗收**：同名不同路徑 EXE 不撞 Profile；clone 中斷不留下正式 bottle；不同 bottle registry 不互相污染；非 APFS fallback 正確。

**依賴**：T02 的 lifecycle primitives；schema 與 T04 對齊。  
**主要檔案**：新增 Profile／Bottle service 與 tests。

### T06 — per-game 設定 UI 與 launch routing

**目的**：進階設定可選 Profile／EXE，啟動時套用對應 bottle、env、args。

**範圍**：

- 設定視窗新增「遊戲」分頁與 Profile selector。
- DPI、sync、Retina、字體、環境變數、參數的 Profile override。
- 啟動依 bookmark／標準化路徑找 Profile，解析 args array 與 env dictionary。
- 未建立 Profile 的 EXE 顯示建立流程，不靜默塞回 shared bottle。

**驗收**：同名 EXE、移動後 bookmark、含空白／Unicode 路徑、參數含空白與引號、非法 env key；皆不經 shell eval。

**依賴**：T03、T04、T05。  
**主要檔案**：Settings/Profile UI、launch service。

### T07 — 相容性 recipe 與元件安裝框架

**目的**：把已知遊戲需求資料化並可測試。

**範圍**：

- recipe schema、revision、能力／engine gate。
- 先加入 AoE II、Metal Slug、Pikachu Volleyball、BlueCG 的純設定 recipe。
- cnc-ddraw 來源／版本／安裝位置 spike。
- LF2 Winetricks 元件的下載、授權、checksum、離線與可重入 spike；未釐清前不要標示為一鍵完成。

**驗收**：recipe 套用只影響目標 bottle；覆寫與恢復預設可預測；缺元件時清楚失敗，不留下 applied revision。

**依賴**：T04、T05；可先獨立完成 schema／research。  
**主要檔案**：建議新增 `recipes/`、installer scripts、fixture tests。

### T08 — Sync session guard 與並行啟動

**目的**：避免同一 wineserver 混用 sync。

**範圍**：

- bottle runtime state／lock，記錄本次 session 的 engine、sync、power mode。
- 啟動前比對；衝突時阻擋並提供關閉／建立獨立 Profile。
- 不同 bottle 並行測試。

**驗收**：同 bottle same-mode 可並行；different-mode 被阻擋；不同 bottle different-mode 可同時啟動；crash 後 stale lock 可依 wineserver socket 安全清除。

**依賴**：T05、T06。  
**主要檔案**：launch/runtime-session service 與 tests。

### T09 — `taskpolicy` 省電原型與量測報告

**目的**：取得能源模式是否有實際收益及可接受體驗的證據，不承諾固定節能比例。

**範圍**：

- benchmark 保留 normal／utility／background 的比較；正式 launch service 與 UI 只支援 normal／background，文案固定為「標準／省電」。
- 確保 policy 套在會建立 wineserver 的最外層 process。
- BlueCG 掛機場景量測腳本與報告。
- 記錄 Intel／Apple Silicon 差異、畫面、音訊、網路與計時器回歸。

**驗收**：三模式可重現量測；正式 UI 淘汰收益不明顯的 utility；background 的畫面、音訊、網路掛機結果通過最低門檻才顯示「省電」；同 bottle session 切換會被阻擋。

**依賴**：可先做 CLI spike；正式接 UI 依賴 T08。  
**主要檔案**：獨立 benchmark script/report，最後才改 launch service。

### T10 — 整合、migration 與發布驗收

**目的**：處理跨任務行為與 v0.3 使用者升級。

**範圍**：

- schema 1、shared bottle、舊 marker、舊 logs migration。
- Intel fresh install／rebuild；Apple Silicon Rosetta；多 Profile 並行。
- 文件、錯誤碼、release notes、診斷資訊隱私檢查。

**驗收**：完整自動測試、Universal app build、兩種 CPU 實機 smoke test；舊 shared bottle 不會無提示遭刪除。

**依賴**：T01–T09 中要進本版的項目。

## 7. 建議執行波次與 Agent 並行方式

```text
Wave 1: T00 ───────────────┐
        T01 ──┐            │
        T09 CLI spike      │
              ▼            ▼
Wave 2:      T02          T04
              │            │
              ▼            ▼
Wave 3:      T03          T05
                           │
                    ┌──────┼──────┐
                    ▼      ▼      ▼
Wave 4:            T06    T07    T08
                                  │
                                  ▼
Wave 5:                    T09 UI + T10
```

多 Agent 同時工作時的原則：

- T00 完成前，避免兩個 Agent 同改 `cyder_app_main.swift`。
- 每個任務優先新增獨立 service／script／test，再由單一 integration Agent 接線。
- T04 與 T05 必須先凍結 schema contract；T06 不自行發明第二套 Profile 格式。
- T02 是 prefix 寫入的唯一權威；其他任務不可直接 `rm -rf` bottle。
- T08 是 runtime session 判斷的唯一權威；T06／T09 不各自實作 wineserver 衝突規則。

## 8. 今日建議範圍

若今天要取得可合併且風險最低的成果，建議目標是：

1. T00 Swift 拆分。
2. T01 wineboot／bootstrap log 與錯誤測試。
3. T02 prefix manager 的 `status/create/probe`，先不開放 destructive rebuild UI。
4. T04 完成 schema／planner contract 與「只改 DPI」的最小垂直切片。
5. T09 只做 CLI prototype 與量測表，不進正式 UI。

T05–T08 屬第二波；它們需要先把 prefix lifecycle 與 settings contract 穩定下來，否則多個 Agent 很容易在 shared bottle、Profile schema、wineserver 規則上做出互不相容的實作。

## 9. 最終驗收總表

- wineboot 成功／失敗 log 永不被遊戲啟動覆寫。
- Intel Mac wineboot exit、signal、timeout、產物損毀都會出現可操作的錯誤對話框。
- 每次開啟 Cyder 都會做快速檢查；必要且安全時做主動 probe；成功才顯示主介面。
- 重建採 staging、backup、atomic switch、rollback，不先刪舊環境。
- 未變更的進階設定不執行 registry command；force reapply 可完整修復。
- 每個遊戲 Profile 有獨立 bottle；同名 EXE 不撞設定。
- APFS clone 明確使用 clonefile 路徑，非 APFS fallback 有測試與提示。
- 同 bottle 不允許混用 MSync／ESync 或 power mode；不同 bottle 可並行。
- 已知遊戲需求由 versioned recipe 表達，不再硬編碼 BlueCG 單一例外。
- `utility` 因量測收益不明顯，不進入正式 UI。
- `background` 必須通過畫面、音訊與掛機穩定性門檻，才標示為「省電」。
