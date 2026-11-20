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

## 採用任務清單（逐項懷疑）

原則：Recall 的修補是「一個人、一台 M1 Pro、一款遊戲」的解法。每一項在採用前都要回答四個問題，答不出來就不採用：

1. **問題在 Cyder 上重現了嗎？** 先在 Cyder 量到同樣的症狀，才算有問題要解。
2. **根本原因是 Recall 說的那個嗎？** 讀過原始碼、能指出出錯的那一行。
3. **有沒有更小、更通用、或更上游的解法？** 例如修正呼叫端而非包一層條件、送回 CodeWeavers／Wine／DXMT 上游、或用設定取代修補。
4. **代價是什麼？** 對其他遊戲（楓之谷、Steam、BlueCG）、minOS、簽署與維護負擔的影響；每項行為變更依 AGENTS.md 規則 6 附上最窄的測試。

以下「已確認」指 2026-11-20 讀過 Cyder 使用的 CrossOver 26.3.0 原始碼（engine `build/cx26/sources/wine`）。

### 門檻

- [ ] **G0 Battle.net 在 Cyder bottle 可用。** 安裝、登入、更新、下載、啟動。疑點：Recall #48 的 CEF 崩潰修正內容未知，先查 Recall 1.6.2 前後的差異再決定是否需要；Cyder 已對 Steam 的 CEF 加參數，Battle.net 可能同樣只需參數而非修補。
- [ ] **G1 未修改的 DXMT v0.80 能否進入對戰。** 記錄粒子特效、FPS、1% low、卡頓次數。此結果決定 T3 是否必要。

### T1 Wine 修補

- [ ] **T1.1 msync 下錯誤關閉 alert「fd」（Recall #40、#50）。**
  - 已確認：CrossOver `dlls/ntdll/unix/sync.c` 的 `get_inproc_alert_fd()` 在 msync 下把 `reply->handle`（共享表的索引）存進 `alert_fd`，而 `thread.c` 的 `pthread_exit_wrapper()` 一律 `close()` 它，會關掉剛好同號的檔案。這是 CrossOver 本身的錯，與 Overwatch 無關。
  - 疑點：Recall 的 `if (!do_msync()) close(...)` 只擋住症狀；同一個欄位仍同時代表「fd」與「索引」兩種意義，之後任何人再 `close(alert_fd)` 都會重犯。執行緒結束時，伺服器端的 alert 索引是否有回收也未確認。
  - 較好的作法：msync 索引另存一個欄位（例如 `alert_index`），`alert_fd` 只存真正的 fd；確認索引回收路徑；回報 CodeWeavers。
  - 關聯：Cyder 的 MSync 是選用設定，`docs/games/pikachu-volleyball/` 記錄 MSync 不相容。先檢查該問題是否同一個原因。
- [ ] **T1.2 載入 DLL 的 Unix library 時持有 `virtual_mutex`。**
  - 已確認：CrossOver `get_builtin_unix_funcs()` 在持有 `virtual_mutex` 時呼叫 `dlopen()`。Recall 改為先放鎖、`dlopen()`、再上鎖，並處理兩個執行緒同時載入的情況。
  - 疑點：Recall 稱 Rosetta 下 `dlopen()` 需要 170–770 ms，這通常表示 Rosetta 的翻譯快取未命中，而不是 `dlopen()` 本身慢。若是如此，鎖只是把延遲擴散給其他執行緒，真正的成本仍在。`dlopen()` 期間的 initializer 若回呼需要 `virtual_mutex` 的路徑，原本的持鎖是否有其他保護用途也未確認。
  - 較好的作法：先用 `WINE_SYSCALL_LOG` 類型的量測在 Cyder 重現凍結；再比較「放鎖」與「啟動時預先載入常用 Unix library」或「預先觸發 Rosetta 翻譯」。放鎖本身看起來正確，可作為 upstream Wine 的修補提出。
- [ ] **T1.3 wineserver 每 30 秒存 registry 造成全體暫停。**
  - 已確認：CrossOver 啟用 MSync 時，wineserver 會建立 `mach_message_pump` 執行緒（`server/msync.c`）。Recall 在這個多執行緒程序中 `fork()`，子程序再呼叫用到 stdio 與 malloc 的 `save_branch()`。POSIX 只保證 fork 後的子程序呼叫 async-signal-safe 函式；Recall 以 60 秒逾時 `SIGKILL` 兜底，可能把死結隱藏成「這次沒存到」。
  - 疑點：Cyder 自己的 `cyder-wineserver-registry-fsync.patch` 在主執行緒上對每個檔案 `fsync()`，Cyder 的暫停可能比 Recall 量到的更長，原因也不完全相同。另外 Recall 在 `mach.c` 假設「macOS 上唯一的子程序就是 registry 存檔」，未驗證。
  - 較好的作法：先量 Cyder 上一次存檔花在序列化與 `fsync()` 各多少時間。可考慮：主執行緒只把 dirty branch 序列化到記憶體，交給專用寫入執行緒寫檔與 `fsync()`；或在遊戲前景時延長存檔間隔。不採用 `fork()`。
