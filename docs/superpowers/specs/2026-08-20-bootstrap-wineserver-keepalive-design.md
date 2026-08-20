# Bootstrap wineserver keep-alive（P2）

日期：2026-08-20  
狀態：設計已核准（write-and-go）  
範圍：首次 `cyder_provision_prefix_baseline` 內 wineboot → Mono → Gecko 的 wineserver 生命週期。

## 目標

1. wineboot 成功後**不關掉** wineserver，讓後續 Mono/Gecko（及同 baseline 內其他 wine 作業）接上同一個 live server。
2. 以 **artifact 就緒** 取代「等 wineserver 完全退出」作為 wineboot 成功條件。
3. baseline 結束時才統一 `cyder_stop_prefix_wineserver`（既有 verify 路徑）。
4. 用 `bootstrap-timing.jsonl` 量測前後差異。

## 非目標

- 不做 wineboot **前** prestart wineserver（方案 B；prefix 尚未建立，收益小於 keep-alive）。
- 不預裝 Mono/Gecko 進 golden template。
- 不改 MSI 內容、不改 engine tar、不改 Swift UI。

## 現況問題

`cyder_init_bottle` 成功路徑目前會：

1. `wineboot -u`
2. `wineserver -w`（等到 server **退出**；實測約 4.2s）
3. 再 `wineserver -k`
4. Mono/Gecko `msiexec` 各自冷啟動 wineserver

## 決策

| 項目 | 決定 |
|------|------|
| Keep-alive 機制 | **不用** `wineserver -p`；wineboot 後在 ~3s idle 內立刻接 MSI install |
| MSI 就緒 | `mono-download` / `gecko-download` 移到 **wineboot 之前**，熱路徑不做 checksum/下載 |
| Flush 判定 | 輪詢 on-disk `drive_c` / `kernel32.dll`（不等 `system.reg`） |
| 成功路徑 | **不**呼叫 `wineserver -w` / `-k` / `-p` |
| 失敗路徑 | 維持 `-k` + `-w` 清理 |
| 正常關機點 | baseline verify 的 `cyder_stop_prefix_wineserver`（順便 flush .reg） |

## 實驗結論（2026-08-20）

- 只拿掉 `-w`/`-k` 但中間仍做 download：**不夠**（server 會在 idle 後退出）。
- wineboot **前** `-p`：wineboot 本身變慢，整體變差。
- wineboot **後** `-p`：artifact wait 變短，但 wineboot 仍偏慢，整體仍變差。
- **下載提前 + wineboot 後立刻 msiexec（無 `-p`）**：有效。

實測（相對基線）：

| stage | before | after | delta |
|------|-------:|------:|------:|
| wineboot | 14679 | 11698 | -2981 |
| artifact-wait | 4174 | 135 | -4039 |
| mono-install | 5814 | 4780 | -1034 |
| gecko-install | 3018 | 2481 | -537 |
| SUM(excl nested) | 25393 | 20861 | **-4532** |

## 風險與緩解

| 風險 | 緩解 |
|------|------|
| registry 尚未 flush 就往下跑 | artifact 輪詢 + 既有 timeout／ARTIFACT error code |
| wineserver 在 Mono 前意外退出 | Mono/Gecko 本就會自動再起 server；只是失去暖機收益 |
| 失敗留下半殘 session | 失敗路徑仍 `-k`/`-w`；baseline 結尾也 stop |

## 驗收

1. 單元／腳本測試：成功路徑不再出現 `wineserver -k`；失敗路徑仍清理。
2. 實測：`wineboot` 階段不再含「等 server 死掉」的數秒空等；Mono/Gecko install 總時間下降或持平不回退。
3. bootstrap 仍可完成，artifact verify 通過。
