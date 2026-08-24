# Rosetta 知情同意安裝（Swift）

日期：2026-08-25  
狀態：draft（待實作）  
範圍：Apple Silicon 上缺 Rosetta 2 時的偵測、使用者同意、安裝與錯誤呈現。

相關：
- `scripts/cyder-ensure-rosetta.sh`
- `scripts/cyder_launcher.sh`（`rosetta-check`）
- `scripts/cyder_app_main.swift`（`ensureEnvironment`）
- `scripts/cyder_launch_support.swift`（`CyderSetupPanel` / `runFrontmostAlert`）
- `tests/test-cyder-rosetta.sh`
- 使用者回報：`CYD-ENG-003` 實為 `rosetta-check` 失敗（GUI 下無 TTY 的
  `softwareupdate --install-rosetta` 授權卡住）

## 問題

1. GUI 路徑直接跑 `softwareupdate --install-rosetta`（不帶 `--agree-to-license`）時，
   macOS 要求終端輸入 `A` 同意；背景程序無法完成，失敗被包裝成 `CYD-ENG-003`。
2. 系統原生／Launch Services 的 Rosetta 安裝提示可能伴隨「macOS 即將不支援」類訊息，
   對使用者不友善，也不利於 Cyder 說明「為何需要」。
3. 產品先前禁止 `--agree-to-license`；改為：**僅在 Cyder 對話框知情同意之後**才允許。

## 目標

1. 缺 Rosetta 時由 **Swift** 顯示說明對話框；使用者同意後才安裝。
2. 安裝期間顯示既有 **`CyderSetupPanel`** 不定進度列；成功後才繼續
   engine／graphics／bootstrap。
3. 拒絕或安裝失敗 → 專用錯誤碼 **`CYD-ROS-001`**，不再誤報為引擎解壓失敗。
4. GUI 下 bash **不再代為安裝** Rosetta（只檢查）。

## 非目標

- 不觸發系統原生 Rosetta 安裝視窗／x86 helper `.app`。
- 不實作可定量進度百分比（`softwareupdate` 無穩定進度 API；用不定進度列即可）。
- 不改變 Intel Mac 行為（無需 Rosetta）。
- 不在此規格處理 App Translocation；可另文件提醒移至「應用程式」。

## 決策摘要

| 項目 | 決定 |
|------|------|
| UI 擁有者 | **A：Swift**（同意 + 進度 + 錯誤） |
| 同意後安裝命令 | `/usr/sbin/softwareupdate --install-rosetta --agree-to-license` |
| 進度 UI | 既有 `CyderSetupPanel`（indeterminate bar） |
| 拒絕／失敗錯誤碼 | `CYD-ROS-001`，stage 建議 `rosetta-check` 或對等 |
| bash（`CYDER_GUI=1`） | 僅 `cyder_rosetta_is_installed`；缺則失敗，**不安裝** |
| CLI／非 GUI | 可保留互動式 `softwareupdate --install-rosetta`（不帶 agree），或要求先裝好 |
| 測試契約 | 禁止「未經 Swift 同意路徑」默默 agree；GUI 安裝路徑必須經同意後才帶 agree |

## 使用者流程

```
ensureEnvironment 開始（Apple Silicon）
 │
 ├─ Rosetta 已安裝？ ──是──▶ 既有 engine / graphics / bootstrap
 │
 └─ 否
      NSAlert（說明 + 〔安裝〕〔取消〕）
      ├─ 取消 ──▶ CYD-ROS-001，結束
      └─ 安裝
           CyderSetupPanel：「正在安裝 Rosetta 2…」
           softwareupdate --install-rosetta --agree-to-license
           驗證 pkgutil / arch -x86_64 true
           ├─ 成功 ──▶ 關閉 panel，繼續 ensureEnvironment
           └─ 失敗 ──▶ 關閉 panel，CYD-ROS-001
```

### 對話框文案（建議）

