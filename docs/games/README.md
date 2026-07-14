# 遊戲問題文件

這裡是專案內「依遊戲」整理的入口；建置、產品設計與歷史實驗仍放在 `docs/` 根目錄及 `docs/superpowers/`。

## 遊戲

| 遊戲 | 狀態 | 入口 |
|------|------|------|
| BlueCG／水藍魔力 | A6 same-view backing sync 已通過 Retina+DPI resize 驗收；MIDI underrun 仍列為待釐清雜訊 | [BlueCG](bluecg/README.md) |
| 皮卡丘打排球 | MSync、ESync 與含空白的 Wine runtime 路徑均列為相容性問題；目前以無同步、無空白實體 runtime 作為 workaround | [皮卡丘排球](pikachu-volleyball/README.md) |

## 建議文件結構

```text
docs/games/
├── bluecg/
│   ├── README.md
│   ├── display/       # 視窗、Retina、resize
│   ├── runtime/       # Wine engine、patch、版本比較
│   └── audio/         # MIDI、音效與 underrun
└── pikachu-volleyball/
    ├── README.md
    └── runtime-path-and-sync.md
```

目前既有的詳細研究文件仍位於 `docs/bluecg-*.md`；子目錄提供按問題分類的穩定入口，避免複製兩份容易失真的長篇內容。
