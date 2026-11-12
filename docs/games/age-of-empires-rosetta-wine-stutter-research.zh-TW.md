# 世紀帝國 IV／II：Rosetta、Wine 與 CrossOver 卡頓研究

- 調查日期：2026-09-07
- 研究狀態：已完成初步研究；尚未修改 Cyder 引擎、CompatDB 或正式 workaround
- 相關引擎：Cyder 目前 pin 的 CX26.3.0／Wine 11.0

## 結論摘要

目前不適合把網路上所稱的 AoE IV 修正直接納入 Cyder 正式引擎，但值得在
`cyder-wine-engine` 建立實驗分支做 A/B 測試。

這個修正有機會改善 AoE II，因為兩者都可能經過 x86_64 Wine、Rosetta、例外處理
與可執行程式碼翻譯；但是現有證據不足以判定 AoE II 每 5–6 秒的週期性卡頓就是
同一個根因。AoE II 的歷史回報包含 Intel Mac、主選單與不同圖形後端，這削弱了
「純 Rosetta code-cache 問題」的解釋。

目前應採取的判定是：

1. **可納入研究計畫：** Rosetta／Wine 例外處理與 executable-page translation
   reuse 值得做受控實驗。
2. **不可直接納入正式引擎：** Marc Ibrahim 的實際 diff、測試方法與回歸測試尚未
   公開可審查，不能只根據一篇社群貼文做全域 Wine 修改。
3. **AoE II 先分型：** 先把長期存在的 5–6 秒週期性卡頓，與 2026 年 6 月遊戲
   更新後的長載入、記憶體暴增與嚴重卡頓分開追蹤。

## 1. AoE IV 網路觀察

Marc Ibrahim 的貼文表示，AoE IV 在 Apple Silicon 上由 CrossOver 約 8 FPS 且
頻繁凍結，改善後可在高畫質、大型戰鬥與線上模式維持約 70–150 FPS。他後續說明：

- GPU 工作約 9 ms；
- 但每個 frame 原本約需 160 ms；
- Astra 修改了 Wine 的例外處理；
- 另外加入 code cache，使 Rosetta 可以重用翻譯，而不是反覆翻譯同一段程式碼。

