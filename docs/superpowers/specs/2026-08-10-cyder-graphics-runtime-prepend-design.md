# Cyder：圖形後端改為 runtime prepend（對齊 CrossOver）

日期：2026-08-10  
狀態：已核准／實作中（自動化契約測試已完成；Wine、封裝 app 與實際遊戲煙測仍待手動驗證）
相關：

- `docs/superpowers/specs/2026-07-28-cyder-graphics-backends-design.md`
- `docs/superpowers/specs/2026-08-08-cyder-dxmt-graphics-backend-design.md`（**貨源位置**：本文件改為 DXMT／DXVK 皆不進 engine tarball，以 runtime graphics payload 為準；DXMT 作為可選後端與 UI 行為仍有效）
- 本機 CrossOver `cxcompatdb.so`／`CXBT_*.pm`（CX 24+ 不再把 DXVK 長期拷進 bottle）

## 目標

1. **不動 bottle 內建 d3d***：system32／syswow64 的 Wine `d3d*`／`dxgi` 保持引擎內建；切換圖形後端只在**啟動時**透過 CompatDB／等同 CrossOver 的 **prepend + load-order** 完成。
2. **DXVK／DXMT 不打進 engine tarball**：改為 app Resources 獨立 graphics payload；開 Cyder.app 時依 version 解壓／更新到 `~/.cyder/runtime/graphics/`（或等價）。
3. **開 Cyder.app**（首次與之後）：檢查／更新 DXVK、DXMT 貨源；GPTK 只檢查 link／目錄是否存在，缺失不擋進入設定。
4. **Finder 直接開 EXE**：不做 graphics version 升級／解壓；仍做當次後端配線。貨源缺失則該後端不可用並退回 default／WineD3D，並提示開啟 Cyder.app。

## 非目標

- 不把 Apple GPTK／D3DMetal 打進公證包或 engine（授權邊界不變）。
- 本版不重做設定 UI 大改版（可加 GPTK／graphics 狀態列）。
- 不引入 bottle 內 symlink 搶 system32 檔名作為主切換手段。
- 不保證舊「已拷入 DXVK／DXMT PE」的 bottle 在未遷移前行為與新模型相同——開 Cyder 時做一次性還原。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 架構 | 對齊 CrossOver：貨源在 runtime 根；bottle 留 Wine 內建；啟動 prepend |
| DXVK loader | 不再依賴 `n,b` + prefix native PE；改為與 DXMT／CX 相同的 prepend／builtin 路徑 |
| Payload 來源 | 隨 app 打包（Resources 內 archive + version／sha sidecar），非網路下載為主路徑 |
| GPTK 缺失 | 軟狀態（設定顯示未偵測到）；不擋開 Cyder |
| Finder EXE | 跳過 ensure-graphics 更新；可啟動則用現有 `current-*` |
| 引擎瘦身 | pack 排除 `lib/dxvk`、`lib/dxmt`；MoltenVK 仍留引擎 |

---

## §1 目標與非目標

見上文「目標」「非目標」。成功標準：

- 切換 wined3d／dxvk／dxmt／d3dmetal **不改變** bottle 內 d3d11／dxgi 檔案 hash（遷移完成後）。
- `CYDER_GRAPHICS_BACKEND=dxvk` 時，`WINEDEBUG=+loaddll` 顯示 d3d11 為 **builtin**，且模組映射位址／來源可證明命中 prepend 的 DXVK（對齊本機 CrossOver 實測：位址異於 Wine 內建）。
- 開 Cyder 可更新過期 graphics payload；Finder 開 EXE 不會觸發解壓更新。

---

## §2 目錄與時序

### 2.1 App 內貨源

```text
Cyder.app/Contents/Resources/
  graphics/
    dxvk-<ver>.tar.zst
    dxvk-version.txt
    dxvk-artifact-sha256.txt
    dxmt-<ver>.tar.zst
    dxmt-version.txt
    dxmt-artifact-sha256.txt
```

Version／sha 使用**分開的 sidecar 檔**（對齊現有 engine-version／engine-artifact-sha256 模式），不用合併 manifest。

打包腳本（`pack-engine-artifact`／`create-cyder-app`）負責產出上述檔案並自 engine 樹**排除** `lib/dxvk`、`lib/dxmt`。MoltenVK 仍在 engine。

### 2.2 本機 runtime 貨源

