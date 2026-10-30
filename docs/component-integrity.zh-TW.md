# 執行元件清單與唯讀診斷（Issue #12 / P0-02）

本階段只檢查 Cyder 隨附的 Wine、DXVK、DXMT。診斷不執行被檢查的二進位、不啟動 Wine、不寫入 prefix、registry、遊戲、元件或設定，也不下載、移除、重新簽署或修復檔案。既有安裝流程中的解壓、簽署與圖形連結行為不因本功能改變。

## 已實作的路徑

- `build-component-manifests.rb` 在 App 打包、最終簽章之前，串流讀取已通過封存檔 SHA-256 比對的實際 payload，產生 `Contents/Resources/component-manifests/{engine,dxvk,dxmt}.json` 及 `index.json`。不重新打包引擎，也不依賴開發機已安裝的 runtime。
- 每個普通檔案記錄相對路徑、大小、SHA-256、格式（Mach-O / PE / data）、架構、簽章政策及是否屬於關鍵項目；元件來源記錄名稱、版本、封存檔名與封存檔 SHA-256。連結記錄路徑、種類、目標，不把連結當作普通檔案。
- index 綁定各份清單的 SHA-256 與來源；**信任來源是正式 App 的資源簽章與發行者約束，不是 runtime 旁的 checksum／安裝 marker**。執行時先驗證系統簽章服務、App 的 deep/strict 簽章，再由 `codesign -R` 執行 Apple anchor、Developer ID Application 憑證種類及 Team ID `3U9565WWM2` 的 requirement。不解析可能含檔名的顯示文字來判定發行者。
- ad-hoc／開發版不能建立正式發行者信任，顯示「無法確認」。不提供環境變數或 CLI 參數繞過發行者驗證。正式版仍需要發行流程簽署；清單不能彌補不可信的建置輸入或被入侵的發行環境。
- 原有 engine／graphics 安裝或更新完成後呼叫完整檢查；每次最終遊戲交接前呼叫關鍵檢查。檢查失敗會回傳診斷與非零 CLI 退出碼；目前啟動 hook 只記錄摘要，不阻擋啟動、不觸發修復。未攜帶清單的舊版／開發 payload 不由新 hook 處理。
- 「偏好設定 → 除錯 → 檢查執行元件…」提供獨立的背景完整檢查視窗，可取消、重新檢查。結果只存在記憶體；視窗限制報告大小及顯示差異數量，忽略取消／舊工作延遲回覆。程序 owner 只管理本次診斷 observer，不清理遊戲程序。

## 檢查範圍與判定

關鍵檢查涵蓋 engine 版本／來源描述、Wine 入口與其連結目標、wineserver、ntdll、kernel32/kernelbase、winemac，以及 DXVK/DXMT 的 d3d11、dxgi、winemetal。完整檢查走訪全部清單項目；不遞迴掃描遊戲目錄，也不把每次啟動變成整個 runtime 的深度掃描。

引擎內的 `lib/dxvk`、`lib/dxmt` 由獨立版本化 graphics 清單負責；安裝用 `.cyder-*` marker、tar 的 AppleDouble 中繼資料不作為 payload 基準。MoltenVK `.real` 連結允許現有兩個受支援目標，兩份實體檔仍各自接受雜湊檢查。硬連結依其實際內容建立獨立路徑項目。符號連結本身比對目標；普通檔案及其父目錄不得以連結跳到別處讀取。讀取與驗證前後檢查檔案身分／修改狀態；這是當下證據，不能消除檢查後再被更動的競態。

| 結果 | 意義 |
|---|---|
| `ok` | 本次範圍內的清單項目符合預期；不代表遊戲驗收或防惡意程式保證 |
| `missing` | 清單檔案或安裝目錄缺少；不推定誰刪除了它 |
| `content_mismatch` | 大小、內容雜湊、格式、架構或連結目標與清單不同 |
| `source_mismatch` | 清單 digest／來源不符，或 App 的資源／程式簽章不完整 |
| `signature_invalid` | 內容符合清單，但 Mach-O 的簽章驗證回報無效；缺少簽章另附 `signature_not_present` 原因 |
| `unknown` | 發行者未驗證、清單未隨附、服務不可用、權限／讀取問題、檔案讀取中變更、逾時、取消或輸出不完整 |

Mach-O 使用 `codesign --verify --strict`；此階段不把所有葉節點強制改成 Developer ID，也不改動現有簽章。PE 與一般資料檔不要求 macOS 簽章或 Authenticode：合法未簽署 Windows DLL 仍可符合清單。沒有防毒隔離證據時，UI 不使用「遭防毒移除」的判定。

檢查對象是清單內的必要元件，不檢測所有額外未列入清單的檔案、不驗證遊戲 DLL、第三方 GPTK/D3DMetal、載入時實際選擇的 DLL 或執行中的記憶體，也不作為安全啟動閘門。這些不應由「符合清單」推論已通過。

## 時間與負載預算

