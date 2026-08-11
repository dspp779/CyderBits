# Cyder：DXVK 2 圖形後端設計

日期：2026-08-11  
狀態：已核准（方案 1：獨立後端 `dxvk2`；選單標籤採 A）  
相關：

- `docs/superpowers/specs/2026-08-10-cyder-graphics-runtime-prepend-design.md`（payload／prepend／ensure 模型）
- `docs/superpowers/specs/2026-08-08-cyder-dxmt-graphics-backend-design.md`（第三後端上架先例）
- `docs/build-dxvk.zh-TW.md`（1.x／2.x 編譯與目錄）

## 目標

1. 下一版 Cyder.app 隨附 **DXVK 2.7.1** graphics payload（與現有 1.10.3 並列，不互相覆蓋）。
2. 圖形轉譯選單新增 **「DXVK 2」**；既有 **「DXVK」** 仍是 1.10.3。
3. 啟動時 `CYDER_GRAPHICS_BACKEND=dxvk2` 走既有 CompatDB **builtin + prepend**，貨源為 `lib/dxvk2`。

## 非目標

- 不把 1.x 升級成 2.x，也不把 `current-dxvk` 指到 2.x。
- 不改 CompatDB 預設、不改既有規則的 `graphics_backend: dxvk`。
- 不把 `dxvk2` 插入任何自動回退鏈（`default` 仍完全交給 CompatDB）。
- 不重編／不改 DXMT、GPTK、MoltenVK 貨源位置。
- 不把 `lib/dxvk2` 打進 engine tarball。
- 本版不保證所有遊戲在 2.7.1 可玩；只提供可選後端。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 架構 | 方案 1：獨立後端 token `dxvk2`，prepend `ENGINE/lib/dxvk2` |
| 選單 | 「DXVK」= 1.10.3；「DXVK 2」= 2.7.1 |
| Payload | `Resources/graphics/dxvk2-2.7.1.tar.zst` + version／sha sidecar |
| Runtime | `~/.cyder/runtime/graphics/dxvk2/<ver>/`、`current-dxvk2`、engine `lib/dxvk2` symlink |
| 限幀／HUD | 與手動 DXVK 相同（`DXVK_FRAME_RATE`、`DXVK_HUD`） |
| Schema | 9（新增 `dxvk2`；舊 `dxvk` 不遷移） |
| Wine | 必須新 engine：`valid_graphics_backend` 接受 `dxvk2`，否則環境變數覆寫被忽略 |
| 缺貨 | 「DXVK 2」灰掉；啟動 fail-closed 回 `default` |

---

## §1 Payload 與目錄

### 1.1 編譯產物（已存在）

本機 `scripts/build-dxvk2.sh` 已將 stamp 過的 2.7.1 PE 裝到
`ENGINE/lib/dxvk2/{x86_64,i386}-windows/`（`d3d8` `d3d9` `d3d10core` `d3d11` `dxgi`）
與 `lib/dxvk2/version`（`dxvk v2.7.1`）。1.x 仍在 `lib/dxvk`。

### 1.2 App 內貨源

在現有 dxvk／dxmt sidecar 旁增加一組：

```text
Cyder.app/Contents/Resources/graphics/
  dxvk-<ver>.tar.zst
  dxvk-version.txt
  dxvk-artifact-sha256.txt
  dxvk2-2.7.1.tar.zst
  dxvk2-version.txt          # 內容：2.7.1
  dxvk2-artifact-sha256.txt
  dxmt-…
```

`pack-graphics-payloads.sh`：

- 新增 `pack_payload dxvk2 "$ENGINE/lib/dxvk2"`。
- 打包前對 `dxvk2` staging 跑 `stamp-wine-builtin-pe.py`（與 `dxvk` 相同）。
- 缺 `lib/dxvk2/x86_64-windows/d3d11.dll` 或 `version` 則失敗（與 dxvk／dxmt 同等 gate）。
- archive 內頂層目錄名為 `dxvk2/`，對齊 ensure 解壓後 `staging/$name`。

`create-cyder-app.sh` 複製 graphics 目錄的條件改為 **同時**要求 dxvk、dxvk2、dxmt 的 version／sha／`*.tar.zst`。`CYDER_ALLOW_MISSING_GRAPHICS=1` 行為不變。

