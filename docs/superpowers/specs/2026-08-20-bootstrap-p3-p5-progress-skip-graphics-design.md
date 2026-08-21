# Bootstrap P3/P4/P5：progress、idempotent skip、graphics 解耦

日期：2026-08-20  
狀態：設計已核准（方案 A）；**Mono／Gecko skip 條款已過時**（2026-08-21 起 bootstrap 不預裝這兩者，見 `docs/cyder.md`）。P3 progress、tar／golden skip、P5 graphics 解耦仍適用。  
範圍：首次／重跑 `cyder_provision_prefix_baseline` 與 shared bootstrap 的 progress UX、可重入 skip、graphics/winemetal 責任邊界。

相關：`docs/superpowers/specs/2026-08-20-bootstrap-wineserver-keepalive-design.md`（P2）

## 目標

1. **P3**：progress 檔結構化（`stage` / `label` / `elapsed_ms`）；Swift 顯示 label，可選附已用時間；舊純文字仍相容。
2. **P4**：Mono / Gecko / tar / golden 已就緒時 skip install（重跑／半殘修復加速）。
3. **P5**：shared bootstrap 不再對空 prefix 預先 `prepare_graphics`；winemetal／graphics ensure 只在 prefix 存在後做一次（Phase C）。

## 非目標

- 不做子階段清單 UI、不做 ETA。
- 不做「Phase B 成功、Phase C 失敗」半成功狀態機／UI。
- 不預裝 Mono/Gecko 進 golden template（另案）。
- 不改 MSI 內容、不改 engine tar。

## 決策摘要

| 項目 | 決定 |
|------|------|
| Progress 格式 | `key=value` 多行；stderr 仍印 label |
| Swift 顯示 | `label`；`elapsed_ms>0` 時附 `（Ns）` |
| Mono skip | `.cyder-mono-<ver>` 存在 |
| Gecko skip | `.cyder-gecko-<ver>` 存在 |
| tar skip | `drive_c/windows/syswow64/tar.exe` 存在 |
| golden skip | `.cyder-golden-baseline-v2` 存在 |
| download | 仍執行（cheap）；skip 的是 install |
| graphics | `cyder_bootstrap_shared_prefix` 開頭移除 prepare；結尾 ensure 保留（prefix 已存在） |
| Phase C 失敗 | 仍令 bootstrap 失敗（保守） |

## 架構

```
download MSI
→ wineboot (Phase B start)
→ mono/gecko install (skip if markers)
→ tar / golden / graphics-ensure (Phase C; skip where marked)
→ stop wineserver + verify
```

## 驗收

1. progress 檔含 `stage=` / `label=`；Swift 能解析並顯示。
2. 已有 Mono/Gecko/tar/golden marker 時重跑 provision，對應 install 被 skip。
3. shared bootstrap 開頭不再呼叫 `cyder_prepare_graphics_prefix`；結尾仍 `cyder_ensure_graphics`。
4. 相關 shell／Swift 契約測試通過。
