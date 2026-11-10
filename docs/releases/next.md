# 下一版預計改進

> 更新：2026-10-03  
> 狀態：第一階段已實作並完成建置／CPU 測試，待 GPU 驗收；版本號與正式納入範圍待定。

## 新楓之谷：DXMT 資源建立與繪圖卡頓

目標是降低首次使用圖形資源時的 CPU 配置、資料上傳與提交等待成本，並修正已重現的初始化資料遺失。引擎與 renderer 修改在 sibling `cyder-wine-engine` 完成；Cyder 應用層負責驗收後的 engine／graphics payload 匯入與版本整合。

依據：[完整程式分析與測量](../../../cyder-wine-engine/docs/maplestory-dxmt-resource-cpu-submit-study.zh-TW.md)、[重現工具與原始證據](../../../cyder-wine-engine/tools/dxmt-resource-study/README.md)、[GameToMac／PSO archive 研究](../games/gametomac-maplestory-pipeline-study.zh-TW.md)。分析基準為 DXMT v0.80 與本機獨立 PSO archive 實驗版本，不能推論其他 DXMT 版本或 D3DMetal 有相同缺陷。

### 預計工作與順序

| 順序 | 預計改進 | 具體修改與目前證據 | 對新楓之谷的預期／限制 |
|---:|---|---|---|
| 1 | **修正初始化命令區耗盡後資料遺失** | 將 `do…while(0)` 內配置失敗後直接退出的流程，改成完整預留命令空間、flush 後確實重試；避免提交尚未填好的 command，並處理永久配置失敗。GPU 測試在 16,384 個子資源中三次重現零起算 slice 9294 初始資料變全零；8,192 個控制組正確。 | 優先處理的正確性問題；尚未證明遊戲會觸發此容量邊界，或它是首次命中卡頓根因。 |
| 2 | **補齊低干擾分段計時** | 記錄 newBuffer／newTexture 次數、bytes 與耗時、pool hit/miss、padded upload、initializer 鎖與 flush、PSO 排隊／等待、Map／chunk／Present 等待；用 frame／chunk／event ID 對齊。補上現有 `commit_interval` 未涵蓋的 initializer 成本，修正統計最小值從零起算與 event_stall 欄位誤用。 | 先分清楚配置、遊戲 CPU、編譯與同步各占多少時間，作為後續改造依據。 |
| 3 | **合併帶 padding 的紋理上傳** | 同時處理 `CreateTexture` 初始化與 `UpdateSubresource`：將逐列 Wine／Metal bridge call 改成批次 stride copy，統一通知修改範圍。保留 managed 同步、來源資料生命期、BC／mip／array／3D pitch／部分 box 語意。 | 若命中特效或傷害字大量上傳帶 padding 的紋理，可能降低 CPU burst；來源為 tight layout 時收益有限。 |
| 4 | **改善 buffer 回收與零填充配置** | 審核所有 coherent sequence 契約後，評估將 ring allocator 的 `<` 回收邊界改為 `<=`；zero buffer 改為有上限的尺寸分桶或幾何成長，消除擴張路徑的雙重 flush，保留舊 allocation 至 GPU 完成。 | 可能減少 burst 邊界的額外 Metal 配置與提交。現有程式已有 pooling，重點是回收邊界與真正 pool miss，並非全面重寫 allocator。 |
| 5 | **避免 archive 寫入占住編譯 worker** | 前輪實驗 cache 的 save 雖在 ready/notify 後，仍占 compilation worker；評估獨立、有界、低優先權寫入佇列，滿載時放棄此次持久化，確保生命期與 shutdown join。依量測評估 compiler 執行緒數與優先權。 | 適用於啟用 archive 的 cold pipeline burst；不會減少遊戲解壓、紋理配置或必要 GPU 同步成本。 |
| 6 | **依量測縮小初始化等待範圍** | 若 trace 顯示整個 chunk 等待全部 upload 是主因，再研究按 allocation／subresource 記錄初始化 event，在最早使用資源前等待，保留跨 queue 相依性與 untracked resource hazard 追蹤。 | 有機會避免無關繪圖一起被擋住；屬較大改造，先量測再決定是否納入。不能直接移除 wait 或以增加 queue 深度代替修正。 |

### 目前效能證據

- 同版 DLL、相同內容的 64 張 257×512 RGBA8 紋理，暖機後 tight row pitch 1028 的建立時間約 **1.3–1.6 ms**，padded row pitch 1280 約 **2.5–2.8 ms**；全部逐列 GPU 讀回正確。這是輸入 layout 比較，**不是優化前後的加速結果**，不可外推為遊戲 FPS 增幅。
- 抽出原始 ring allocator、以 fake allocator 模擬 20 批已完成工作：現行邊界配置 **2 個 block**，包含相等邊界後為 **1 個**。這證實配置差異，尚未驗證所有 GPU 生命期情境。
- 既有遊戲紀錄的首次命中 Present 空窗約 **655–749 ms**；目前沒有新的遊戲內 A/B。執行緒名稱含 `AGXBuffer init…` 不足以證明 allocator 是根因。

### 2026-10-03 執行進度

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

### 納入版本前的驗收條件

- [ ] 初始化修正後，8,192 與 16,384 個子資源全部逐像素讀回正確；新增 heap-full、不同配置失敗點與永久失敗測試，不能把既知失敗重現算成 graphics pass。
- [ ] 上傳修改涵蓋 tight／padded、BC、mip／array、3D 與部分更新，並確認 API 返回前已取走來源資料；i386 無法安全存取映射位址時保留回退。
- [ ] 回收與 zero buffer 修改通過 GPU 延遲完成、連續尺寸增長與高配置壓力測試，沒有過早重用、資料污染或無界記憶體增長。
- [ ] 每個優化使用獨立 patch／實驗開關；分別保留停用與啟用時的耗時、記憶體及畫面正確性結果。
- [ ] 同一角色、地圖、技能做多次真命中測試，區分 cold process 與 PSO archive 冷／暖狀態，比較最長 Present gap、p95/p99 frame time 和分段耗時；確認登入、持續遊玩與退出正常。
- [ ] 驗收通過後，依引擎打包與 Cyder release 流程整合；記錄實際 engine／graphics 版本及雜湊，再更新正式 release note。

這些項目列入下一版的改進工作清單；是否正式出貨取決於各項驗收。尚未確認可消除新楓之谷首次命中卡頓，不預先承諾效能百分比。現有 PSO archive 仍是獨立、預設停用的實驗，不能因列入規劃就直接改成產品預設。