```text
~/.cyder/runtime/graphics/
  dxvk/<ver>/…                 # 解壓內容（PE 布局對齊現有 lib/dxvk）
  dxmt/<ver>/…                 # 含 x86_64-unix/winemetal.so 等
  current-dxvk → <ver>         # symlink 或 marker
  current-dxmt → <ver>
```

為減少 Wine／CompatDB 改動，提供 **CX 相容視圖**（symlink 即可）：

```text
~/.cyder/runtime/graphics-root/   # 或重用既有 CYDER_GRAPHICS_BACKENDS_ROOT 語意
  lib/dxvk → ../graphics/current-dxvk
  lib/dxmt → ../graphics/current-dxmt
```

啟動時 `CYDER_GRAPHICS_BACKENDS_ROOT` 指向該根（引擎目錄可繼續用於 MoltenVK／Wine 本體；若 loader 要求單一 root，則 graphics-root 需能解析到引擎 MoltenVK，或 patch 允許分根——實作計畫中擇一寫死並測過）。

### 2.3 Bottle

- `drive_c/windows/system32|syswow64/d3d*.dll`、`dxgi.dll`：**Wine 內建**。
- 不再執行（或改為 no-op／僅遷移）`install-dxvk-prefix.sh`、啟動時 `install-dxmt-prefix.sh` 的「覆寫 PE」行為。

### 2.4 GPTK

- 偵測順序不變：`Application Support/Cyder/runtime/apple_gptk` → CrossOver `lib64/apple_gptk`。
- 開 Cyder：只更新 UI／狀態。
- 啟動 `d3dmetal`：既有 link + 環境變數。

### 2.5 開 Cyder.app 時序

1. `ensure-engine`（引擎 tarball／fingerprint）。
2. `ensure-graphics`：比對 Resources sidecar vs `runtime/graphics` → 需要則解壓並更新 `current-*`。
3. GPTK 存在檢查 → 狀態（不擋）。
4. **遷移**：若 bottle 仍含舊 Cyder 拷入的 DXVK／DXMT PE（見 §3）→ 還原為引擎 Wine 內建。
5. 既有 templates-ready／health-check 等。

### 2.6 啟動遊戲時序（含 Finder EXE）

1. 解析後端偏好（`default` 不強制）。
2. 設定 `CYDER_GRAPHICS_BACKEND`／`CX_GRAPHICS_BACKEND`；CompatDB／runtime **prepend** 對應 `lib/dxvk`｜`lib/dxmt`｜GPTK wine。
3. Finder 路徑：**跳過**步驟 2.5 的 ensure-graphics 更新；使用現有 `current-*`。

---

## §3 Wine／CompatDB、遷移、失敗行為

### 3.1 Runtime 對齊 CrossOver

本機 CrossOver（`cxcompatdb.so`／`set_graphics_backend`）行為摘要：

- 貨源在 `CX_ROOT/lib/{dxvk,dxmt}` 與 `lib64/apple_gptk/wine`。
- Bottle 內 d3d11 為 Wine 內建；切換不靠覆寫該檔。
- `CX_GRAPHICS_BACKEND=dxvk` 時 loaddll 為 **builtin**，但映射位址異於 Wine 內建（prepend 命中 DXVK）。
- CX 24+ bottle 升級會**移除**舊拷貝 DXVK 並改環境變數。

Cyder 應對齊：

- 修改／替換現行 `apply_graphics_backend()` 中 **dxvk → `n,b` + 依賴 prefix native** 的分支，改為與 dxmt／CX 相同的 prepend 模型（實作可在 ntdll CompatDB patch 或未來若引入 `cxcompatdb` 等價模組）。
- 以自動化測試鎖定：dxvk 啟動時 builtin 位址／模組路徑可區分於 wined3d。

### 3.2 遷移

觸發：開 Cyder 且 shared（及必要時 profile）bottle 存在。

偵測（擇一或併用，實作計畫寫死）：

- `$PREFIX/.cyder-runtime/dxvk-payload`／`dxmt-payload` 存在；或
- system32 `d3d11.dll` hash 命中已知引擎 `lib/dxvk`／`lib/dxmt`（遷移過渡期可保留 hash 表）或明顯≠當前引擎 Wine 內建。

動作：

