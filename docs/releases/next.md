# 0.15.0 規劃

> 更新：2026-11-16
> 狀態：範圍已選定，開發中。列入不代表一定出貨；每項需通過下方驗收才進正式 release note。

0.15.0 需要 macOS 12 以上（0.14 系列是最後支援 macOS 10.15／11 的版本）。

## 範圍

### A. 新楓之谷首次命中卡頓（[#22](https://github.com/dspp779/CyderBits/issues/22)、[#25](https://github.com/dspp779/CyderBits/issues/25)）

| 項目 | 內容 | 目前狀態 | 驗收 |
|---|---|---|---|
| A1 | WZ read-ahead（`CYDER_MAPLESTORY_READAHEAD`）正式納入 engine：patch 套用清單、`build-wine.sh`、`engine-release.json` 與測試；決定是否預設開啟 | 2026-11-16：已納入 Cyder014 release stack（engine `claude/cyder014`）並有 patch 測試；App 將它與 WZ cache 合併為「MapleStory WZ 檔案讀取最佳化」單一設定，預設開啟。各後端各量一次，讀取等待約減少 70%（DXVK 388 → 108 ms）；A5 多次量測未做 | 有 patch 測試；A5 量測確認效果後再決定預設值 |
| A5 | 各後端（DXVK／DXMT／D3DMetal）多次冷快取量測，並在舊款 Intel Mac 量測 | 目前每格只有一次 | 同角色、地圖、技能，每格至少 3 次；記錄讀取等待、最長 Present 空窗與 p95／p99 幀時間 |
| A11 | 舊款 Intel Mac 走圖卡頓：型態、WZ cache 開／關、DXVK state cache 是否寫入並在下次生效 | 從未量測 | 有量測紀錄與結論；若需修改另開項目 |

不納入：read-ahead 後 256 KiB 補讀視窗、cache 命中去除 `lseek`、mutex 外補讀，以及下方 DXMT resource lab 各項。

### B. Wine engine Cyder014