### 1.3 Runtime 與 engine 視圖

```text
~/.cyder/runtime/graphics/
  dxvk/<ver>/
  dxvk2/<ver>/
  dxmt/<ver>/
  current-dxvk  → dxvk/<ver>
  current-dxvk2 → dxvk2/<ver>
  current-dxmt  → dxmt/<ver>

~/.cyder/runtime/Engines/wine-x86_64/lib/
  dxvk  → 相對路徑到 current-dxvk
  dxvk2 → 相對路徑到 current-dxvk2
  dxmt  → 相對路徑到 current-dxmt
```

`cyder-ensure-graphics.sh` 對 `dxvk2` 呼叫既有 `cyder_install_graphics_payload` 與
`cyder_replace_engine_graphics_link`。Finder 開 EXE 仍跳過 ensure（沿用 prepend 設計）。

`pack-engine-artifact.sh`（ogom 與 `cyder-wine-engine` 副本）排除清單加上 `lib/dxvk2`。
MoltenVK 仍留 engine。

### 1.4 遷移

2.x 從未拷進 bottle，**不加**新的 prefix 還原規則。現有 dxvk／dxmt 遷移不變。

---

## §2 Wine／CompatDB

`CYDER_GRAPHICS_BACKEND` 只有通過 `valid_graphics_backend()` 才會覆寫規則。
因此 **必須**改 patch 並重編／重包帶 CompatDB runtime 的 engine，否則 UI 選「DXVK 2」無效。

修改（CX26 與 OEM25 兩份保持同文）：

- `patches/cyder-compatdb-runtime.patch`
- `patches/cyder-compatdb-runtime-oem25.patch`

| 函式 | 變更 |
|------|------|
| `valid_graphics_backend` | 接受 `dxvk2`（size == 5） |
| `apply_graphics_backend` | MoltenVK 存在檢查對 `dxvk` **與** `dxvk2` 都做；路徑仍是 `root/lib/<backend>`，因此 `dxvk2` 自然落到 `lib/dxvk2` |
| 其餘 | 不改 load-order（仍 `"b"`）與 prepend 模型 |

YAML 規則可以使用 `graphics_backend: dxvk2`，本版**不**新增或改寫任何出貨規則。

`cyder-wine-engine`：套用更新後的 patch、產出下一版 engine artifact。Cyder 下一版 pin 該 engine。

---

## §3 設定與 UI

### 3.1 Schema 9

- `CyderGraphicsBackend` 增加 `case dxvk2`（`rawValue == "dxvk2"`）。
- `schemaVersion = 9`。舊檔 `dxvk` 維持 1.10.3，不遷移。
- 未知後端字串仍消毒成 `default`。
- 舊 Cyder（只懂 schema ≤ 8）讀到 schema 9 時沿用現況：整份設定回退預設。這是可接受的單向升級。

### 3.2 選單順序與文案

全域（`cyder_settings_ui.swift`）：

`預設`、`D3DMetal`、`DXMT`、`DXVK`、`DXVK 2`、`WineD3D`

每遊戲（`cyder_game_library_ui.swift`）在最前多 `跟隨全域`，其餘相同。

- 「DXVK 2」在 payload／MoltenVK 缺失時灰掉，tooltip：「需要已安裝的 DXVK 2 圖形元件」。
- 說明文字：「使用 DXVK 2.7 將 Direct3D 轉為 Vulkan，再由 MoltenVK 轉為 Metal。」
- 「DXVK」說明不變。

### 3.3 能力探測與啟動

- `CyderGraphicsCapabilities` 增加 `hasDxvk2`：`lib/dxvk2/x86_64-windows/d3d11.dll` + 與 DXVK 相同的 MoltenVK 檢查。無 `engineRoot` 時與 `hasDxvk` 一樣預設 `true`（設定頁尚未綁 engine 時不誤灰）。
- `effectiveLaunchBackend`：`dxvk2` 僅在 `hasDxvk2` 時回傳 `.dxvk2`，否則 `nil`（fail-closed，對齊 DXMT）。
- `cyder_apply_graphics_preference`：新增 `dxvk2` 分支，缺 `lib/dxvk2` 則 log 並回 `default`。