- [ ] **T1.4 Battle.net 更新代理反覆重裝（約 14 MB）。**
  - 已確認：upstream Wine 的 `svcctl_SetServiceObjectSecurity()` 仍是 `FIXME`，回傳 `ERROR_CALL_NOT_IMPLEMENTED`。實作它是正確方向。
  - 疑點：「把服務路徑的 `/` 改成 `\`」是 Recall 為 Battle.net 加的推論，Windows 本身是否會正規化尚未查證；若 Windows 不會，改寫使用者給的路徑反而違反行為。
  - 較好的作法：把 security descriptor 部分拆出來，附 Wine 測試（`dlls/advapi32/tests/service.c` 類型）送 upstream；路徑正規化先在 Windows 上驗證行為再決定。先在 Cyder 重現重裝循環。
- [ ] **T1.5 執行中接上的耳機不出現（`wine-audio-devices.patch`）。**
  - 疑點：766 行，同時改 `mmdevapi` 與 `winecoreaudio.drv`；「藍牙耳機時改用 Mac 內建麥克風」是產品決策，不是 Windows 行為。
  - 較好的作法：只取裝置變更通知與 `AUDCLNT_E_DEVICE_INVALIDATED`；麥克風選擇不採用。查 upstream Wine 是否已有裝置熱插拔的工作。
- [ ] **T1.6 Media Foundation 存 MP4（`wine-media-foundation.patch`）。**
  - 疑點：約 260 KB，新增 `winemacmf` 元件，維護成本高，只對精華片段有用。
  - 建議：延後到 0.16.0 之後；先確認 Overwatch 可改存 WebM。
- [ ] **T1.7 Game Mode（`WINE_GAME_MODE`）。**
  - Recall 的作法是在 app bundle 內放一份 Wine loader 的複本，並 `execv()` 到它。
  - 疑點：每個遊戲一份 loader 複本，要分別簽署與公證；路徑依遊戲 exe 名稱組合。
  - 較好的作法：Cyder 已有 `scripts/cyder_create_game_app.py`，先評估讓產生的遊戲 app 本身宣告為遊戲並直接 exec loader，避免在 engine 裡用環境變數比對 exe 名稱。
- [ ] **T1.8 每個程式的 DPI（`WINE_APP_DPI`）。** 疑點：這是 Battle.net 在 Retina 的介面大小問題，可能用 per-app registry 設定（`LogPixels`）就能解決，不需修補。先試設定。

### T2 Mac driver

- [ ] **T2.1 對 Cyder 已修補的樹執行 `git apply --check`**，套用 `wine-v1-canvas`、`wine-mouselook`、`wine-winemac-activation`，列出衝突。
- [ ] **T2.2 拆成獨立問題**，每項分別在 Cyder 重現後再移植：點擊時重讀顯示器列表、Cmd-Tab 回到全螢幕、全螢幕解析度清單、鍵盤配置切換、IME。疑點：楓之谷已有自己的全螢幕與前景修補，兩邊對「何時重讀顯示器、何時離開全螢幕」的假設可能相反；任何一項都要回歸楓之谷與 BlueCG。
- [ ] **T2.3 raw mouse（Game Controller framework）。** 疑點：靠 exe 名稱清單（`WINEMAC_MOUSELOOK`）啟用；Game Controller 的 mouse 在其他 app 取得焦點時的行為需驗證。較好的作法：改由 CompatDB 規則啟用，而不是固定的環境變數清單。

### T3 DXMT（需先決定政策）

- [ ] **T3.0 簽署政策決定。** 選項：(a) 維持只用 upstream 原版，把修正送回 3Shain/dxmt 等新版本；(b) Cyder 自建並以 Developer ID 簽署修改版。疑點：(b) 會讓 Cyder 長期維護一個 DXMT 分支；upstream 最後一個 release 仍是 v0.80（2026-04-23），但 main 分支仍活躍。
- [ ] **T3.1 stream output 粒子特效（`dxmt-stream-output.patch`，288 行）。** 屬於正確性修正，最適合送回 upstream。先以最小 D3D11 程式重現（geometry shader 原樣傳遞點 + stream output），而不是只靠遊戲畫面判斷。
- [ ] **T3.2 shader 提前準備與 pipeline 快取。** 與 engine repo 的 GameToMac Overwatch DXMT 研究、PSO archive lab overlay 重疊；先比較兩者，不要同時維護兩套快取。
- [ ] **T3.3 等待、frame pacing、保留壓縮。** 疑點：Recall 的 frame pacing 以「讓遊戲睡到 GPU 快完成」換輸入延遲，對 GPU 較強的 Mac 或其他遊戲效果可能相反。逐項以相同錄製重播量測，不整包採用。

### 不採用（除非另有決定）

- [ ] **N1 偽裝 NVIDIA 顯卡與自簽 `nvngx.dll`。** 若之後要做超解析，改評估由 DXMT 在 Metal 端提供 MetalFX spatial upscaling，不向遊戲偽裝硬體。
- [ ] **N2 `WINEMAC_SCREEN_READBACK`（反作弊截圖回傳黑畫面）。** 不採用；韓國版另案評估。
- [ ] **N3 HID 直接讀取滑鼠。** 需要「輸入監控」權限；等 T2.3 完成並確認 Game Controller 不足時再談。

## 本次未做

未建置或執行 Recall；未在 Cyder 上啟動 Battle.net 或 Overwatch；未對 Cyder 修補樹執行任何 `git apply --check`。任務清單中「已確認」的部分只是讀過原始碼，沒有重現或量測。Recall 的效能數據與 issue 修正狀態皆未經獨立驗證。
