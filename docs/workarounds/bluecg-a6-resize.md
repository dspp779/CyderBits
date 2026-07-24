# BlueCG A6 resize workaround

BlueCG 的視窗 resize 黑屏已由 [`patches/a6-final-same-view-backing-sync.patch`](../../patches/a6-final-same-view-backing-sync.patch) 解決。正式組合為 R1、R2、R3、R5；R4 只保留作歷史實驗，不應另行疊加。

正式 engine：`CX26.3.0-W11-Cyder004`（Cyder 現行封裝；含 A6 same-view backing sync）。首版 A6 驗收 artifact `CX26.2.0-W11-Cyder003` 與 SHA-256 見 [A6 engine artifact](../bluecg-winemac-a6-engine.md)。目前已驗收：

- RetinaMode + 高 DPI 下拖曳放大／縮小不黑屏
- 進入／離開 Alt+Enter 不黑屏
- 最小化／還原不再逐次放大
- 高 DPI render target 能跟隨，沒有 A4 的右上黑邊

這是 BlueCG 專用的 winemac.drv workaround；尚未證明適合所有 OpenGL、DirectDraw 或 3D 遊戲。完整解法矩陣見 [BlueCG resize 追蹤](../bluecg-winemac-resize-black-screen.md)。
