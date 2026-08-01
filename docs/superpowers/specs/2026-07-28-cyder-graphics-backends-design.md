# Cyder 0.8.0：圖形後端（DXVK / D3DMetal / WineD3D）設計

日期：2026-07-28  
狀態：已核准（方案 1）  
版本目標：`0.8.0`（正式 CX26）／`0.8.0-maplestory-oem25`（OEM）

## 目標

1. 更新兩份引擎（**cx26**、**oem-25**），內建可驗證的 **DXVK** payload（D3D11/DXGI + 引擎既有 MoltenVK）。
2. App 偏好設定提供圖形轉譯選項：`default` / `wined3d` / `dxvk` / `d3dmetal`，含說明與條件式啟用。
3. **不**把 Apple GPTK 打進可再散布的 engine／公證包；執行期使用本機 CrossOver GPTK，或由使用者從官方評估 DMG 安裝到 Cyder runtime。
4. 選 DXVK 時預設 `DXVK_FRAME_RATE=60`，可改「不限制」。
5. 打包、Developer ID 簽署並公證兩套 App。

## 非目標

- 不內建／再散布 Apple GPTK 或 CrossOver 私有 GPTK 於出貨 artifact。
- 本版不啟用 `D3DM_ENABLE_METALFX`。
- 本版不上架 `dxmt` 為使用者選項（CompatDB schema 可保留，UI 不暴露）。
- 不改變既有 MSync／ESync／Retina 等偏好語意，僅新增圖形相關欄位。

## 決策摘要

| 項目 | 決定 |
|---|---|
| 架構 | 方案 1：App 偏好主導 + runtime 偵測／安裝 GPTK |
| GPTK 出貨 | 引擎不內建；CrossOver 直接用；評估 DMG 可安裝進 runtime |
| 偏好範圍 | 全域預設 + 每遊戲覆寫 |
| 與 CompatDB | 最終值為 `default`（或未設）→ 不覆寫，交給 CompatDB；非 `default` → App 覆寫 |
| DXVK 限幀 | 選 DXVK 時預設 60；可選不限制 |
| D3DMetal OS | 需 macOS ≥ 14，否則選項灰掉 |
| 版本 | 0.8.0 / 0.8.0-maplestory-oem25 |

---

## §1 雙引擎與 DXVK

### 建置與共用

- 以 CrossOver 25.0.1 來源樹中的 DXVK snapshot 建置（`RELEASE`／log 字串為 `v1.10.3`；建置時由 `pin-dxvk-version.py` 釘死，避免吃到 Cyder app git tag）。
- 建置產物：`d3d11.dll` / `dxgi.dll`（x86_64 + i386），**不含** d3d9/d3d10（維持現有 `build-dxvk.sh` 取捨）。
- **同一組 DLL artifact** 安裝進：
  - `install/wine-cx26-x86_64/lib/dxvk/`
  - `install/wine-maplestory-oem25-source-x86_64/lib/dxvk/`（或該 flavor 的正式 engine 路徑）
- 建置／整合時比對兩引擎目標 hash，確認來源未分叉後再共用；若日後 CX26 與 OEM 來源分叉，再拆 artifact。

### Prefix

- bottle bootstrap 繼續呼叫 `install-dxvk-prefix.sh`：有 MoltenVK 才把 DXVK PE 裝進 `system32`／`syswow64`。
- 引擎必須帶 MoltenVK（現況已具備者維持）。

### 引擎 artifact 邊界

- 打包進 App 的 engine **含** `lib/dxvk`。
- 打包進 App 的 engine **不含** `lib64/apple_gptk`。

---

## §2 偏好設定 UI 與 `DXVK_FRAME_RATE`

### 資料模型（settings.json）

建議新增（名稱可在實作微調，語意固定）：

```text
graphicsBackend: "default" | "wined3d" | "dxvk" | "d3dmetal"   // 全域，預設 "default"
dxvkFrameRate: "60" | "unlimited"                              // 僅對 dxvk 有意義；選 dxvk 時預設 "60"
```

