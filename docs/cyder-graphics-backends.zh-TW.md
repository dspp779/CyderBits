# Cyder 圖形後端（WineD3D / DXVK / DXVK 2 / DXMT / D3DMetal）

Cyder 0.8.0 起，可在 **Cyder 偏好設定 → 圖形** 或個別遊戲設定中選擇 Direct3D 轉譯方式。多數遊戲建議維持 **跟隨 CompatDB（default）**；僅在相容性或效能需要時才手動覆寫。

## 選項說明

| 選項 | 說明 |
|------|------|
| **default** | 跟隨 CompatDB／引擎預設；不注入後端覆寫 |
| **wined3d** | Wine 內建 Direct3D；相容性較廣，效能通常較差 |
| **dxvk** | Vulkan→Metal（MoltenVK）；需 Cyder 已安裝 DXVK runtime payload |
| **dxvk2** | DXVK 2.7（Vulkan→Metal）；需已安裝 DXVK 2 runtime payload |
| **dxmt** | Direct3D→Metal（DXMT）；需 Cyder 已安裝 DXMT runtime payload 與 macOS 15+ |
| **d3dmetal** | Apple D3DMetal／GPTK；需 macOS 14+ 且本機有可用 GPTK |

個別遊戲可覆寫全域設定；選「跟隨全域」表示不覆寫。

## Runtime 圖形元件與啟動方式

步驟圖與打包／安裝／prepend 關係見
[引擎、圖形轉譯層與 Runtime 載入](cyder-graphics-runtime-pipeline.zh-TW.md)。

DXVK、DXVK 2 與 DXMT 是 Cyder.app 內 `Resources/graphics/` 的獨立 payload，不再包在
Wine engine archive。Cyder.app 開啟時會依 version／SHA-256 sidecar 將 payload
解壓到 `~/.cyder/runtime/graphics/`，再由 engine 的 `lib/dxvk`／`lib/dxvk2`／`lib/dxmt`
相對 symlink 指向目前版本（`current-dxvk`／`current-dxvk2`／`current-dxmt`）；MoltenVK 仍由 Wine engine 提供。

切換 DXVK、DXMT、D3DMetal 或 WineD3D 不會把後端 DLL 拷進 bottle 的
`system32`／`syswow64`。這些位置維持 Wine 內建 `d3d*`／`dxgi`；Wine 的
CompatDB 在遊戲啟動時以 **builtin + prepend** 方式從 runtime payload 載入選定後端。
舊版 Cyder 曾寫入 DXVK／DXMT DLL 的 bottle，會在開啟 Cyder.app 時遷移回 Wine
內建 DLL（不會清除使用者的 DllOverrides registry 設定）。

- **從 Cyder.app 開啟設定或遊戲庫**：會先確認 engine，更新 graphics payload，並對未使用中的 shared bottle 執行遷移。
- **在 Finder 直接開啟 `.exe`**：不解壓或升級 payload，只使用現有 `current-dxvk`／`current-dxvk2`／`current-dxmt`。若所選後端（含 DXVK 2）完全不存在，該次會回退到 default／WineD3D，並提示先開啟 Cyder.app。
- **GPTK**：只更新偵測狀態；未安裝不會阻止開啟 Cyder.app。

## 限幀 vs 遊戲內 VSync

選 **DXVK**、**DXVK 2** 或 **DXMT** 時會出現 **限制幀率** 選項：

- **60（預設）／120／144** — DXVK 家族設 `DXVK_FRAME_RATE`；DXMT 合併進 `DXMT_CONFIG` 的 `d3d11.preferredMaxFrameRate`。
- **不限制** — 不設 `DXVK_FRAME_RATE`，並從既有 `DXMT_CONFIG` 拿掉限幀鍵。

這與遊戲選單內的 **VSync（垂直同步）** 是不同機制：