- **標題**：需要安裝 Rosetta 2
- **內文**：Rosetta 2 是 Apple 提供的官方元件，讓 Apple Silicon Mac 能執行 x86_64
  程式。Cyder 的遊戲執行元件需要它才能運作。安裝時會代表你同意 Apple 的軟體授權條款。
- **按鈕**：〔安裝〕（預設）／〔取消〕

實作文案可微調，但必須包含：官方元件、用途說明、同意後會代為同意授權。

### 錯誤摘要（建議）

- 取消：使用者取消安裝 Rosetta 2。
- 安裝／驗證失敗：無法安裝或完成 Rosetta 2；請稍後再試或從「終端機」手動安裝。

## 架構

### Swift

在 `ensureEnvironment` **最前面**（`needsEngine` 解壓之前）：

1. 若非 Apple Silicon → skip。
2. 若已安裝 → skip。
3. 否則跑上述同意 → 進度 → 安裝 → 驗證。
4. 失敗回傳 `CyderFailure(code: "CYD-ROS-001", …)`；`presentFailure` 沿用現有 alert 路徑。

安裝應在背景佇列執行，主執行緒只更新 UI；`ensureEnvironment` 既有同步／semaphore
模式可沿用（與 engine-install 一致）。

### bash

- `cyder_rosetta_install`：拆成「互動安裝」與「同意後安裝」或由呼叫端傳旗標；
  **GUI 預設不安裝**。
- `CYDER_GUI=1` 且缺 Rosetta：`cyder_ensure_rosetta` 回傳失敗並記錄明確訊息
  （防御：Swift 漏檢時不要再卡住 TTY）。
- `tests/test-cyder-rosetta.sh`：更新契約——不再全域禁止字串 `--agree-to-license`；
  改為斷言 GUI ensure 路徑不安裝／不帶 agree，且文件或 helper 註明 agree 僅由
  Swift 知情同意後呼叫。

### 與既有文件

- `docs/releases/v0.9.0*.md` 曾寫「Rosetta 改由 macOS 原生流程」——後續 release notes
  應改述為 Cyder 知情同意 + `--agree-to-license`（實作時更新當版 release note，
  不必改寫舊版歷史除非需要勘誤）。

## 錯誤處理

| 情況 | 結果 |
|------|------|
| 使用者按取消 | `CYD-ROS-001`，不呼叫 softwareupdate |
| softwareupdate 非 0 | `CYD-ROS-001`，保留 operation log／stderr |
| 命令成功但驗證仍失敗 | `CYD-ROS-001`（安裝未完成） |
| Intel | 不進入此流程 |
| 已安裝 | 不顯示對話框 |

## 測試計畫

1. **腳本**：`test-cyder-rosetta.sh` 反映新契約（GUI 不安裝；agree 僅允許在明確的
   同意後安裝 helper／文件化入口）。
2. **手動（Apple Silicon、暫時無法卸 Rosetta 時）**：至少驗證「已安裝 → 不快取對話框」；
   若有測試機可卸 Rosetta：同意 → 進度 → 成功後能進引擎；取消 → `CYD-ROS-001`。
3. **回歸**：有 Rosetta 的機器開偏好設定／啟動遊戲，路徑與時間應與今日相當（多一次
   便宜的已安裝檢查）。

## 實作順序（概要）

1. Swift：偵測 + alert + SetupPanel + softwareupdate + `CYD-ROS-001`
2. bash：GUI 改為 check-only；調整錯誤訊息
3. 測試與 release note 契約更新

## 成功標準

- 缺 Rosetta 的 GUI 使用者會先看到 Cyder 說明，不會卡在終端 `Type A`，也不會因
  Rosetta 看到誤導的 `CYD-ENG-003`。
- 同意後安裝成功才繼續；不同意或失敗明確失敗。
- 無「未經對話框同意」的 `--agree-to-license` 安裝路徑（CLI 互動安裝除外）。