### 3.4 限幀與 HUD

下列對 `dxvk` **與** `dxvk2` 皆成立：

- 顯示「限制幀率」；選 60 時設 `DXVK_FRAME_RATE=60`。
- HUD 選單可出現「DXVK HUD」；`resolvedGraphicsHud` 在後端不是這兩者時把 `.dxvk` HUD 收成 `.off`。
- `environment()` 寫入的 `CYDER_GRAPHICS_BACKEND` 為 `dxvk` 或 `dxvk2`（依有效後端）。

`CyderGraphicsHud.dxvk` 仍表示「DXVK 這類 HUD」，不是後端名稱。

---

## §4 失敗行為

| 情境 | 行為 |
|------|------|
| 開 Cyder，dxvk2 解壓／校驗失敗 | 錯誤／軟失敗與現有 graphics 相同；「DXVK 2」不可用；1.x／DXMT 不受影響 |
| 選 DXVK 2 但 `current-dxvk2` 缺失 | 該次回 `default`；Finder 路徑提示先開 Cyder.app |
| CompatDB 規則寫 `dxvk2` 但 payload 不在 | `apply_graphics_backend` 既有 unavailable → WineD3D |
| 只更新 app、engine 仍是舊 CompatDB | `dxvk2` 環境變數被忽略（看起來像 default）。緩解：下一版同時 pin 新 engine |
| 同時開一款 DXVK、一款 DXVK 2 | 允許；兩棵樹獨立 |

---

## §5 驗證

### 自動化（實作時必須綠）

- `tests/test-cyder-pack-graphics-payloads.sh`：產出 dxvk2 archive／sidecar；stamp；engine 排除 `lib/dxvk2`。
- `tests/test-cyder-ensure-graphics.sh`：安裝 `current-dxvk2` 與 `lib/dxvk2` symlink；不改 `current-dxvk`。
- `tests/test-cyder-graphics-prepend-patch.sh` 與 compatdb runtime 測試：`valid_graphics_backend` 含 `dxvk2`；MoltenVK 檢查涵蓋 `dxvk2`。
- `tests/test-cyder-settings-swift.sh`／harness：schema 9 解 `dxvk2`；`environment()` 設 `CYDER_GRAPHICS_BACKEND=dxvk2` 與限幀；HUD 規則。
- UI 契約測試（若已有選單 index 斷言）：新 index 映射。
- `tests/test-cyder-dxvk2.sh` 維持「不寫 `lib/dxvk/`」。

### 手動（封裝後，不阻擋合約測試合併）

- 選 DXVK：log／strings 仍為 `DXVK v1.10.3`；bottle `d3d11` hash = Wine 內建。
- 選 DXVK 2：`WINEDEBUG=+loaddll` 為 builtin，位址異於 WineD3D 與 1.10.3；strings 含 `v2.7.1`。
- 開 Cyder 會安裝 dxvk2；Finder 開 EXE 不升級 payload。

---

## 風險與緩解

| 風險 | 緩解 |
|------|------|
| 只出新 app、舊 engine：選項無效 | 下一版同時 pin 含更新 CompatDB 的 engine |
| 使用者以為「DXVK」已是 2.x | 文案固定「DXVK 2」；說明寫 2.7 |
| 2.7.1 對舊 D3D9 遊戲迴歸 | 預設與 CompatDB 仍走 1.10.3 |
| pack 漏 stamp | pack 對 dxvk2 強制 stamp；契約測試檢查 offset 64 |

## 實作順序（高層）

1. CompatDB patch + 契約測試；engine 重編／重包。
2. pack／ensure／create-app／engine exclude。
3. Swift 設定／UI／啟動環境變數 + harness。
4. 文件（圖形後端、編譯備忘、scripts）。

## 參考

- CompatDB 已用 `snprintf(..., "%s/lib/%s", root, backend)`；token 與目錄名必須同為 `dxvk2`。
- 1.10.3 與 2.7.1 本機 install 樹已分開驗證（戳記、version 檔、互不覆蓋）。