每遊戲／profile 覆寫：

```text
graphicsBackend: 同上 | null/省略 = 跟隨全域
dxvkFrameRate: 同上 | null/省略 = 跟隨全域
```

解析順序：遊戲覆寫 → 否則全域 → 得到最終 `graphicsBackend` / `dxvkFrameRate`。

### UI

- 全域：`Cyder 偏好設定` 新增「圖形」區塊。
- 個別遊戲：啟動／遊戲設定提供同一組控制；「跟隨全域」對應未覆寫。

選項說明（文案大意）：

| 值 | 說明 |
|---|---|
| default | 跟隨 CompatDB／引擎預設（建議多數遊戲） |
| wined3d | Wine 內建 Direct3D；相容性較廣，效能通常較差 |
| dxvk | Vulkan→Metal（MoltenVK）；需引擎 DXVK；可限幀 |
| d3dmetal | Apple D3DMetal／GPTK；需 macOS ≥ 14，且本機有 CrossOver GPTK 或已安裝評估版 GPTK |

條件：

- macOS &lt; 14 → `d3dmetal` 灰掉並說明。
- 無可用 GPTK → `d3dmetal` 灰掉；提供安裝／偵測說明與按鈕（§3）。
- 引擎無 DXVK／MoltenVK → `dxvk` 灰掉（0.8.0 出貨引擎不應如此）。

### DXVK 限幀 UI

- 僅當最終後端為 `dxvk` 時顯示：`限制幀率` → **60（預設）**／**不限制**。
- `60` → 啟動環境設 `DXVK_FRAME_RATE=60`。
- `unlimited` → 不設或清除 `DXVK_FRAME_RATE`。
- 後端非 `dxvk` → 不帶此變數。

### 與 CompatDB 的優先序

1. 計算最終 `graphicsBackend`（遊戲覆寫 ∪ 全域）。
2. 若為 `default` → **不**注入後端覆寫；CompatDB `graphics_backend` 與引擎預設照常。
3. 若為 `wined3d` / `dxvk` / `d3dmetal` → App 在啟動路徑注入對應覆寫（環境變數／既有 runtime 選擇器），**壓過**該次啟動的 CompatDB 後端選擇。

實作應對齊現有 `CYDER_GRAPHICS_BACKENDS_ROOT`、`CX_APPLEGPTK_LIBD3DSHARED_PATH`、CompatDB runtime `apply_graphics_backend()` 行為，避免雙重衝突；明確以「App 非 default 覆寫」為準。

---

## §3 GPTK 偵測／安裝與啟動配線

### 可用 GPTK 來源（優先序）

1. **CrossOver**：`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk`  
   - 驗證 `external/libd3dshared.dylib` + `external/D3DMetal.framework`（及 wine 側若需要）。  
   - 完整則 **直接使用**，不複製進 Cyder。
2. **Cyder runtime 副本**：`~/Library/Application Support/Cyder/runtime/apple_gptk/`  
   - 由下方「安裝 Apple GPTK」寫入。
3. 皆無 → `d3dmetal` 不可選。

### 「安裝 Apple GPTK…」

使用者須先開啟 Apple「Evaluation environment for Windows games」DMG 並同意授權；卷名型式：

```text
/Volumes/Evaluation environment for Windows games *
```

例如：

- `/Volumes/Evaluation environment for Windows games 3.0`
- `/Volumes/Evaluation environment for Windows games 4.0 beta 1`

每個候選卷驗證：

```text
<volume>/redist/lib/external/libd3dshared.dylib
<volume>/redist/lib/external/D3DMetal.framework
```

（以及 `redist/lib/wine/` 若存在則一併複製。）

流程：

1. 掃描合格卷，列出版本供使用者 **選擇**。
2. 授權／來源說明提示後，將選中卷的 `redist/lib/` 複製到 `.../Cyder/runtime/apple_gptk/`（安裝前清空或替換舊內容）。
3. 寫入 manifest（來源卷名、顯示版本、安裝時間、內容 hash 可選）。
4. UI 顯示「已安裝：…」；提供 **移除已安裝 GPTK**。
5. 無合格卷 → 提示先掛載 DMG 並同意授權後再重試。

