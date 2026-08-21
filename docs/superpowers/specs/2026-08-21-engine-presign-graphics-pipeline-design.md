# Engine 跳過重簽 + 圖形 payload∥wineboot

日期：2026-08-21  
狀態：設計已核准（E1 + G1 + G2）  
範圍：冷安裝引擎簽署成本；bootstrap 圖形 payload 與 winemetal 排程／計時。

相關：
- `docs/superpowers/specs/2026-08-21-bootstrap-download-wineboot-pipeline-design.md`
- 實測 session `750A6DAD…`：engine-install 11.6s（~2s 解壓 + ~9s 重簽）

## 目標

1. **E1**：artifact 已預簽且解壓後 `codesign --verify` 成功則跳過 `sign-wine`；pack 寫入 `.cyder-engine-signed`。
2. **G1**：`graphics-ensure`（必要時拆 payload / winemetal）寫入 `bootstrap-timing.jsonl`。
3. **G2**：DXVK/DXMT payload 解壓與 wineboot 並行；prefix 就緒後再 engine link + winemetal。

## 非目標

- 不改 DXVK/DXMT／engine 編譯內容。
- 不把圖形打進 engine tar。
- 不並行 msiexec。

## 決策摘要

| 項 | 決定 |
|----|------|
| E1 skip | marker 存在 **或** `bin/wine`/`wineloader` verify 成功 → 跳過重簽並確保 marker |
| E1 pack | `sign-wine` 後寫 `.cyder-engine-signed` 再 tar |
| G1 | `graphics-payload`（解壓+link）與 `graphics-winemetal` 分開計時；bootstrap Phase C 使用之 |
| G2 | provision 開始時背景 `cyder_install_graphics_payload`×2；wineboot 後 join → link → winemetal |

## 驗收

1. 冷裝預簽 artifact：engine-install 接近解壓時間，op log 無大量 `replacing existing signature`。
2. timing jsonl 含 `graphics-payload` / `graphics-winemetal`（或等價）。
3. 冷圖形時 payload 與 wineboot 時間區間可重疊。
