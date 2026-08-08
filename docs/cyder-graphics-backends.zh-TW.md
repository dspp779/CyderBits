# Cyder 圖形後端（WineD3D / DXVK / DXMT / D3DMetal）

Cyder 0.8.0 起，可在 **Cyder 偏好設定 → 圖形** 或個別遊戲設定中選擇 Direct3D 轉譯方式。多數遊戲建議維持 **跟隨 CompatDB（default）**；僅在相容性或效能需要時才手動覆寫。

## 選項說明

| 選項 | 說明 |
|------|------|
| **default** | 跟隨 CompatDB／引擎預設；不注入後端覆寫 |
| **wined3d** | Wine 內建 Direct3D；相容性較廣，效能通常較差 |
| **dxvk** | Vulkan→Metal（MoltenVK）；需引擎內建 DXVK |
| **dxmt** | Direct3D→Metal（DXMT）；需引擎 `lib/dxmt`（v0.80）與 macOS 14+ |
| **d3dmetal** | Apple D3DMetal／GPTK；需 macOS 14+ 且本機有可用 GPTK |

個別遊戲可覆寫全域設定；選「跟隨全域」表示不覆寫。

## DXVK 限幀 vs 遊戲內 VSync

選 **DXVK** 時會出現 **限制幀率** 選項：

- **60（預設）** — 啟動時設定 `DXVK_FRAME_RATE=60`，由 DXVK 在轉譯層限幀。
- **不限制** — 不設定 `DXVK_FRAME_RATE`，幀率由 GPU／遊戲邏輯決定。

這與遊戲選單內的 **VSync（垂直同步）** 是不同機制：

- DXVK 限幀在 Wine 轉譯層生效，可在遊戲未提供限幀選項時控制負載。
- 若遊戲強制開啟 VSync 或以固定 tick 驅動畫面，實際幀率仍可能卡在遊戲設定的值。
- 兩者同時存在時，以較嚴的限制為準（例如遊戲 VSync 鎖 30 fps 時，DXVK 限 60 不會讓畫面超過 30）。

建議：先試 **60** 限幀觀察 HUD／Activity Monitor；若仍過高或與遊戲 VSync 衝突，再改 **不限制** 或調整遊戲內設定。

## DXMT

DXMT 將 Direct3D 轉譯至 Metal，由 Cyder 封裝 engine 隨附 **上游 v0.80** payload（`lib/dxmt/`，含 `winemetal.so` 與 Windows DLL）。Cyder 不從原始碼建置 DXMT，也不借用 CrossOver 的 `lib/dxmt`。

### 系統需求

- **macOS 14（Sonoma）或更新** — macOS 13 及以下 `dxmt` 選項會灰掉。
- 引擎缺 `lib/dxmt` 完整 payload 時，`dxmt` 選項亦會灰掉。

選 **DXMT** 時不套用 DXVK 限幀（`DXVK_FRAME_RATE`）；限幀選項僅在 **DXVK** 後端出現。

## D3DMetal 與 GPTK

D3DMetal 需要 Apple Game Porting Toolkit（GPTK）。**Cyder 不內建、不隨 App 再散布 GPTK**（公證包與 engine 皆不含 `apple_gptk`）。

### 系統需求

- **macOS 14（Sonoma）或更新** — macOS 13 及以下 `d3dmetal` 選項會灰掉。

### 可用 GPTK 來源

1. **CrossOver（優先）** — 若已安裝 CrossOver，Cyder 會直接使用  
   `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk`  
   無需複製。
2. **Apple 評估 DMG** — 掛載「Evaluation environment for Windows games」卷（例如 `Evaluation environment for Windows games 3.0`），在偏好設定中選擇版本並 **安裝 Apple GPTK**，會複製至  
   `~/Library/Application Support/Cyder/runtime/apple_gptk/`  
   （路徑受 `CYDER_SUPPORT` 影響時以實際設定為準）。

使用前須在 DMG 中 **同意授權**；Cyder 不會代為分發 GPTK 檔案。

### 移除已安裝副本

偏好設定中可 **移除已安裝 GPTK**（僅刪除 Cyder runtime 副本，不影響 CrossOver）。

## 疑難排解

| 狀況 | 處理 |
|------|------|
| D3DMetal 無法選取 | 確認 macOS ≥ 14；安裝 CrossOver 或從評估 DMG 安裝 GPTK |
| DXMT 無法選取 | 確認 macOS ≥ 14；確認 engine 含 `lib/dxmt`（封裝版應已內建 v0.80） |
| DXVK 選項灰掉 | 引擎缺 DXVK／MoltenVK（0.8.0 出貨版不應發生） |
| 改後端後畫面異常 | 先改回 **default** 或 **wined3d** 再重啟遊戲 |
| 限幀無效 | 檢查遊戲是否強制 VSync；見上方「限幀 vs VSync」 |

## 相關文件

- [Cyder 0.8.0 發布說明](releases/v0.8.0.md)
- [Cyder 使用指南](cyder.md)
