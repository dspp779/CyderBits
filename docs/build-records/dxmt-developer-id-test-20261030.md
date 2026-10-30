# 2026-10-30 DXMT Developer ID 與 Cyder 測試包

已產生真實簽署產物，僅本機交付，沒有公證、上傳、發布或 commit。

| 項目 | 結果 |
|---|---|
| Cyder | 0.13.2-dev-dxmt-cyder1，Developer ID，arm64 + x86_64 |
| Wine | 既有固定 CX26.3.0-W11-Cyder012；沒有重建引擎 |
| DXMT | 0.80-cyder.1，官方 v0.80 的 Cyder 簽署衍生包 |
| Team | 3U9565WWM2 |
| Native signing identifier | local.cyder.dxmt.0.80-cyder.1.winemetal |
| Native timestamp | Oct 30, 2026 at 2:34:58 AM（codesign 顯示值） |
| Native minOS / SDK | 15.0 / 15.1 |
| 公證／遊戲驗收 | 未公證；遊戲、真實 DXMT 載入與防毒環境待使用者實測 |

DXMT native 原始 SHA-256：`3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca`。

簽署後 native SHA-256：`86937f85da8dd63e0cd9add92709a9f67b6419d5201e16c1af01a28b9eb1ee6f`。

DXMT archive SHA-256：`7b15f1a0717cd754f43fbeb0b5e71fe4a1bcc16a08b3e303ced7492471eb5b81`。

Cyder ZIP：87,373,442 bytes；SHA-256：`86cdd362730104f411854d51c8077475aeaae2e932aed13392aa083411bd1fb2`。

App 原始碼基準 d4b710c，加上目前未提交的元件診斷／簽章政策修改。既有其他工作目錄的修改保留。實際組裝補上 `CYDER_GRAPHICS_ARTIFACTS_DIR` 讀取接線，並校正 Developer ID 測試通道的成品狀態文字。

## 實際通過項目

- 真正 Developer ID 與安全時間戳簽署，完整上游 11 個成員來源 pin 核對。
- DXMT 原生元件的封存前及 archive 解壓後驗章。
- App deep／strict 驗章、arm64／x86_64 slice 驗證。
- 隔離 runtime 快篩：Wine 16 項（145 ms）、DXVK 5 項（33 ms）、DXMT 9 項（170 ms）；整體含 App 信任驗證在 5 秒預算內完成。
- 隔離 runtime 完整掃描：Wine 1,817 項（6,341 ms）、DXVK 15 項（114 ms）、DXMT 14 項（287 ms），均 ok／verified-publisher。此為本次單次實測，不是跨機型效能保證。
- 最終 ZIP 實際解壓，再驗 App、DXMT 及快速診斷，均通過；略過的只有公證檢查。
- 原始 source 與本機既有 DXMT native hash 仍為原來未簽署值，沒有就地補簽。

現有 Developer ID 依專案指南匯入；第一次簽署逾時後使用建置專用暫存鑰匙圈完成。已還原搜尋清單並刪除暫存鑰匙圈／狀態，沒有保存或輸出密碼與私鑰。

主要輸出在 `dist/test-dxmt-cyder1-20261030`（gitignored）；內含 ZIP、README、checksum 與 verification。較大的隔離 runtime 是驗證副本，不是要安裝的成品。