來源：[Marc Ibrahim 原始貼文](https://x.com/marc_ibrahim/status/2096365209111724235?s=46)

這個測量若屬實，瓶頸比較像 CPU／Wine／Rosetta translation path，而不是
D3DMetal 單純繪圖效能。不過它仍是單一實驗結果，沒有公開完整 patch、基準測試
或可重現的最小案例，因此不能直接當成上游通用修正。

CrossOver 26.0 的 release notes 確實把 Age of Empires IV: Anniversary Edition
列為修正遊戲之一，但目前 AoE IV 相容性頁仍是 Limited Functionality，論壇也有
CrossOver 26.x 的 microstutter 回報。這表示「版本含有某些 AoE IV 修正」不等於
「所有 Apple Silicon 使用者的卡頓都已解決」。

來源：[CrossOver changelog](https://www.codeweavers.com/crossover/changelog) ·
[AoE IV CrossOver 討論](https://www.codeweavers.com/compatibility/crossover/forum/age-of-empires-iv?msg=343863)

## 2. 這類修正對 Cyder 的技術意義

「加入 Rosetta code cache」不應理解成在 Cyder 加一個環境變數或圖形後端選項。
較合理的技術解讀是：修正 Wine 對 Rosetta fault 的判斷，或避免不必要地把可執行
頁面標記為需要重新翻譯，讓 Rosetta 能保留並重用已產生的 translation。

目前 Cyder engine source 已有相關機制，包括：

- `ntdll/unix/signal_x86_64.c` 的 Rosetta invalid-instruction、privileged-instruction
  與部分 CET／XGETBV 例外處理；
- `ntdll/unix/virtual.c` 對 Rosetta 可執行頁面修改後的 permission／retranslation
  行為做補償。

可參考目前 source：`dlls/ntdll/unix/signal_x86_64.c` ·
`dlls/ntdll/unix/virtual.c`（engine checkout 的 `build/cx26/sources/wine/` 下）

另一個公開實驗專案 Endfield_FineWine 也記錄了兩類 Rosetta／Wine 問題：

1. Rosetta 對大量 `0F 1F` multi-byte NOP 的 fault 行為需要額外處理；
2. Rosetta 對 `mov rbx, cr3` 的例外類型可能與 Wine 預期不同，需要調整例外映射。

這證明例外處理確實可能影響使用保護、self-check 或 self-modifying code 的遊戲，
但不證明它就是 Marc 使用的相同 patch，也不代表可以不經測試地全域套用。

來源：[Endfield_FineWine working solution](https://github.com/stoicswe/Endfield_FineWine/blob/main/docs/13-working-solution.md)

## 3. AoE II 的問題需要分成兩類

### 3.1 長期存在的週期性 5–6 秒卡頓

社群回報的特徵包括：

- 約每 4–8 個遊戲內秒數，或約每 5–6 秒 real time 卡頓一次；
- 有人在主選單與遊戲中都能重現；
- 回報涵蓋 M1／M2／M3 以及 Intel Mac；
- DXVK、D3DMetal、GPTK、Windows 相容模式與 sync 選項之間沒有一致解法；
- 有些案例在 CrossOver 或 macOS 更新後開始，但不代表根因一定是 Rosetta。

來源：[CodeWeavers AoE II stutter 討論](https://www.codeweavers.com/compatibility/crossover/forum/age-of-empires-ii-definitive-edition/?forumthreadcurPos=0%3Bmsg%3D234409%3Bmsg%3D252762) ·
[社群重現紀錄](https://www.reddit.com/r/Codeweavers_Crossover/comments/1i12g12/stutter_every_7ish_seconds_m1_macbook_pro_age_of/)

這些特徵使以下可能性仍需優先排查：遊戲 timer／simulation、present／VSync、
audio callback、檔案或 shader 工作、Wine scheduler，以及特定版本的遊戲邏輯。
因此，AoE IV 的 Rosetta 修正目前只能列為其中一條假說，不能視為最可能答案。

### 3.2 2026 年 6 月更新後的另一個 regression

近期另有一組更嚴重的回報：載入時間大幅增加、文明選擇或主選單停頓數十秒、
記憶體與 CPU 持續升高，最後造成整台 Mac 變慢。這組現象應與舊的固定週期卡頓
分開追蹤；即使兩者都被玩家描述成「stutter」，也不代表共享同一個 bug。

社群亦有回報 CodeWeavers 正在把這個 regression bisect 到 Wine 10.0-rc1 與
Wine 10.3 之間的變更，但這不等於已證明它就是 5–6 秒週期性卡頓的根因。

來源：[近期 AoE II／CrossOver regression 討論](https://www.reddit.com/r/aoe2/comments/1vg1ai7/update_on_aoe2_de_multiplayer_issues_with/)

## 4. 是否適合納入 Cyder

| 項目 | 目前判定 | 原因 |
|------|------|------|
| 直接照 Marc 貼文修改正式 Wine engine | **不適合** | 沒有可審查的完整 diff、授權、回歸測試與 AoE II 證據 |
| 把 Rosetta exception 修正放進實驗 engine | **適合** | 有公開先例，且目前 engine 已有相鄰的 Rosetta workaround |
| 在 CompatDB 加 AoE II 全域 workaround | **暫不適合** | 5–6 秒卡頓尚未證明與某個 backend 或單一設定相關 |
| 先做 AoE IV／AoE II engine A/B benchmark | **優先建議** | 可把「共同 Wine/Rosetta 根因」與「AoE II 自身問題」分開 |

任何 exception handling 或 executable-page 行為的修改都可能影響其他 x86_64
遊戲的啟動、保護程式、JIT、自修改程式碼與 crash recovery。因此應以
`cyder-wine-engine` 的 patch／build／test 流程進行，不應在 app 層用全域環境變數
繞過。

## 5. 建議的 A/B 驗證計畫

### Phase 1：先確認 AoE II 卡頓類型

在乾淨 bottle、無 mods 的條件下，固定同一張地圖與解析度，分別測試：

- 主選單 idle；
- 單機 skirmish；
- 大型戰鬥；
- 線上模式（若問題只在線上出現，另列 network／simulation 變數）；
- D3DMetal、DXVK、DXMT 與 WineD3D；
- 音效開啟與 `-nosound`，只把後者當診斷手段，不當正式 workaround。

每次記錄 frame time、CPU 使用率、GPU 使用率、卡頓週期，以及卡頓時是否有
`wineserver` 或音效程序活動。若主選單也會以相同週期卡頓，應降低對遊戲 simulation
與 Rosetta code cache 的先驗判斷；若只在 Apple Silicon 遊戲中且 CPU frame time
暴增，才提高 Rosetta/Wine 假說的優先級。

### Phase 2：引擎 A/B

使用目前 CX26.3.0／Wine 11.0 作為 baseline，至少比較：

1. stock Cyder engine；
2. 只套用可審查的 Rosetta exception patch；
3. 若取得 Marc 的原始 diff，再做獨立 variant；
4. AoE IV 與 AoE II 各自測試，避免只以 AoE IV 成功作為通用證據。

每個 variant 必須同時通過：

- 一般 Wine exception／啟動測試；
- AoE IV 的 frame-time 與穩定性測試；
- AoE II 主選單與遊戲內的週期性卡頓測試；
- 長時間執行、切換視窗、離場與重新啟動測試；
- 至少一款不相關的 x86_64 遊戲回歸測試。

只有在 AoE II 的卡頓能穩定重現、套 patch 後穩定消失，並且沒有一般遊戲回歸，
才應考慮把 patch 加入正式 engine release。若只改善 AoE IV 而 AoE II 不變，應把
它保留為 AoE IV 特定相容性修正，不應擴大成 AoE II workaround。

## 6. 研究結論

目前最合理的產品決策是：

- **不立即納入正式 Cyder release。**
- **在 engine repo 建立小範圍、可回滾的實驗 patch。**
- **先取得 frame-time／CPU evidence，再決定是否測試 Rosetta exception patch。**
- **AoE II 的 5–6 秒卡頓與 2026 年更新後 regression 分開追蹤。**
- **CompatDB 暫不新增全域 AoE II workaround。**

這份文件記錄的是研究與驗證計畫；本次沒有修改 Wine source、engine manifest 或
CompatDB。
