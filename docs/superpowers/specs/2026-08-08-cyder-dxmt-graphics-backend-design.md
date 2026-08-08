# Cyder：DXMT 圖形後端設計

日期：2026-08-08  
狀態：已核准（方案 1）  
相關：`docs/superpowers/specs/2026-07-28-cyder-graphics-backends-design.md`（0.8.0 刻意不上架 DXMT；本文件取代該限制）

## 目標

1. 將上游 **DXMT** 預編譯 payload 裝進 **CX26** 與 **OEM25** engine 的 `lib/dxmt/`。
2. App 偏好設定／遊戲覆寫提供 **DXMT** 作為圖形轉譯選項之一。
3. **移除**圖形後端的 **自動／`auto`** 選項；產品預設改為 **`default`（跟隨 CompatDB）**（含 OEM）。
4. 啟動時以 `CYDER_GRAPHICS_BACKEND=dxmt` 走既有 Wine CompatDB runtime `apply_graphics_backend()`。

## 非目標

- 不從原始碼建置 DXMT（本版使用上游 release tarball）。
- 不借用 `/Applications/CrossOver.app/.../lib/dxmt`（與 DXVK／CompatDB「backend 由 engine payload 負責」一致）。
- 不把 DXMT 納入任何 auto cascade（`auto` 整項移除）。
- 不改變 Apple GPTK／D3DMetal 授權邊界；不啟用 MetalFX。
- 不在本版強制所有遊戲改用 DXMT。

## 決策摘要