- DXVK 限幀在轉譯層生效；DXMT 則由 Metal／CoreAnimation 控節奏。兩者都可在遊戲未提供限幀時控制負載。
- 若遊戲強制開啟 VSync 或以固定 tick 驅動畫面，實際幀率仍可能卡在遊戲設定的值。
- 兩者同時存在時，以較嚴的限制為準（例如遊戲 VSync 鎖 30 fps 時，DXVK 限 60 不會讓畫面超過 30）。

建議：先試 **60** 限幀觀察 HUD／Activity Monitor；若仍過高或與遊戲 VSync 衝突，再改 **不限制** 或調整遊戲內設定。

## DXMT

DXMT 將 Direct3D 轉譯至 Metal。Cyder 隨 app 打包 **上游 v0.80** DXMT runtime payload（`Resources/graphics/dxmt-*.tar.zst`，含 `winemetal.so` 與 Windows DLL）；開啟 Cyder.app 時由 ensure-graphics 解壓至 `~/.cyder/runtime/graphics/`，並透過 engine `lib/dxmt` symlink 指向 `current-dxmt`（見上方「Runtime 圖形元件與啟動方式」）。Cyder 不從原始碼建置 DXMT，也不借用 CrossOver 的 `lib/dxmt`。

### 系統需求

- **macOS 15（Sequoia）或更新** — macOS 14 及以下 `dxmt` 選項會灰掉（不同於 D3DMetal 的 macOS 14+ 門檻）。
- **DXMT runtime payload 已安裝** — 尚未解壓或 `current-dxmt` 不存在時，`dxmt` 選項會灰掉；請先開啟 Cyder.app 完成 ensure-graphics。

選 **DXMT** 時限幀走 `DXMT_CONFIG`（Metal／CoreAnimation 節奏），不是 `DXVK_FRAME_RATE`。DXMT 的數值最好是螢幕刷新率的因數（例如 60Hz 上選 144 可能實際落到較低的整除值）。

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
| DXMT 無法選取 | 確認 macOS ≥ 15；先開啟 Cyder.app，使 DXMT runtime payload 安裝完成 |
| DXVK 選項灰掉 | 先開啟 Cyder.app，使 DXVK runtime payload 安裝完成；同時確認 engine 有 MoltenVK |
| DXVK 2 選項灰掉 | 先開啟 Cyder.app 完成 ensure-graphics |
| 改後端後畫面異常 | 先改回 **default** 或 **wined3d** 再重啟遊戲 |
| 限幀無效 | 檢查遊戲是否強制 VSync；見上方「限幀 vs VSync」 |

## 驗證狀態

已由自動化 fixture／契約測試覆蓋：graphics archive 的 version 與 checksum、
runtime 解壓與 `current-*`／engine symlink 更新、舊 bottle DLL 還原與
`winemetal.dll` 移除、以及 Cyder 開啟與 Finder `.exe` 路徑的更新分流。

下列仍須在具備 Wine、已封裝 Cyder.app 與實際遊戲的環境手動確認；尚未宣告遊戲煙測完成：

- 新 bottle bootstrap 未拷 DXVK，且 `d3d11.dll` hash 等於 Wine 內建版本。
- 強制 dxvk／dxmt／d3dmetal／wined3d 時，bottle hash 不變，`WINEDEBUG=+loaddll` 顯示 builtin + prepend 行為。
- 曾安裝舊 DXVK 的真實 bottle 在開啟 Cyder.app 後完成遷移。
- Cyder.app 會升級 payload、Finder 不會（以 log 或 marker mtime 確認）。
- GPTK 缺失仍可進入 Cyder.app；實際 engine tar 無 `lib/dxvk`／`lib/dxmt`、app 含 `Resources/graphics/` 且 engine 仍有 MoltenVK。

## 相關文件

- [引擎、圖形轉譯層與 Runtime 載入](cyder-graphics-runtime-pipeline.zh-TW.md)
- [DXVK 編譯備忘（1.x / 2.x）](build-dxvk.zh-TW.md)
- [Cyder 0.8.0 發布說明](releases/v0.8.0.md)
- [Cyder 使用指南](cyder.md)
