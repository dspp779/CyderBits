# 遊戲問題文件

這裡是專案內「依遊戲」整理的入口；建置、產品設計與歷史實驗仍放在 `docs/` 根目錄及 `docs/superpowers/`。

## 總覽

- 📋 **[遊戲相容性矩陣 (Compatibility Matrix)](compatibility-matrix.md)** — 彙整所有已測試單機與線上遊戲之相容性狀態、設定參數與已知 workaround。
- 🎮 **[圖形後端偏好](../cyder-graphics-backends.zh-TW.md)** — Cyder 0.8.0+ 全域／每遊戲 WineD3D、DXVK、D3DMetal 選項與 GPTK 需求。
- 🔎 **GameHub／CrossOver 上游設定盤點** — 見 sibling repo `cyder-wine-engine` 的 [`docs/crossover-gamehub-compatibility-settings.zh-TW.md`](../../../cyder-wine-engine/docs/crossover-gamehub-compatibility-settings.zh-TW.md)（GameSir argv HACK、`crossover.tie`、`cxfixes.xml`）。

## 遊戲

| 遊戲 | 狀態 | 入口 |
|------|------|------|
| 遊戲相容性總表 | 彙整單機／線上遊戲測試紀錄 | [相容性矩陣](compatibility-matrix.md) |
| BlueCG／水藍魔力 | A6 same-view backing sync 已通過 Retina+DPI resize 驗收；MIDI underrun 仍列為待釐清雜訊 | [BlueCG](bluecg/README.md) |
| 皮卡丘打排球 | MSync、ESync 與含空白的 Wine runtime 路徑均列為相容性問題；目前以無同步、無空白實體 runtime 作為 workaround | [皮卡丘排球](pikachu-volleyball/README.md) |
| 楓之谷（台灣 Beanfun／經典版） | 正式 Cyder + CX26 可跑新楓之谷；OEM-25 僅歷史紀錄 | [研究入口](maplestory/README.md) · [經典版凍結](../maplestory-classic-wineserver-hang.md) · [GRAP 殘留](maplestory/grap-core64-residual-process-analysis.md) |
| Steam | 自動套用 system compositor 與 CEF sandbox 相容參數；Windows 遊戲仍需逐款驗證 | [Steam](steam/README.md) |

## 建議文件結構

```text
docs/games/
├── bluecg/
│   ├── README.md
│   ├── display/       # 視窗、Retina、resize
│   ├── runtime/       # Wine engine、patch、版本比較
│   └── audio/         # MIDI、音效與 underrun
├── pikachu-volleyball/
│   ├── README.md
│   └── runtime-path-and-sync.md
└── maplestory/
    ├── README.md
    ├── oem-cx25-maplestory-patches.md
    └── …
```

目前既有的詳細研究文件仍位於 `docs/bluecg-*.md`；子目錄提供按問題分類的穩定入口，避免複製兩份容易失真的長篇內容。
