# BlueCG A6 engine artifact

> 建立日期：2026-07-13

## 發行識別

正式引擎標籤為：

```text
CX26.2.0-W11-Cyder003
```

欄位意義：

| 欄位 | 意義 |
|------|------|
| `CX26.2.0` | CrossOver 26.2.0 基線 |
| `W11` | Wine 11.0 系列 |
| `Cyder003` | Cyder 第三個可辨識 engine 發布版；不暴露內部 A6/R1–R5 實驗編號 |

版本標籤中的句點會由封裝工具轉為連字號，因此正式 artifact 為：

```text
dist/artifacts/a6-final/engine-wine-x86_64-CX26-2-0-W11-Cyder003.tar.xz
```

SHA-256：

```text
fa5984a5379f8ef1d398d6e66736c579bc2a1f9b047b692b46449dab9d8a5cf7
```

Artifact 解開後根目錄為 `wine-x86_64/`，可直接交給 Cyder engine installer。

## 最終 patch 組成

正式 source patch 為：

```text
patches/a6-final-same-view-backing-sync.patch
```

它是以乾淨的 CrossOver 26.2.0 source tree 產生的單一可重放 patch，整合：

1. R1：live resize 期間 per-view 延後 backing sync，結束後提交最終尺寸。
2. R2：final backing sync 改用同一 drawable 的 in-place CGL context update。
3. R3：same-view 的 programmatic resize 也採用 in-place update；真正 view switch 才保留 attach/reset。
4. R5：還原尺寸以 user32 saved normal rect 為權威，避免 Retina frame 轉換造成倍增。

R4 的 deminiaturize frame guard 保留在歷史 patch
`patches/a6-r4-deminimize-frame-guard.patch`，但沒有併入正式 patch。A/B runtime
測試顯示移除 R4 後，拖曳、連續縮放、Alt+Enter、最小化／還原均維持正常，因此
R4 guard 不需要作為正式 runtime 的依賴。

R1–R5 的逐步實驗結果與失敗邊界請見
[`bluecg-winemac-experiments.md`](bluecg-winemac-experiments.md)；原版、A2、A4
的功能／畫質／效能比較請見
[`bluecg-winemac-runtime-comparison.md`](bluecg-winemac-runtime-comparison.md)。

## 建置與重現

目前已驗證的來源 runtime：

```text
install/wine-experiments/a6-final-no-r4
```

重新打包：

```bash
cd /Users/jjc/ogom
CYDER_ENGINE_VERSION_LABEL='CX26.2.0-W11-Cyder003' \
CYDER_ENGINE_ARTIFACTS_DIR="$PWD/dist/artifacts/a6-final" \
WINE_INSTALL="$PWD/install/wine-experiments/a6-final-no-r4" \
bash scripts/pack-engine-artifact.sh --xz --force
```

封裝腳本會對暫存副本執行 strip、dylib relocation、ad-hoc code-sign，再建立
`tar.xz`；不會修改來源 runtime。

## 封裝驗證

已完成下列檢查：

```bash
cd /Users/jjc/ogom
ART='dist/artifacts/a6-final/engine-wine-x86_64-CX26-2-0-W11-Cyder003.tar.xz'
shasum -a 256 -c "$ART.sha256"
tar -xOf "$ART" wine-x86_64/version
tar -xOf "$ART" wine-x86_64/winemac.sha256
tar -tf "$ART" | rg \
  'wine-x86_64/(bin/wine|bin/wineserver|lib/wine/x86_64-unix/winemac.so)$'
```

驗證結果：

- 版本檔為 `CX26.2.0-W11-Cyder003`。
- `wine`、`wineserver`、`winemac.so` 均存在。
- 解開後 `winemac.so` SHA-256 為
  `814358c0b459b3e4b2735b604ba038dd166f72561e9425676b57f323d7aafbab`。
- `codesign --verify --deep --strict` 通過。

## 圖形 runtime 內容

目前正式 artifact 已包含：

```text
wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib
```

它是 x86_64 Wine 的 Vulkan／MoltenVK runtime；不代表 BlueCG 會改走 Vulkan。BlueCG 的已驗證路徑仍是 DirectDraw → wined3d/OpenGL，A6 修復的是 `winemac.drv` 的 GL backing 生命週期。DXVK、dxmt、D3DMetal 目前沒有接入此 artifact。

## BlueCG 驗收矩陣

在 RetinaMode=`y`、DPI 為 96 倍數（目前測試使用 196）下，已由使用者實機確認：

| 操作 | 結果 |
|------|------|
| 拖曳放大／縮小 | 放開後正確滿版，無黑屏 |
| 連續縮放兩三次 | 正常 |
| Alt+Enter 進入／切回視窗 | 正常 |
| 最小化／還原 | 尺寸不再逐次放大，畫面正常 |
| 高 DPI 初始畫面 | 無 A4 的右上黑邊，畫質較清晰 |

正式包的用途是 BlueCG 專用高 DPI runtime；A4 仍可作為不需要 backing sync 的
fallback，A2 則保留作為非 Retina guard-only 對照，不應覆蓋 Cyder 共用 engine。