| 項目 | 決定 |
|---|---|
| 架構 | 方案 1：上游預編譯 → 雙引擎 `lib/dxmt` → pack gate → UI／啟動 |
| 來源 | [3Shain/dxmt](https://github.com/3Shain/dxmt) release **v0.80** `dxmt-v0.80-builtin.tar.gz` |
| 授權 | v0.80 為最後一個 **MIT** release；之後上游改 LGPL，升級需另開 |
| 引擎範圍 | CX26 與 MapleStory OEM25 都帶 |
| 預設後端 | 一律 `default`（跟隨 CompatDB）；移除 `auto` |
| OS | macOS ≥ 14 才可選 `dxmt`（與上游要求一致；`< 14` 灰掉） |
| CrossOver 借用 | 否 |

---

## §1 Payload：下載、釘版、安裝

### 釘版

- URL：`https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz`
- SHA-256（GitHub asset digest）：`8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`
- 腳本（建議名）：`scripts/fetch-dxmt.sh`（ogom，對齊 `build-dxvk.sh`／多引擎安裝模式）
  - 下載（可快取）→ 校驗 checksum → 展開
  - 安裝到一個或多個 `--engine`／`--also-engine` 目標的 `lib/dxmt/`
  - 寫入 `lib/dxmt/version`（或同等 pin 檔）：版本、來源 URL、checksum

### 目標布局（與 CrossOver／CompatDB 文件一致）

```text
lib/dxmt/
  version                 # pin 紀錄
  i386-windows/           # d3d11.dll, dxgi.dll, d3d10core.dll, winemetal.dll, …
  x86_64-windows/         # 同上（及上游若提供的 nvapi 等可選模組）
  x86_64-unix/
    winemetal.so
```

- `apply_graphics_backend()` 對 `dxmt` 已檢查 `x86_64-unix/winemetal.so` 與對應 Windows DLL 路徑。
- tarball 內部目錄若與上述不完全一致，由 fetch 腳本正規化到此布局；不得依賴 CrossOver.app。
- 一併保留／標註上游 LICENSE（v0.80 MIT）。

### 雙引擎

同一組 artifact 安裝進：

- `install/wine-cx26-x86_64/lib/dxmt/`（或以正式 CX26 install 路徑為準）
- MapleStory OEM25 engine install 的 `lib/dxmt/`

與 DXVK 相同：必要時支援一次命令寫入兩個 engine。

### Pack gate（`cyder-wine-engine`）

- `scripts/pack-engine-artifact.sh`（及相關測試）將 **`lib/dxmt` 完整性** 列為出貨條件，對齊現有 DXVK gate：
  - 至少：`x86_64-windows/d3d11.dll`、`x86_64-windows/dxgi.dll`、`x86_64-unix/winemetal.so`
  - 缺則失敗，不產出可發布 artifact
- 引擎仍 **不含** `apple_gptk`。

### 相容性風險

- 上游 **builtin** 產物假設 Wine 具備 DXMT 所需的 `winemac` 可見符號。若 Cyder Wine 無法載入 `winemetal.so`，本版先以診斷／文件記錄；修復路徑為補 Wine patch 或改自建 DXMT（另開，不在本 scope 默默降級為借用 CrossOver）。

---

## §2 偏好設定與 UI

### 資料模型

`CyderGraphicsBackend`（及 settings JSON）：

```text
"default" | "wined3d" | "dxvk" | "dxmt" | "d3dmetal"
```

- **移除** `auto`。
- 讀取時若遇到歷史值 `"auto"` → **遷移為 `"default"`**（寫回可在下次儲存時完成）。
- `CyderProduct.defaultGraphicsBackend`：**一律 `.default`**（OEM 不再預設 `.auto`）。
- OEM 不再把 `default` 改寫成 `auto`；也不再隱藏「跟隨 CompatDB／預設」選項。

### UI 選項（全域 + 每遊戲覆寫）

| 值 | 說明（文案大意） |
|---|---|
| default | 跟隨 CompatDB／引擎預設（建議多數遊戲） |
| wined3d | Wine 內建 Direct3D |
| dxvk | Direct3D → Vulkan → Metal（MoltenVK）；可限幀 |
| dxmt | Direct3D → Metal（DXMT）；需引擎 `lib/dxmt` 與 macOS ≥ 14 |
| d3dmetal | Apple D3DMetal／GPTK；需 macOS ≥ 14 與可用 GPTK |

條件：

- macOS &lt; 14 → `dxmt`、`d3dmetal` 灰掉並說明。
- 引擎缺 DXMT payload → `dxmt` 灰掉。
- 無可用 GPTK → `d3dmetal` 灰掉（既有行為）。
- DXVK 限幀控制仍 **僅**在有效後端為 `dxvk` 時顯示。

### 與 CompatDB

1. 計算最終 `graphicsBackend`（遊戲覆寫 ∪ 全域）。
2. `default` → **不**注入 App 後端覆寫。
3. `wined3d` / `dxvk` / `dxmt` / `d3dmetal` → 設定 `CYDER_GRAPHICS_BACKEND`（及既有 `CX_GRAPHICS_BACKEND` 對齊），強制 `apply_graphics_backend()`。

CompatDB schema／action enum **已含** `dxmt`，無需改 schema。

---

## §3 啟動路徑

- `scripts/cyder-common.sh` 與相關設定載入：接受 `dxmt`；**刪除**對 `auto` 的 cascade（`cascadePreferredBackend`／OEM 特例）。
- 選 `dxmt` 時不設 `DXVK_FRAME_RATE`（限幀仍屬 DXVK）。
- 診斷 preamble／環境 harness：可記錄 `CX_ACTIVE_GRAPHICS_BACKEND=dxmt`（由 Wine runtime 寫入）。
- 缺 payload 時：既有 runtime 行為為診斷並回退 WineD3D；UI 應盡量在選項層就灰掉，避免誤導。

---

## §4 文件與產品狀態

更新（實作計畫中列具體檔案）：

- `docs/cyder-graphics-backends.zh-TW.md`：加入 DXMT；移除「自動」敘述（若有）。
- `README.md`／`README.zh-TW.md` 圖形後端狀態表：dxmt 改為已整合（隨 engine 出貨）。
- 既有 0.8.0 設計中「不上架 dxmt」以本文件為準。

---

## §5 測試

最少涵蓋：

1. **fetch-dxmt**：checksum 失敗拒絕安裝；成功後雙引擎布局含 `winemetal.so` 與 d3d11/dxgi。
2. **settings**：無 `auto` case；`"auto"` 輸入遷移為 `default`；預設為 `default`（含 OEM harness）。
3. **UI／force-settings**：選項列表含 DXMT、不含「自動」；OEM 仍可見「預設／跟隨 CompatDB」。
4. **啟動 env**：偏好 `dxmt` → `CYDER_GRAPHICS_BACKEND=dxmt`。
5. **pack gate**（engine repo）：缺 `lib/dxmt` 關鍵檔則失敗。

---

## §6 實作邊界

| 區域 | Repo |
|---|---|
| `fetch-dxmt.sh`、App UI、settings、cyder-common、ogom 測試與使用者文件 | **ogom（Cyder）** |
| `pack-engine-artifact` DXMT gate、engine 出貨測試 | **cyder-wine-engine** |
| Wine `apply_graphics_backend`（已支援 dxmt） | 僅在不相容時再開 patch；本版預設不改 |

---

## 核准紀錄

- 2026-08-08：確認方案 1（上游預編譯進雙引擎）、釘 v0.80、移除 auto、預設 `default`。
