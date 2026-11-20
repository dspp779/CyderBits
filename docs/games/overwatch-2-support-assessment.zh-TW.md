# Overwatch 2 支援可行性評估（參考 Recall）

評估日期：2026-11-20。目標版本：0.16.0（未承諾）。

結論：Recall 與 Cyder 使用同一份 Wine 基礎，Wine 修補可逐項評估移植；但 Recall 對 Overwatch 的主要效益在修改過的 DXMT，與 Cyder 現行「只出貨未修改 upstream DXMT v0.80」的簽署政策衝突。建議分層採用，不整包導入。0.16.0 是否可行，取決於下方兩道門檻（Battle.net、未修改 v0.80 能否進入對戰），兩者都尚未在 Cyder 實測。

本機基準：CyderBits `main` `2261b37b7395b399249020bb63aead4fa36fee3c`、engine `f1dbd2f2ddc622a6df754a8d490b901ba64c2484`（Cyder014）。本次只閱讀原始碼、文件與 issue，未建置、未執行、未測試任何遊戲。下文所有 Recall 數據都是其作者在單一 M1 Pro 上的自述，不是 Cyder 的驗收紀錄。

## 參考來源

[AsherJN/recall](https://github.com/AsherJN/recall)：Apache-2.0 的 Overwatch 專用 Mac 啟動器，最新為 1.6.6（2026-11-20）。修補位於 `patches/`，說明見其 `patches/README.md`、`docs/HOW-IT-WORKS.md`、`docs/BUILDING.md`、`docs/SOURCES.json`。

| 項目 | Recall 1.6.6 | Cyder（Cyder014） |
|---|---|---|
| Wine | CrossOver 26.3.0 `sources/wine`（Wine 11.0） | 相同 |
| DXMT | [NerRobDog/dxmt](https://github.com/NerRobDog/dxmt) `c5dc3a0`，比 v0.80 多 216 個 commit、144 個檔案，再加 7 個自有修補 | 只允許 upstream v0.80 原版（`cyder-wine-engine/docs/graphics-signing-policy.zh-TW.md`） |
| macOS | 26.5+，僅 Apple Silicon，以 macOS 26.5 SDK 建置 | 12+；DXMT gate 為 macOS 15+ |
| 授權 | App 程式 Apache-2.0；Wine／DXMT 修補 LGPL-2.1+ | 附上出處即可重用 |

Recall 版本更新很快：1.5（2026-10-21）到 1.6.6 之間共 8 個版本，多數是崩潰修正。若固定採用某一版修補，就必須持續追蹤上游。

## 分層建議

### 第一層：與遊戲無關的 Wine 修補（不論 Overwatch 是否延期都值得評估）

| 修補 | 解決的問題 | Cyder 端注意事項 |
|---|---|---|
| `wine-service-security.patch` | 保留 service 的 security descriptor、不把路徑斜線改壞；Battle.net 更新代理每隔一次啟動就重新下載約 14 MB | 先在 Cyder 重現 Battle.net 重裝循環 |
| `wine-ntdll-syscall-log.patch`（msync 部分） | 執行緒結束時把 msync alert index 當 fd 關閉，誤關遊戲封存檔，導致 Recall #40、#50 崩潰 | 檢查 Cyder 的 msync 路徑是否同樣受影響 |
| `wine-ntdll-syscall-log.patch`（loader lock 部分） | 載入 DLL 的 Unix library 時持有 virtual-memory lock，在 Rosetta 下對戰中每 20–25 秒凍結 150–400 ms | 與楓之谷 IO／載入相關修補一併回歸 |
| `wine-server-registry-save.patch` | wineserver 每 30 秒存 registry 時暫停所有程式約 0.1 秒，改由 fork 出的副本寫入 | 可能與 `cyder-wineserver-registry-fsync.patch` 衝突，需合併設計 |
| `wine-audio-devices.patch` | 執行中接上的耳機不會出現在遊戲；藍牙麥克風切換 | 純 Wine 行為修正，適合獨立 PR |
| `wine-media-foundation.patch` | 遊戲用 Media Foundation 存 MP4（精華片段）失敗；新增 VideoToolbox／AudioToolbox 編碼器 | 體積大（約 260 KB），優先度低於上列 |

每一項都先 `git apply --check` 於 Cyder 已套用修補的樹上，再以最小重現與既有遊戲回歸驗證；不因「同為 Wine 11.0」就假設行為相同。

### 第二層：Mac driver 修補（需要額外工作）

`wine-winemac-activation.patch`（約 149 KB）包含全螢幕畫布與解析度、點擊時不重讀顯示器列表、Cmd-Tab 回到全螢幕、raw mouse（Game Controller framework）、IME 與鍵盤配置切換。它與 Cyder 的楓之谷 winemac 修補（`maplestory-cx26-fullscreen-restore`、`keep-foreground`、`cyder-winemac-*` 等）修改相同區域。須先對 Cyder 已修補的樹執行 `git apply --check` 才能估工；預期需要拆分後逐項移植，而非整包套用。`wine-mouselook.patch` 與 `wine-v1-canvas.patch` 是它的前置修補，一起評估。

### 第三層：DXMT 效能與正確性（需要政策決定）

Recall 的主要效益都在這一層：

- 提前翻譯 shader、相同翻譯結果共用快取；shader pack 與啟動時預載（與 engine repo 的 GameToMac Overwatch DXMT 研究、PSO archive lab overlay 方向重疊）。
- 精準喚醒的 CPU／GPU 等待、frame pacing、維持 Apple 無損壓縮。
- `dxmt-stream-output.patch`：未修改的 DXMT 會丟棄 Overwatch 以 stream output 繪製的粒子特效（Ana 睡眠、Sombra 駭入、神話造型等）。這是正確性問題，不只是效能。

採用任何一項，都表示 Cyder 要自行建置 DXMT 並以 Developer ID 簽署；目前 `scripts/graphics-signing.py` 對 v0.80 以外的任何內容一律停止。這是產品政策決定，須先由維護者明確同意，並另訂來源、簽署與 minOS 掃描規則。Recall 的 DXMT 基於 NerRobDog fork，不是 v0.80 原版，因此實際工作是「把需要的修補 rebase 到 Cyder 選定的 DXMT 基準」，不是直接套用。

### 預設不採用

| 項目 | 原因 |
|---|---|
| `dxmt-metalfx-upscaling.patch` 的 DLSS 路徑 | 向遊戲回報 NVIDIA RTX 4090，並以自簽 Authenticode 繞過 NVIDIA loader 對 `nvngx.dll` 的簽章要求；有反作弊與帳號風險 |
| `WINEMAC_SCREEN_READBACK=1` | 讓韓國版反作弊截圖取得黑畫面而非失敗，屬於規避反作弊行為 |
| `WINEMAC_RAW_SOURCE=hid` | 需要「輸入監控」權限；可列為後續選項，不放入第一版 |

Recall 與 Cyder 都不修改遊戲檔案、不注入、不讀取遊戲記憶體；Blizzard 不正式支援 Mac 上的 Wine 執行，任何方案都無法保證帳號安全。

## 門檻與順序

1. **門檻零：Battle.net。** `compatibility-matrix.md` 與 `docs/games/` 目前沒有 Battle.net 或 Overwatch 紀錄。在 Cyder bottle 實測安裝、登入、更新、下載遊戲、啟動遊戲。Recall 在同一 Wine 11.0 上曾遇到 Battle.net CEF renderer 必定崩潰（[#48](https://github.com/AsherJN/recall/issues/48)，例外 `0xE0000008` 於 `libcef`），後續版本修正；修正內容需另查。
2. **門檻一：未修改的 DXMT v0.80 能否進入對戰。** 記錄能否到主選單、練習場、自訂對戰；粒子特效是否缺失；平均 FPS、1% low、超過 50 ms 的卡頓次數。這決定是否必須做第三層。
3. 第一層 Wine 修補逐項移植，每項一個 engine PR，附最小重現與回歸。
4. 第二層 Mac driver 修補拆分移植。
5. 若門檻一失敗或卡頓不可接受，提出 DXMT 簽署政策變更，再移植第三層。

0.16.0 的合理目標是完成 1–3，並把 Overwatch 標為「實驗性」；宣稱可玩須另外通過實機驗收。

## 實機驗收項目

- Battle.net：首次安裝、登入（含 Xbox 等第三方登入，見 Recall #33）、重開後保持登入、遊戲更新是否每次重新套用（Recall #26 回報同一修補反覆出現）。
- Overwatch：主選單、練習場、自訂對戰與一般對戰各至少一場；英雄禁用後不崩潰（#50）；粒子特效正常（#57）；Cmd-Tab、Spaces 切換多次後畫面與輸入恢復；外接螢幕。
- 效能：相同 Mac、相同設定下與 CrossOver 或 Recall 對照，記錄完整 engine 與 graphics 雜湊。
- 每次記錄有效 graphics backend、實際載入路徑、錯誤原文與正常退出。

## 本次未做

未建置或執行 Recall；未在 Cyder 上啟動 Battle.net 或 Overwatch；未對 Cyder 修補樹執行任何 `git apply --check`。Recall 的效能數據與 issue 修正狀態皆未經獨立驗證。
