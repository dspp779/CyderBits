# BlueCG／水藍魔力

BlueCG 是本專案的主要 DirectDraw PE32 驗證遊戲。

## 問題索引

| 類別 | 狀態 | 文件 |
|------|------|------|
| 顯示／視窗 resize 黑屏 | **已由 A6 final patch 解決**（BlueCG 專用 engine） | [問題總覽與解法矩陣](../../bluecg-winemac-resize-black-screen.md) |
| runtime 比較 | A6 為目前正式方案；A2、A4 保留作對照／fallback | [runtime comparison](../../bluecg-winemac-runtime-comparison.md) |
| A6 engine artifact | 現行 Cyder：`CX26.3.0-W11-Cyder004`；首版驗收 artifact 為 `CX26.2.0-W11-Cyder003` | [artifact 與重現方式](../../bluecg-winemac-a6-engine.md) |
| 歷史實驗 | A1–A6-R5 結果與失敗邊界 | [experiments](../../bluecg-winemac-experiments.md) |
| MIDI／音效 | 觀察到 `dmsynth underrun`；尚未證明會造成遊戲功能失敗 | [MIDI underrun](audio/midi-underrun.md) |

## 使用建議

- 需要 Retina+DPI 與進入遊戲後 resize、Alt+Enter、最小化／還原時，使用 Cyder 現行 engine（`CX26.3.0-W11-Cyder004`）或 [A6 final engine](../../bluecg-winemac-a6-engine.md) artifact 重現流程。
- 不要把 A6 的 `winemac.so` 直接覆蓋所有遊戲共用 engine；它目前是 BlueCG 專用修復。
- 一般建置與啟動流程見 [BlueCG 建置與執行](../../bluecg.md)。
