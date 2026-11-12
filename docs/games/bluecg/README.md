# BlueCG／水藍魔力

BlueCG 是本專案的主要 DirectDraw PE32 驗證遊戲。

## 驗證與產品狀態（2026-11-02）

以下報告記錄指定版本、場景與隔離 runtime 的實測。HALFTONE、GPU helper 與 cnc-ddraw 均未成為 Cyder 的預設功能，沒有新增 BlueCG CompatDB 規則。報告與工具合併不代表實驗引擎已發佈。

| 路徑 | 已完成 | 邊界／待驗證 |
|------|--------|-------------|
| 原始 bitmap 取樣 | 定位 COLORONCOLOR 非整數、非等比拉伸與階梯感 | WineD3D GL／GDI 名稱不決定最後 bitmap 的取樣方式 |
| HALFTONE／GPU 線性 helper | 單開與三開畫質、逐程序 CPU、晶片功率及 API 提交間隔比較 | 預設關閉的引擎原型；提交間隔不是顯示幀時間／輸入延遲 |
| cnc-ddraw 7.1 | HD[1] 32-bit 格式、平滑、保持比例的桌面無邊框全螢幕及退出 | 一般模式、核心 ☰ Reset／Fit／Lock 聯動、多螢幕及 CNC 能耗尚未完整驗證 |
| macOS 原生 fullscreen Space | 已重現裁切／退出異常，另有受控排序修正候選 | [engine #4](https://github.com/dspp779/cyder-wine-engine/issues/4) 保持 open；候選修正在 [Draft PR #6](https://github.com/dspp779/cyder-wine-engine/pull/6)，不能用 CNC 無邊框結果代替驗收 |

功率表的 Combined 為全系統 CPU＋GPU＋ANE 晶片功率估計，並非 Wine 程序瓦數加總或插座整機功率；程序 Energy Impact 是另一種指標。效能問題追蹤 [CyderBits #15](https://github.com/dspp779/CyderBits/issues/15)，記憶體增長追蹤 [engine #5](https://github.com/dspp779/cyder-wine-engine/issues/5)，均保留未完成項目。

## 問題索引

| 類別 | 狀態 | 文件 |
|------|------|------|
| 放大筆畫不均／階梯感 | 已定位指定核心的 COLORONCOLOR 最終 bitmap 拉伸；16 組初始化與 7 組遊戲對照 | [registry／DDRAW／字體根因實測](scaling-root-cause-2026-11-01.zh-TW.md) |
| 最終 bitmap 平滑取樣 | 單開 GDI HALFTONE：邊緣較柔和但模糊，CPU 與晶片功率成本已實測 | [畫質與成本比較](final-blit-halftone-2026-11-01.zh-TW.md) |
| GPU 線性平滑取樣 | 單開 GDI 四組對照：近似 HALFTONE 字體畫質，CPU 與晶片功率成本降低 | [GPU 畫質、CPU、功率與提交間隔](gpu-linear-2026-11-02.zh-TW.md) |
| 三開 GPU 線性取樣 | 四組逐程序／功率／提交間隔與12次生命週期檢查；含戶外場景漂移限制 | [三開完整比較與字體裁圖](triple-gpu-2026-11-02.zh-TW.md) |
| cnc-ddraw 色彩／平滑／官方 ☰ 選單 | HD[1] 指定 32-bit 後排除條紋；桌面無邊框驗收通過，☰ 歸屬核心且聯動仍待測 | [cnc-ddraw 與選單完整對照](cnc-ddraw-2026-11-02.zh-TW.md) |
| 顯示／視窗 resize 黑屏 | 歷史 A6 final patch 已解決當時驗收的 resize 黑屏；不包含上述原生全螢幕缺陷 | [問題總覽與解法矩陣](../../bluecg-winemac-resize-black-screen.md) |
| runtime 比較 | 歷史 baseline、A2、A4、A6 對照與 fallback，不是現行引擎版本清單 | [runtime comparison](../../bluecg-winemac-runtime-comparison.md) |
| A6 engine artifact | 歷史首版 `CX26.2.0-W11-Cyder003`；後續 `CX26.3.0-W11-Cyder008` 納入紀錄 | [artifact 與重現方式](../../bluecg-winemac-a6-engine.md) |
| 歷史實驗 | A1–A6-R5 結果與失敗邊界 | [experiments](../../bluecg-winemac-experiments.md) |
| MIDI／音效 | 觀察到 `dmsynth underrun`；尚未證明會造成遊戲功能失敗 | [MIDI underrun](audio/midi-underrun.md) |

## 使用建議

- 重現歷史 Retina+DPI／resize 結果時，依 [A6 final engine](../../bluecg-winemac-a6-engine.md) artifact 流程核對版本；新的測試請記錄實際引擎版本與模組，不把 Cyder008 當成現行版本。
- 不要把測試 runtime 的 `winemac.so` 或 GPU helper 直接覆蓋所有遊戲共用 engine；產品整合與正式打包仍需獨立驗收。
- 一般建置與啟動流程見 [BlueCG 建置與執行](../../bluecg.md)。
- 驗證改動時依 [BlueCG 測試步驟](testing.md)：App 層走 Cyder.app，引擎／renderer 對照直接用引擎與隔離副本。
