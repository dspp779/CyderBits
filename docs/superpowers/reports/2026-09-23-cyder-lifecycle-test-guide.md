# Cyder lifecycle 隔離測試版：建置與執行

目前仍在整合驗收中；這份文件是可重現入口，不是全面 Wine／NGS 相容性聲明。逐項結果與未驗證範圍見 [證據報告](2026-09-21-cyder-lifecycle-evidence.md)。

## 建置

在 `/Users/jjc/ogom` 的任務分支執行：

```bash
bash scripts/build-cyder-lifecycle-test.sh
```

需要已設定的 Xcode／SDK、系統 `/usr/bin/python3`，以及 repo 設定所指向的引擎 archive／圖形 payload。腳本使用既有 app builder，固定 ad-hoc 簽名、原生 Swift、arm64 + x86_64；主機 Python 不依賴 x86 Homebrew。它不建置 Wine 引擎、不下載或安裝 Rosetta、不啟動 app、不發布。

每次新建 `/private/tmp/cyder-lifecycle.XXXXXX`，不接受既有輸出目錄，因此不覆蓋先前 app 或正式安裝。成功時印出 app、identity.json、manifest.json 路徑；失敗保留 build.log，不能把沒有 verified 完成檔的目錄當成通過。

輸出包含：

- `build/Cyder.app`：已重簽且核對雙架構的測試 app。
- `support/`、`runtime/`：私有測試資料，wrapper 已設定 CYDER_SUPPORT、CYDER_RUNTIME_ROOT；不共用正式資料。
- `identity.json`：隨機 bundle ID 及確切 app／資料路徑。
- `inputs.json`：Swift 編譯輸入、主要 lifecycle shell 與兩支建置腳本的 SHA256。
- `manifest.json`：上述輸入、包內關鍵 shell、wrapper、Swift binary、Info.plist 的 SHA256；不是所有圖形／引擎 payload 的完整供應鏈 manifest。
- `build.log`、`sign.log`、`verified`：建置、簽名核對及最後完成標記。

manifest 的 sourceHEAD 僅記錄當時 Git HEAD；若在含本任務未提交修改時建置，不能把它當成 clean-tree 證明。來源 bytes 以 inputs 的 hash 為準，builder 會在建置前後核對沒有中途變更。

## 本輪產物及驗證

C34 目前產物：`/private/tmp/cyder-lifecycle.pNTDsa/build/Cyder.app`。C32 雖通過簽名及來源驗證，但其測試 bundle ID 過長，使 sentinel socket 路徑超過 Darwin 上限；不應再使用 C32 包作 GUI 驗收。新 builder 使用短識別碼並檢查通訊路徑長度，保留舊產物作失敗證據。

可用以下命令複核成功包（不啟動 app）：

```bash
codesign --verify --deep --strict --verbose=2 /private/tmp/cyder-lifecycle.pNTDsa/build/Cyder.app
lipo /private/tmp/cyder-lifecycle.pNTDsa/build/Cyder.app/Contents/MacOS/CyderSwift -verify_arch arm64 x86_64
cat /private/tmp/cyder-lifecycle.pNTDsa/identity.json
cat /private/tmp/cyder-lifecycle.pNTDsa/verified
```

要開啟這個已隔離的測試包：

```bash
open /private/tmp/cyder-lifecycle.pNTDsa/build/Cyder.app
```

重新建置時使用新輸出所印出的路徑，不沿用上述範例。不要搬到 Applications 或替换正式 Cyder。首次畫面應可先使用遊戲庫；環境準備是獨立操作。

2026-09-23 沙箱外的 `/usr/bin/arch -x86_64 /usr/bin/true` 失敗，Rosetta receipt 亦不存在，因此目前未把本包標為真實 Wine 可執行。若需 Wine 實測，先確認主機可執行 x86 系統程式，再在這個 app 的獨立環境內操作；此建置腳本不代替使用者接受系統軟體授權。既有 CD2／其他測試 prefix 也不會被此新包自動帶入。

## 不執行 Wine 的回歸入口

以下均使用正式程式路徑與測試臨時資料；UI harness 需要可用的 macOS 桌面 session。缺少完成檔或因 AppKit session 限制提前退出時，必須記為未通過，不能只看外層 shell exit。

```bash
bash tests/test-cyder-launch-context.sh
bash tests/test-cyder-setup-progress.sh
bash tests/test-cyder-open-files-lifecycle.sh
bash tests/test-cyder-settings-access.sh
bash tests/test-cyder-bootstrap-timing.sh
bash tests/test-cyder-library-loader.sh
bash tests/test-cyder-app-integration.sh
CYDER_MENU_SAMPLES=/private/tmp/cyder-menu-callback-samples.csv bash tests/test-cyder-menu-responsiveness.sh
```

menu 測試的 30 筆數據是 callback-cycle 代理指標，不是真正滑鼠點擊至畫面呈現的延遲。library 測試使用實際 AppKit 控制與正式 loader，但未執行完整 app delegate，也未操作 Wine 視窗。C32 原始樣本見 [CSV](2026-09-23-menu-callback-C32.csv)；其他生命周期／journal／owner／環境校準測試及既有真實操作見證據報告各批次，不以這份短清單取代完整 V01–V14 驗收。

C33 新增的 app integration 測試呼叫正式 CyderMain.main() 與完整 delegate，驗證設定／要求／遊戲庫、reopen、三種退出來源、ownership 失敗唯讀 UI、第二實例 socket 轉送與歷史 queued/dispatching 不重播。它是臨時最小 bundle 內的事件重放，不是實際 CUA 點擊、鍵盤 Command-Q 或最終引擎包實測。可設定 CYDER_APP_INTEGRATION_ARTIFACTS 保存完成檔、日誌及 durable state。當前 CUA 綁定工具 timeout、主機 Rosetta 不可用，相關限制仍適用。

C34 遊戲庫回歸另含 Finder 查詢／捷徑安裝的受阻與晚到測試，以及輸出 128 KiB 錯誤的自建本機 helper。測試不實際開 Finder、不写入使用者 Applications；其通過不等於已完成所有診斷 I/O 與整體回應性驗收。