- 啟動關鍵檢查：整體 deadline 5 秒，包含發行者驗證；不使用 runtime 旁的成功快取跳過檢查。
- 安裝後／手動完整檢查：deadline 60 秒；CLI 可指定最多 300 秒。每個內容讀取區塊與 metadata 子程序都檢查單調時鐘。metadata 子程序逾時時只終止自己擁有的 child。
- 視窗外層另有預算加 1 秒的 observer deadline，逾時立即顯示無法確認，不等待 pipe 關閉；取消也立即更新 UI。底層特殊檔案系統的不可中斷系統呼叫不保證在期限內結束；因此視窗有獨立觀察期限，普通檔案讀取拒絕 FIFO 等特殊檔案。
- 2026-10-30，本機臨時解壓副本（CX26.3.0-W11-Cyder012，正常 macOS 信任服務）：關鍵檢查 16 / 1,817 項，讀取 12,716,113 bytes，85 ms；完整檢查 1,817 項，442,481,193 bytes，2,374 ms，皆符合清單。這是引擎單體測量，不含正式 App 發行者驗證，不代表不同磁碟／機型或端到端啟動時間保證。新增版本／大量元件必須重新測量；逾時仍是 unknown。

實際 graphics 副本對照：DXVK 1.10.3 關鍵／完整檢查為 5／15 項，6／14 ms，皆符合清單。DXMT 0.80 為 8／13 項，34／39 ms；內容雜湊皆相符，但原始 `x86_64-unix/winemetal.so` 未簽署（另以系統 codesign 確認 `code object is not signed at all`），因此現行 Mach-O `verify` 政策回報 `signature_invalid`，並明示缺少簽章。這不是安裝後改檔或防毒刪除證據。本階段採保守驗證，不默默放寬政策或補簽；此葉節點是否需要明確的上游未簽例外／發佈時簽署，留待 Issue #12 的 P1-02 政策處理。

後續來源調查已確認這個檔案與新下載的官方原件完全相同、上游原本就未簽署；詳見 [DXMT 簽章來源與政策評估](dxmt-winemetal-signing-audit.zh-TW.md)。本次調查沒有修改目前保守的診斷政策或補簽。

## 離線回歸

```bash
/usr/bin/ruby tests/test-cyder-component-integrity.rb
bash tests/test-cyder-component-hooks.sh
bash tests/test-cyder-component-diagnostics.sh
bash tests/test-cyder-ensure-graphics.sh
bash tests/test-cyder-engine-tarball.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-engine-version.sh
bash tests/test-cyder-maplestory-scrolling.sh
bash tests/test-cyder-scrolling-launch.sh
bash tests/test-cyder-game-launch-settings.sh
bash tests/test-cyder-app-integration.sh
```

Ruby fixtures 涵蓋正常／缺檔／改檔／來源與清單雜湊不符、Mach-O 簽章無效／無法確認、合法未簽署 PE、fat Mach-O、舊式 MZ、父目錄連結、FIFO、封存檔重複／路徑越界、關鍵連結目標、MoltenVK 合法切換、讀取中修改、取消／逾時，以及建置產生三份清單／索引而不更改輸入。snapshot 斷言檢查讀取前後內容與修改 metadata 不變；發行者信任的正向單元案例使用明確的 mock，不冒充實際 Developer ID 發布驗收。

AppKit fixtures 只執行臨時 Ruby observer，驗證主執行緒回應、結果顯示、取消、重啟、延遲回覆隔離、deadline 與輸出限制；不啟動 Wine。整個 App 的整合測試需正常桌面／LaunchServices 權限。

正式發布前仍需以實際 Developer ID 簽署的完整 App 驗證信任鏈、各元件完整掃描、端到端啟動預算，以及目標 macOS 版本（含 Catalina shell 路徑）的系統 Ruby／codesign 行為；本次未進行公證或新楓之谷實機驗收。自動修復、差分重新下載、簽章政策遷移及防毒隔離取證不屬於此階段。

### 本次結果（2026-10-30）

- 元件核心／建置 fixtures：18 cases、86 assertions，全部通過。
- Hook、AppKit 背景／取消／重啟／deadline／5 MiB 輸出／關閉視窗 fixtures：通過。
- 既有 graphics 安裝、engine tarball、App payload、engine version：通過。
- 滾輪核心：19 cases、82 assertions；最終啟動次序與 12 組解析案例、每遊戲設定：通過。
- 完整 App 隔離整合：選單／直接入口、main runloop、環境不可用、慢速診斷 I/O、重開、退出與 durable forwarding/recovery：通過。沙箱內的桌面服務測試無法正常啟動 fixture，已在沙箱外以隔離環境重跑通過；未執行真實 Wine。
- 新 Swift 元件診斷程式的 x86_64 / macOS 11 typecheck：通過；arm64 AppKit fixture 與完整 App 編譯／執行通過。這不等於 Intel 實機驗收。
- 正常系統信任服務下，實際 Wine Developer ID 元件通過 literal `codesign -R` 發行者 requirement；既有 ad-hoc App 無法建立發行者信任。新正式 App 的完整簽署／公證驗收仍待發行流程。


後續已實作精確 upstream-unsigned 例外、簽署後 package 的 Team／時間戳政策及正式發佈 gate；最新行為見 [Graphics 簽章政策](graphics-signing-policy.zh-TW.md)。上面的 DXMT 缺簽結果是例外加入前的歷史量測。
