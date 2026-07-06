# Cyder / CyderBits 產品分流設計

> **日期**：2026-07-05  
> **狀態**：已核准（brainstorming）  
> **品牌**：CyderBits（repo）· **Cyder.app**（無腦執行器）· **CyderBits.app**（硬核打包器）

## 背景

Cyder MVP 目前以單一 `Cyder.app` 打包 `.exe` 為 game `.app`，每個 app 建立獨立 UUID bottle（`~/Library/Application Support/Cyder/Bottles/`），刪除 app 不刪 bottle，測試時容量快速膨脹（每 bottle ~1.3 GB，含 mono）。

產品將分流為兩個獨立 `.app`，共用 Wine 引擎，但 prefix 策略不同。

## 決策摘要

| 項目 | 決策 |
|------|------|
| 產品形態 | 兩個獨立 `.app`：Cyder.app + CyderBits.app，可分開下載 |
| Cyder prefix | **全機唯一** `SharedPrefix`；所有 `.exe` 共用；BlueCG 亦同（接受衝突 / workaround） |
| BlueCG game_dir | 開發測試用，**非** Cyder 正式路徑 |
| Cyder 開檔方式 | A 檔案關聯 + B 雙擊選檔 + C 拖放（三者皆要） |
| Wine 引擎 | 共用 `Application Support/Cyder/Engines/`；CyderBits 可選 `--portable-engine` 內嵌 |
| CyderBits bottle | Phase 2：預設 APFS `cp -c` clone template；進階可空白 bottle；Phase 1 維持現狀 |
| 開發優先 | **Phase 1：Cyder 執行器 MVP**；CyderBits 暫改名/分流，行為不變 |

## 架構方案（Cyder MVP）

採用 **方案 1：共用 Prefix + 直接啟動**。

```
Cyder.app
  → ensure_engine()           # Engines/wine-x86_64
  → ensure_shared_prefix()    # 全機唯一 SharedPrefix
  → bootstrap (mono, tar, hi-res, mshtml off)
  → wine exe（cwd = exe 目錄）
```

不採 per-exe bottle（現狀）、不採 MVP 級 registry snapshot（方案 2）。

## 產品定位

| 產品 | 角色 | Phase 1 |
|------|------|---------|
| **Cyder.app** | 無腦執行器：裝一次，開任何 `.exe` | 主力開發 |
| **CyderBits.app** | 硬核打包器：自訂 bottle、可選元件、產生 game `.app` | 現有 `cyder_create_game_app.py` 流程，改名/換入口 |
| **CyderBits（repo）** | 開源總品牌：CrossOver Wine 建置 + 工具鏈 | README 維持 |

## Application Support 佈局

```text
~/Library/Application Support/Cyder/
  Engines/wine-x86_64/          # 共用 Wine（Cyder / CyderBits 預設）
  SharedPrefix/                 # Cyder 全機唯一 WINEPREFIX
    drive_c/windows/syswow64/   # tar.exe (bsdtar) + libarchive DLLs
    drive_c/windows/mono/       # wine-mono
    system.reg / user.reg
    .cyder-bootstrap-v1         # bootstrap 完成 marker
  Addons/                       # 可選 payload 快取
    libarchive-2.4.12/          # GnuWin bsdtar + deps（LGPL，附 LICENSE）
  Templates/                    # Phase 2 CyderBits CoW；Phase 1 可預留
  Bottles/                      # Phase 1 CyderBits 仍使用；Cyder 不使用
```

## Cyder.app 行為

### 首次 bootstrap（idempotent）

1. 從 `Contents/Resources/engine-payload/` 安裝引擎至 `Engines/`（沿用 `ensure_shared_engine`）。
2. 若 `SharedPrefix/system.reg` 不存在 → `wineboot -u`。
3. 一次性（有 marker 則跳過）：
   - `install-wine-mono.sh` 邏輯 → prefix 內 mono
   - `install-libarchive-tar.sh` 邏輯 → `syswow64/tar.exe` + DLLs
   - `apply_mac_hires` → RetinaMode + LogPixels=192
   - `WINEDLLOVERRIDES=mshtml=`（避免 Gecko 提示）
4. 寫入 `SharedPrefix/.cyder-bootstrap-v1`。

### 三種開檔

| 方式 | 實作 |
|------|------|
| **A 檔案關聯** | `Info.plist`：`CFBundleDocumentTypes` + UTType for `.exe`；可提示設為預設 |
| **B 雙擊 Cyder** | 無 argv → 檔案選擇器（osascript / NSOpenPanel） |
| **C 拖放** | `on open` / argv 解析 `.exe` 路徑 |

### 執行環境

```text
WINEPREFIX = ~/Library/Application Support/Cyder/SharedPrefix
cwd        = dirname(exe)
LANG/LC_ALL = resolve-wine-locale（AppleLocale → fallback zh_TW.UTF-8）
WINEMSYNC  = 1
```

不建立 game `.app`、不寫 per-game `meta.json`（Phase 1）。

### BlueCG 在 SharedPrefix 下