| 項目 | 內容 | 目前狀態 | 驗收 |
|---|---|---|---|
| B1 | 不以高於 minOS 下限的函式建置 engine（`pipe2`、`strchrnul`、`pcap_init`），打包時檢查 weak import（[engine PR #14](https://github.com/dspp779/cyder-wine-engine/pull/14)） | 程式與離線測試完成；待在 macOS 27／Xcode 27 建置機重建 | `nm -m` 無 `_pipe2`／`_strchrnul`；兩道打包檢查通過；封存不含 `ntdll.so.pre-qdo`；macOS 15.8 bottle 更新（`wineboot -u`）成功 |
| B2 | 程式被 signal 結束時 wineserver 不再當掉（[engine #15](https://github.com/dspp779/cyder-wine-engine/issues/15)／[PR #16](https://github.com/dspp779/cyder-wine-engine/pull/16)） | Apple Silicon 上修正版 SIGTERM 3/3、SIGKILL 1/1 未當掉 | Intel／macOS 15.8 重測；強制結束一款真實遊戲後 server 與 Cyder 啟動流程正常收尾 |
| B3 | [#23](https://github.com/dspp779/CyderBits/issues/23)：MacBook Neo（A18 Pro）／macOS 26.6 的 `wineboot` Segmentation fault | 推測與 B1 同因（macOS 26 沒有 `pipe2`），未確認 | 以 Cyder014 在 macOS 26 建立環境成功，或請回報者驗證 |
| B4 | engine 標籤升為 Cyder014、打包並匯入 CyderBits | 2026-11-16：engine `claude/cyder014`（main + #14、#16、read-ahead、MoltenVK 1.4.2 only）以 Developer ID 打包並匯入；`CX26.3.0-W11-Cyder014`，archive SHA-256 `c2504eeb4e8eb0f8fa30f383c0af73963690679ebcbfb891cf5cc7a4ca243258`，ntdll SHA-256 `d9de819e36ab2adbfb5ea234037ba08e4e5a856a6cd65c302aa7ffc84f541a8a`。未打 tag、未推送 | 依 `cyder-release` 流程；記錄 engine 版本與 ntdll SHA-256 |
| B5 | 移除 MoltenVK 1.2.10，只保留 1.4.2（0.15.0 已要求 macOS 12+，舊系統理由不再存在）：engine 只打包 1.4.2；移除偏好設定選項、`cyder-moltenvk-variant.sh` 選版與相關測試；殘留的 1.2.10 設定改回 1.4.2 | 2026-11-16：程式已完成（engine 只打包 1.4.2；選項與選版移除；殘留 `.real` → 1.2.10 於啟動時改回 1.4.2），待 Intel 實測才能出貨。原條件：1.2.10 目前是 [#7](https://github.com/dspp779/CyderBits/issues/7) 舊款 Intel 內顯（Iris Plus 640，macOS 13）世界層黑畫面唯一已知可用的設定；1.4.2 是否修正未確認。Intel Mac 只能用 DXVK，影響最大 | 舊款 Intel 內顯以 1.4.2 跑新楓之谷經典版畫面正常（可與 A5／A11 的 Intel 量測合併，或請 #7 回報者驗證）；未通過則保留 1.2.10 |

### C. Steam 與 Cities: Skylines II（[#10](https://github.com/dspp779/CyderBits/issues/10)）

依據：[CS2 支援可行性與驗收方案](../games/cities-skylines-2-support-assessment.zh-TW.md)、[Steam 相容設定](../games/steam/README.md)。CS2 免費遊玩期至 2026-11-16。

| 項目 | 內容 | 目前狀態 | 驗收 |
|---|---|---|---|
| C1 | Steam 在目前 engine 上從登入、遊戲庫、下載到啟動遊戲 | 2026-11-15：圖形為 WineD3D 時可登入並下載 CS2；全域圖形選 DXVK 時不出現視窗（[說明](../games/steam/README.md)），不修改程式 | 登入、商店／遊戲庫畫面、下載、啟動一款遊戲、退出，逐步記錄 |
| C2 | CS2 第一階段：CompatDB 規則（`Cities2.exe` 使用 DXMT）與使用指引（不經 Paradox Launcher、Steam 保持背景登入、遊戲內用 Fullscreen Window） | 2026-11-16：規則已啟用並有測試（圖形「預設」以外的選擇優先）；[使用指引](../games/cities-skylines-2/README.md) 完成 | 規則有測試；指引文件完成；不修改遊戲檔案 |
| C3 | CS2 第二階段：不修改遊戲檔案的實測 | 2026-11-15：DXMT 正常初始化，但遊戲在檔案列舉 `IOException` 後卡在黑畫面，未進主選單；Cyder011 與 CrossOver 26.3 官方 engine 相同。engine 修正 Mono last error（engine `claude/mono-gs-lasterror`）後，**未修改的遊戲**設定 SteamAppId 即到達主選單（[紀錄](../games/cities-skylines-2-support-assessment.zh-TW.md)）。修正需隨 Cyder014 出貨。遊玩測試：新遊戲、存檔、重開讀檔、3 分鐘執行、正常退出皆通過；建造與 Mods 未測。圖形後端：只有 DXMT 可玩（D3DMetal 城市全黑、DXVK 停在主選單）。launcher 從 Steam 的 `appmanifest` 取得直接啟動遊戲的 Steam App ID | 進主選單、新建城市、存讀檔、遊玩 20 分鐘、退出；記錄是否需要遊戲 DLL 修補 |

不納入：CS2 遊戲 DLL 修補工具（第三階段）。未通過 C3 前，不宣稱 CS2 可玩。

## 延後（未納入 0.15.0）

以下為先前規劃，保留作後續版本依據。

> 更新：2026-10-03  
> 狀態：第一階段已實作並完成建置／CPU 測試，待 GPU 驗收；版本號與正式納入範圍待定。

### DXMT 資源建立與繪圖卡頓（原 2026-10-03 規劃）

目標是降低首次使用圖形資源時的 CPU 配置、資料上傳與提交等待成本，並修正已重現的初始化資料遺失。引擎與 renderer 修改在 sibling `cyder-wine-engine` 完成；Cyder 應用層負責驗收後的 engine／graphics payload 匯入與版本整合。

依據：[完整程式分析與測量](../../../cyder-wine-engine/docs/maplestory-dxmt-resource-cpu-submit-study.zh-TW.md)、[重現工具與原始證據](../../../cyder-wine-engine/tools/dxmt-resource-study/README.md)、[GameToMac／PSO archive 研究](../games/gametomac-maplestory-pipeline-study.zh-TW.md)。分析基準為 DXMT v0.80 與本機獨立 PSO archive 實驗版本，不能推論其他 DXMT 版本或 D3DMetal 有相同缺陷。

#### 預計工作與順序

| 順序 | 預計改進 | 具體修改與目前證據 | 對新楓之谷的預期／限制 |
|---:|---|---|---|
| 1 | **修正初始化命令區耗盡後資料遺失** | 將 `do…while(0)` 內配置失敗後直接退出的流程，改成完整預留命令空間、flush 後確實重試；避免提交尚未填好的 command，並處理永久配置失敗。GPU 測試在 16,384 個子資源中三次重現零起算 slice 9294 初始資料變全零；8,192 個控制組正確。 | 優先處理的正確性問題；尚未證明遊戲會觸發此容量邊界，或它是首次命中卡頓根因。 |
| 2 | **補齊低干擾分段計時** | 記錄 newBuffer／newTexture 次數、bytes 與耗時、pool hit/miss、padded upload、initializer 鎖與 flush、PSO 排隊／等待、Map／chunk／Present 等待；用 frame／chunk／event ID 對齊。補上現有 `commit_interval` 未涵蓋的 initializer 成本，修正統計最小值從零起算與 event_stall 欄位誤用。 | 先分清楚配置、遊戲 CPU、編譯與同步各占多少時間，作為後續改造依據。 |
| 3 | **合併帶 padding 的紋理上傳** | 同時處理 `CreateTexture` 初始化與 `UpdateSubresource`：將逐列 Wine／Metal bridge call 改成批次 stride copy，統一通知修改範圍。保留 managed 同步、來源資料生命期、BC／mip／array／3D pitch／部分 box 語意。 | 若命中特效或傷害字大量上傳帶 padding 的紋理，可能降低 CPU burst；來源為 tight layout 時收益有限。 |
| 4 | **改善 buffer 回收與零填充配置** | 審核所有 coherent sequence 契約後，評估將 ring allocator 的 `<` 回收邊界改為 `<=`；zero buffer 改為有上限的尺寸分桶或幾何成長，消除擴張路徑的雙重 flush，保留舊 allocation 至 GPU 完成。 | 可能減少 burst 邊界的額外 Metal 配置與提交。現有程式已有 pooling，重點是回收邊界與真正 pool miss，並非全面重寫 allocator。 |
| 5 | **避免 archive 寫入占住編譯 worker** | 前輪實驗 cache 的 save 雖在 ready/notify 後，仍占 compilation worker；評估獨立、有界、低優先權寫入佇列，滿載時放棄此次持久化，確保生命期與 shutdown join。依量測評估 compiler 執行緒數與優先權。 | 適用於啟用 archive 的 cold pipeline burst；不會減少遊戲解壓、紋理配置或必要 GPU 同步成本。 |
| 6 | **依量測縮小初始化等待範圍** | 若 trace 顯示整個 chunk 等待全部 upload 是主因，再研究按 allocation／subresource 記錄初始化 event，在最早使用資源前等待，保留跨 queue 相依性與 untracked resource hazard 追蹤。 | 有機會避免無關繪圖一起被擋住；屬較大改造，先量測再決定是否納入。不能直接移除 wait 或以增加 queue 深度代替修正。 |

#### 目前效能證據

- 同版 DLL、相同內容的 64 張 257×512 RGBA8 紋理，暖機後 tight row pitch 1028 的建立時間約 **1.3–1.6 ms**，padded row pitch 1280 約 **2.5–2.8 ms**；全部逐列 GPU 讀回正確。這是輸入 layout 比較，**不是優化前後的加速結果**，不可外推為遊戲 FPS 增幅。
- 抽出原始 ring allocator、以 fake allocator 模擬 20 批已完成工作：現行邊界配置 **2 個 block**，包含相等邊界後為 **1 個**。這證實配置差異，尚未驗證所有 GPU 生命期情境。
- 既有遊戲紀錄的首次命中 Present 空窗約 **655–749 ms**；目前沒有新的遊戲內 A/B。執行緒名稱含 `AGXBuffer init…` 不足以證明 allocator 是根因。

#### 2026-10-03 執行進度

實作入口：[DXMT resource lab 第一階段](../../../cyder-wine-engine/tools/dxmt-resource-lab/README.md)。

| 項目 | 目前狀態 |
|---|---|
| 初始化命令空間與失敗回報 | 已實作完整空間預留、上傳配置先於命令串接、E_OUTOFMEMORY 回報；待 GPU 確認不再遺失資料。 |
| 初始化與提交計時 | 已實作預設停用的聚合數據及各 64 筆 upload／chunk 事件記錄；統計 startup／min／average／event_stall 測試通過。一般資源配置、PSO 與完整遊戲 trace 尚待擴充。 |
| 零填充 buffer | 已處理擴張路徑雙 flush 與舊資源生命期；尺寸分桶／幾何成長及 ring 回收邊界尚未實作。 |
| 獨立測試版 | 69 個 PE source files 編譯並連結成功；從固定來源重新套 patch 與建置來源逐檔相同，Metal bridge 與其他 payload 未更換。 |
| GPU／遊戲驗收 | 尚未執行。本機 macOS 27.0.1 目前缺少可用 Rosetta，x86_64 程式回報 Bad CPU type；等待使用者對安裝與 Apple 授權的確認。 |
| 後續優化 | 批次 pitched upload、buffer 回收、獨立 archive 寫入佇列待前階段 GPU 驗收後繼續；細化同步等待仍需量測支持。 |

獨立 overlay 標籤：`v0.80-cyder-resource-lab-5bec39a47b2ff778`。建置與 CPU 測試通過不代表 GPU 正確性已通過，不能宣告新楓之谷卡頓已改善；未變更正式 runtime 或 engine pin。

#### 納入版本前的驗收條件

- [ ] 初始化修正後，8,192 與 16,384 個子資源全部逐像素讀回正確；新增 heap-full、不同配置失敗點與永久失敗測試，不能把既知失敗重現算成 graphics pass。
- [ ] 上傳修改涵蓋 tight／padded、BC、mip／array、3D 與部分更新，並確認 API 返回前已取走來源資料；i386 無法安全存取映射位址時保留回退。
- [ ] 回收與 zero buffer 修改通過 GPU 延遲完成、連續尺寸增長與高配置壓力測試，沒有過早重用、資料污染或無界記憶體增長。
- [ ] 每個優化使用獨立 patch／實驗開關；分別保留停用與啟用時的耗時、記憶體及畫面正確性結果。
- [ ] 同一角色、地圖、技能做多次真命中測試，區分 cold process 與 PSO archive 冷／暖狀態，比較最長 Present gap、p95/p99 frame time 和分段耗時；確認登入、持續遊玩與退出正常。
- [ ] 驗收通過後，依引擎打包與 Cyder release 流程整合；記錄實際 engine／graphics 版本及雜湊，再更新正式 release note。

這些項目列入下一版的改進工作清單；是否正式出貨取決於各項驗收。尚未確認可消除新楓之谷首次命中卡頓，不預先承諾效能百分比。現有 PSO archive 仍是獨立、預設停用的實驗，不能因列入規劃就直接改成產品預設。