### 啟動（最終後端 = d3dmetal）

- `WINED3DMETAL=1`、`WINEDXVK=0`（或等價 runtime 選擇）。
- `CX_APPLEGPTK_LIBD3DSHARED_PATH` → 選定 GPTK 的 `external/libd3dshared.dylib`。
- `DYLD_FRAMEWORK_PATH` 含該 GPTK 的 `external`（以載入 `D3DMetal.framework`）。
- Wine DLL 搜尋 prepend 該 GPTK 的 `wine/`（對齊 CompatDB／CrossOver 行為）。
- **DXVK 與 D3DMetal 衝突**：若 prefix 已安裝 DXVK native `d3d11`/`dxgi`，啟動配線必須保證 D3DMetal 路徑不會誤載 DXVK。實作擇一寫死並測過，例如：
  - 對該次 process 使用 builtin／GPTK PE + 明確 overrides；或
  - 在切換後端時調整 prefix payload（需可逆，避免弄壞 DXVK 偏好）。

### 不做

- 不把 GPTK 打進 engine tarball 或公證 zip。
- 本版不設 `D3DM_ENABLE_METALFX`。

---

## §4 測試、打包簽署公證與版本

### 測試

- DXVK artifact 裝入 cx26／oem25；`install-dxvk-prefix`；`DXVK_FRAME_RATE=60` 與 unlimited。
- 偏好：全域 + 覆寫；`default` 不覆寫 CompatDB；非 default 注入正確後端。
- D3DMetal：OS gate；無 GPTK 灰掉；CrossOver 可用；多卷 DMG 可選安裝；移除副本。
- 回歸：compatdb／dxvk／app payload 既有測試。

### 產物

| App | Engine | DXVK | GPTK |
|---|---|---|---|
| `Cyder.app` | cx26 | 內建 | 不內建 |
| `Cyder-maplestory-oem25.app` | oem-25 | 內建 | 不內建 |

### 簽署與公證

- Developer ID 簽署 App 與 nested Mach-O。
- `notarytool` → `stapler` → zip。
- 兩套 App 皆公證；流程對齊 `docs/release-signing.zh-TW.md`，必要時補 OEM 專段。

### 版本

- 正式：`0.8.0`
- OEM：`0.8.0-maplestory-oem25`

### 建議一併交付

- 偏好說明短文（GPTK 授權／不可再散布；DXVK 限幀與遊戲內 VSync 關係）。
- 啟動 log 記錄作用中後端與 GPTK 來源（`CrossOver` vs `runtime`），便於除錯。

---

## 架構關係（簡圖）

```text
Settings (global + per-game)
    → resolve backend + dxvkFrameRate
        → default: CompatDB / engine default
        → dxvk: engine lib/dxvk + prefix DLLs + optional DXVK_FRAME_RATE
        → d3dmetal: CrossOver GPTK OR runtime apple_gptk (from DMG)
        → wined3d: force WineD3D
```

## 風險與緩解

| 風險 | 緩解 |
|---|---|
| GPTK 授權／再散布 | 永不打進公證包；僅本機 CrossOver 或使用者自裝 runtime |
| DXVK vs D3DMetal DLL 搶載 | 啟動覆寫策略單測 + MapleStory 手動煙測 |
| OEM 與 cx26 DXVK 來源漂移 | 共用 artifact + hash 檢查 |
| 評估 DMG 目錄結構變更 | 驗證 `redist/lib/external/...`；失敗給明確錯誤 |

## 實作順序（高層）

1. DXVK 建置／裝入兩引擎 + 測試  
2. Settings 模型與偏好 UI  
3. 啟動路徑覆寫 + `DXVK_FRAME_RATE`  
4. GPTK 偵測／安裝／移除 + D3DMetal 閘門  
5. 文件與 0.8.0 打包簽署公證  