- 遊戲檔留在原目錄（如 `BlueCrossgateNew/`）；Wine 環境共用。
- 大 zip（`BlueCG_client.zip`）依賴 `syswow64/tar.exe`；小 patch 用 Launcher 內建 zip。
- DLL / registry 衝突：文件註明風險；必要時改用 CyderBits 獨立 bottle（Phase 2）。
- 開發路徑 `scripts/run-bluecg.sh` + 獨立 `WINEPREFIX` **保留**，不經 Cyder.app。

## CyderBits.app（Phase 1）

- 現有 `create-cyder-app.sh` / `cyder_create_game_app.py` 定位為 **CyderBits 打包器**。
- 新建 **Cyder.app** 為執行器（新 launcher + Info.plist）。
- 腳本分流（名稱可調）：
  - `create-cyder-app.sh` → 建 Cyder 執行器
  - `create-cyderbits-app.sh` → 建 CyderBits 打包器（現邏輯）
- Phase 1 仍用 `Bottles/<uuid>/`；CoW template、bottle 進 app 屬 Phase 2。

## 共用引擎

- 預設：`Engines/wine-x86_64` 兩 app 共用。
- CyderBits `--portable-engine`：game app 內嵌 `Resources/wine/`（現有旗標）。
- 以 marker / `engine_version` 字串追蹤版本。

## libarchive tar（Addons）

- 來源：GnuWin libarchive 2.4.12（32-bit PE）→ `syswow64/tar.exe`（bsdtar 改名）。
- 檔案：`tar.exe`, `libarchive2.dll`, `bzip2.dll`, `zlib1.dll`。
- Cyder bootstrap 預裝；CyderBits Phase 2 可選。
- 授權：LGPL；`tools/libarchive/LICENSE` 或 `Addons/` 內附來源說明。

## Phase 2（CyderBits 重構，非 Phase 1）

- Bottle 置於 `MyGame.app/Contents/Resources/prefix/`。
- Golden template + APFS `cp -cR`（預設）；進階「空白 bottle」。
- 可選：hi-res、tar、mono、winetricks、複製 exe/目錄、Program Files 安裝。
- Bottle 生命週期綁定 app（刪 app 可選刪 prefix）。

## Phase 3（後續）

- 容器管理 UI、orphan bottle prune、穩定 bottle_id 重用。
- Cyder「加入最愛」、多引擎版本切換（若需要）。

## Wine Engine 瘦身（並行路線，非 CyderBits Phase 編號）

縮小 `Cyder.app` / `CyderBits.app` 內嵌 `engine-payload`（Windows on Wine PE + 非 runtime 檔）。與 CoW bottle、容器 UI 正交，可獨立排程。

| Phase | 摘要 | 預估 app / engine |
|-------|------|-------------------|
| **1** | `strip-wine-install` + Plan B-1 allowlist + 保守 Plan C | ~820 MB |
| **2** | 精簡 Wine build（對齊 Sikarugir PE ~295 MB） | ~300 MB engine |
| **3** | App 不內嵌 engine，首次下載 tar.xz | ~4 MB app + 下載 |

詳見 [2026-07-06-wine-engine-slim-design.md](2026-07-06-wine-engine-slim-design.md) 與 [Phase 1 實作計畫](../plans/2026-07-06-wine-engine-slim-phase1.md)。

## CyderBits Bash 化（並行路線）

`Cyder.app` 已改 `cyder_launcher.sh`；**CyderBits.app** 仍依賴 `cyder_create_game_app.py` + `cyder_common.py`，且產出的 game `.app` 內嵌 Python 啟動器。

| Phase | 摘要 |
|-------|------|
| **1** | `cyder_create_game_app.sh`、`cyder_game_launcher.sh`、擴充 `cyder-common.sh`；icon 抽出 `extract-exe-icon.py` |
| **2** | 可選：game meta 純 bash、`wrestool` icon、完全零 Python |

詳見 [2026-07-06-cyderbits-bash-design.md](2026-07-06-cyderbits-bash-design.md) 與 [Phase 1 實作計畫](../plans/2026-07-06-cyderbits-bash-phase1.md)。

## Phase 1 明確不做（YAGNI）

- CyderBits CoW / bottle-in-app
- Winetricks GUI
- Cyder per-game meta / 書籤
- 自動 prune 舊 `Bottles/`（可另提供手動腳本）
- Registry snapshot 隔離

## 測試計畫（Phase 1）

| 項目 | 驗證 |
|------|------|
| Bootstrap | SharedPrefix 含 mono、syswow64/tar、RetinaMode |
| 開檔 A/B/C | 小 exe smoke；BlueLauncher 啟動 |
| 引擎共用 | Cyder 裝引擎後 CyderBits 不重複安裝 |
| BlueCG 大 zip | 僅 exe + SharedPrefix tar → client.zip 可解 |
| BlueCG 小 patch | 完整遊戲目錄 → 增量更新 |
| 回歸 | `run-bluecg.sh` 開發路徑不受影響 |

## 相關文件

- [2026-07-04-cyder-mvp-design.md](2026-07-04-cyder-mvp-design.md) — 原 MVP（將由本 spec  supersede 部分決策）
- [docs/cyder.md](../../cyder.md) — 使用者文件（Phase 1 實作後更新）
- [docs/bluecg.md](../../bluecg.md) — BlueCG 開發路徑

## 修訂紀錄

| 日期 | 說明 |
|------|------|
| 2026-07-05 | 初版（brainstorming 核准） |
