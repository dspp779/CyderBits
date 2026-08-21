# 全域 MSI 快取 + 每檔下載鎖

日期：2026-08-21  
狀態：設計已核准（方案 2）  
範圍：Wine Mono/Gecko（及共用 `CYDER_DOWNLOADS`）下載路徑與並行安全。

相關：
- `docs/superpowers/specs/2026-08-21-bootstrap-download-wineboot-pipeline-design.md`
- `scripts/install-wine-mono.sh` / `install-wine-gecko.sh` / `cyder-common.sh`（`cyder_init_paths`）

## 目標

1. MSI 快取與 `CYDER_SUPPORT` 解耦：prefetch、bootstrap、隔離 dry-run 共用同一目錄。
2. 同一檔並行下載時以目錄鎖序列化；已完整且 checksum OK 則跳過 curl。

## 非目標

- 不遷移既有 `$CYDER_SUPPORT/downloads` 內舊檔（可手動／日後再做）。
- 不改 MSI 版本／URL／download∥wineboot 調度。
- 不做分散式鎖或跨機器快取。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 預設根目錄 | `$HOME/Library/Application Support/Cyder/downloads` |
| `cyder_init_paths` | 設 `CYDER_DOWNLOADS` 為上述路徑（不再用 `$CYDER_SUPPORT/downloads`）；尊重已 export 的覆寫 |
| 鎖 | `DEST.lock` 以 `mkdir` 原子取得；持鎖者 curl→verify→mv |
| 等鎖 | 短 sleep 重試；逾時（建議 300s）失敗 |
| 雙重檢查 | 取得鎖後再 verify `DEST`，避免重複下載 |

## 驗收

1. `CYDER_SUPPORT` 指向隔離目錄時，MSI 仍落入全域 downloads。
2. 並行兩次同一 `--download-only` 不損壞檔案。
3. 相關 shell 測試通過。
