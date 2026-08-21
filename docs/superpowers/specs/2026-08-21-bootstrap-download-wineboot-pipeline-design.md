# Bootstrap：download ∥ wineboot + install 就緒管線

日期：2026-08-21  
狀態：設計已核准（方案 B：install 依就緒順序）  
範圍：`cyder_provision_prefix_baseline` 內 Mono/Gecko 下載與 wineboot／msiexec 的排程。

相關：
- `docs/superpowers/specs/2026-08-20-bootstrap-wineserver-keepalive-design.md`（P2：install 前 MSI 就緒、無 `-p`）
- `docs/superpowers/specs/2026-08-20-first-open-preferences-timeline-design.md`（量測）

## 目標

1. **mono-download、gecko-download、wineboot 三者並行**。
2. wineboot 成功後，**哪個元件 MSI 先就緒就先 install**；另一個就緒且未在 install 時接著裝（互斥鎖／單調度器）。
3. 保留 P2：msiexec 熱路徑不做下載／checksum；wineserver 在 wineboot 後保持可接 MSI。

## 非目標

- 不並行兩個 msiexec（同一 wineserver）。
- 不改 Swift 層 prefetch（可與本管線並存）。
- 不改 MSI 內容、engine tar、產品 UI 行為（progress label 可隨 stage 更新）。
- 不強制 Mono→Gecko 順序（方案 B）；若驗收發現相容問題再退回固定順序。

## 現況問題

目前串行：

```
mono-download → gecko-download → wineboot → mono-install → gecko-install
```

量測（2026-08-21 dry-run）約：download 合計 ~12.6 s + wineboot ~11.3 s 串在安裝前。  
下載彼此無依賴，也非 wineboot 前置；僅 **msiexec 需要對應 MSI 已在磁碟**。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 並行 | mono-dl ∥ gecko-dl ∥ wineboot |
| Install 閘門 | `wineboot OK` ∧ `該元件 download OK` ∧ 取得 install 互斥 |
| Install 順序 | **B：就緒者優先**（可能 Gecko 先於 Mono） |
| 互斥 | 單一調度迴圈一次只跑一個 install（等效鎖） |
| Download 失敗 | 該元件失敗 → 整體失敗；可取消另一 download；wineboot 已成功則 stop wineserver |
| Wineboot 失敗 | kill 進行中的 download；不進 install |
| Skip markers | 既有 `.cyder-mono-*` / `.cyder-gecko-*`：該側視為 download+install 已完成 |
| Timing | 持續寫 `bootstrap-timing.jsonl`；允許時間區間 overlap |

## 架構

```
T0
 ├─ mono-download (bg) ──ready──┐
 ├─ gecko-download (bg) ─ready──┤
 └─ wineboot (+ artifact-wait) ─┴─ wineboot_gate
                                   │
                    scheduler loop │
                    ├─ if mono ready & !done → mono-install
                    ├─ if gecko ready & !done → gecko-install
                    └─ both done → tar → golden → verify
```

### 調度語意（單 shell）

1. 啟動兩個 `--download-only` 背景工作，記錄 PID／log。
2. 前景（或可 wait 的背景）執行既有 `cyder_init_bottle`。
3. wineboot 失敗 → `kill` downloads → return。
4. wineboot 成功後進入迴圈，直到 mono/gecko 兩側都「完成或 skip」：
   - 非阻塞檢查 download 是否結束；結束則標記 `*_dl_ok` 或失敗退出。
   - 若 `mono_dl_ok && !mono_installed` → 跑 mono-install（持有「鎖」期間不開另一 install）。
   - 若 `gecko_dl_ok && !gecko_installed` → 跑 gecko-install。
   - 兩者都還在下載 → 短 sleep 或 `wait -n` 等任一子程序。
5. 接既有 tar / golden / verify。

若某一側已有 skip marker：該側不啟動 download，直接標為 installed。

### Progress

- wineboot 進行中：維持「正在建立 Windows 環境…」。
- 進入某 install：切換對應 Mono／Gecko label（與現況相同）。
- 可選：下載仍在背景時不額外刷 label，避免與 wineboot 文案搶視覺（實作時取簡潔即可）。

### 相依性說明（為何可 B）

- `install-wine-mono.sh` / `install-wine-gecko.sh` 各自獨立 `msiexec`，腳本無交叉前置。
- 歷史串行順序為慣例，非 Cyder 契約。
- 風險：未知 Wine 內部對「Gecko 先於 Mono」的邊角；驗收含首次 prefix 冒煙；若失敗再改固定 Mono→Gecko（閘門仍可不互相等 download）。

## 預期收益（粗估）

相對「串行 download + wineboot」：

- 下載與 wineboot overlap → 省約 `min(Σ downloads, wineboot)` 量級。
- 快的 MSI 可在慢的還在下時先 msiexec → 再省「等較慢 download」的空窗。

實際以隔離 `cyder-measure-first-open-preferences.sh`（或等效）前後對照為準。

## 驗收

1. 隔離 dry-run：`mono-download`、`gecko-download`、`wineboot` 時間區間可重疊。
2. 允許 `gecko-install` 的 start 早於 `mono-install`（若 gecko 先就緒）。
3. 任一時刻不並行兩個 msiexec（log／timing 不重疊）。
4. 成功 prefix 仍有 Mono/Gecko version markers；`healthChecked`／artifact verify 通過。
5. 相關既有 shell／契約測試通過。
6. 文件註明：Swift prefetch 仍為 best-effort；本管線不依賴它。

## Spec self-review

- [x] 無 TBD／placeholder
- [x] 與 P2（MSI 在 msiexec 前就緒、無雙 msiexec）一致
- [x] 方案 B 與錯誤路徑寫清
- [x] 非目標含「不並行 install」