1. 自**當前引擎** `lib/wine/{x86_64,i386}-windows/` 複製對應 `d3d9`／`d3d10`／`d3d10_1`／`d3d10core`／`d3d11`／`dxgi` 到 system32／syswow64。
2. 若存在 Cyder 寫入的 `winemetal.dll`（無 Wine 內建對應）：**刪除** system32／syswow64 中該檔。
3. 刪除過期 `.cyder-runtime/dxvk-payload`、`dxmt-payload`。
4. **不**自動清除 `HKCU\\Software\\Wine\\DllOverrides`（避免誤傷使用者／CompatDB 持久設定）；依賴啟動時 process-local load-order 覆寫即可。

### 3.3 失敗行為

| 情境 | 行為 |
|------|------|
| 開 Cyder，graphics 解壓／校驗失敗 | 錯誤 UI；可進設定；dxvk／dxmt 選項不可用 |
| 開 Cyder，無 GPTK | 狀態「未偵測到」；不擋 |
| 啟動 dxvk／dxmt 但 `current-*` 缺失 | 該次後端不可用 → 退回 `default`／等效 WineD3D；log；若為 Finder 路徑另提示開啟 Cyder.app |
| 啟動 d3dmetal 無 GPTK | 既有：不可用／退回 |
| Finder、貨源過期但仍可載入 | 不更新；用現有檔啟動 |
| Finder、貨源完全沒有 | 同上退回 + 提示 |

### 3.4 驗證清單

自動化 fixture／契約測試已覆蓋 payload 打包與 checksum、runtime 解壓與
`current-*`／engine symlink、舊 prefix DLL 還原與 `winemetal.dll` 移除、以及
Cyder 開啟與 Finder `.exe` 路徑的更新分流。下列為尚待具備 Wine、封裝 app
與實際遊戲環境的手動驗證，不可視為已完成遊戲煙測：

- [ ] 新 bottle：bootstrap **不**拷 DXVK；d3d11 hash = 引擎 Wine 內建。
- [ ] 強制 dxvk／dxmt／d3dmetal／wined3d：bottle d3d11 hash 不變；`WINEDEBUG=+loaddll` 行為符合 builtin + prepend 模型。
- [ ] 舊 bottle（曾 install-dxvk-prefix）：開一次 Cyder 後 d3d11 回到 Wine 內建。
- [ ] 開 Cyder 更新 graphics version；Finder 開 EXE 不觸發解壓（可用 marker mtime／log 斷言）。
- [ ] GPTK 缺失不擋開 Cyder。
- [ ] 實際 engine tar 無 `lib/dxvk`／`lib/dxmt`；封裝 app 含 graphics archives；MoltenVK 仍在引擎。

---

## 風險與緩解

| 風險 | 緩解 |
|------|------|
| Cyder `apply_graphics_backend` 與 CX `set_graphics_backend` 行為不一致 | 以 CX 本機 loaddll 位址差為金樣；單測／煙測對齊後再宣告完成 |
| `CYDER_GRAPHICS_BACKENDS_ROOT` 與引擎 MoltenVK 分根 | symlink 視圖或單一 root；計畫中選一種並測 DXVK |
| 遷移誤傷使用者自裝 native d3d | 僅在命中 Cyder marker／已知 hash 時還原；否則跳過並 log |
| OEM MapleStory 曾依賴 prefix DXVK + `n,b` | 遷移後改走 prepend；納入 OEM 煙測 |

## 實作順序（高層，細節見後續 plan）

1. Wine／CompatDB：dxvk 改 prepend 模型 + 測試。
2. Graphics payload 打包／ensure-graphics／current-*。
3. 移除 bootstrap／launch 的 prefix PE provision；加遷移。
4. Finder vs Cyder 路徑分流與失敗文案。
5. Pack gate：engine 無 dxvk／dxmt；app 必帶 graphics archives。

## 參考證據（2026-08-10）

- CrossOver bottle `d3d11.dll` hash = `lib/wine/x86_64-windows/d3d11.dll`，≠ `lib/dxvk`／`lib/dxmt`。
- CrossOver `CX_GRAPHICS_BACKEND=dxvk`：loaddll **builtin**，位址 `0x6A340000`（異於 wined3d 的 `…FF280000`）。
- Cyder 現行 `n,b` + prefix DXVK PE：loaddll **native**；將 override 改 `b` 後落到 Wine 內建而非 `lib/dxvk`——證明須改 loader／CompatDB 路徑，而非只改 Cyder shell。
