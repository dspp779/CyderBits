# CyderBits Bash 化設計

> **日期**：2026-07-06  
> **狀態**：已核准方向，待分階段實作  
> **Phase 1 計畫**：[2026-07-06-cyderbits-bash-phase1.md](../plans/2026-07-06-cyderbits-bash-phase1.md)  
> **相關**：[Cyder 分流設計](2026-07-05-cyder-cyderbits-split-design.md)、[Cyder Launcher Phase 1](../plans/2026-07-05-cyder-launcher-phase1.md)、[文件索引](../../README.md#未來開發路線)

## 1. 問題

Cyder 執行器已 **bash 化**（`cyder_launcher.sh` + `cyder-common.sh`），`Cyder.app` 執行期 **不依賴 Python**。

CyderBits 仍依賴 Python：

| 元件 | 現況 | Python 用途 |
|------|------|-------------|
| **CyderBits.app** launcher | `python3 cyder_create_game_app.py --gui` | 整個打包 GUI + 建 app |
| **`cyder_common.py`** | 與 `cyder-common.sh` 重複 | engine、bottle、hi-res |
| **`cyder_create_game_app.py`** (~700 行) | 打包主邏輯 | osascript、rsync、PE icon、meta.json |
| **產出的 game `.app`** | `CyderGame` 內嵌 Python heredoc | 讀 `meta.json` 啟動 Wine |

後果：

- 雙軌維護（shell / Python 各一套 helper）
- `CyderBits.app` 須打包 `cyder_common.py`（曾漏檔導致開啟無反應）
- game `.app` 在玩家機器上仍要 `python3`（雖 macOS 通常有，非必要依賴）

## 2. 目標

| 層級 | 目標 |
|------|------|
| **CyderBits.app** | Launcher 改 `exec bash …/cyder_create_game_app.sh --gui`，執行期無 Python |
| **game `.app`** | `CyderGame` 改純 shell（`source` 共用函式 + 讀 `meta.json`） |
| **開發 CLI** | `bash scripts/cyder_create_game_app.sh` 取代 `python3 scripts/cyder_create_game_app.py` |
| **Python 殘留** | 僅 **PE → icon** 保留最小模組（見 §5）；其餘退役 `cyder_common.py` / `cyder_create_game_app.py` |

非目標：

- 用 `winemenubuilder -t` 取代 icon（upstream 僅 `.lnk`；實測 `0x80004005`）
- 用 `sips` 直接讀 `.exe`（實測 `Cannot extract image from file`）
- Phase 1 改 CyderBits Phase 2（bottle-in-app、CoW template）

## 3. 現況對照（Cyder 已做完的範本）

```
Cyder.app
  MacOS/Cyder → cyder_launcher.sh
  Resources/ogom-scripts/
    cyder-common.sh, cyder_launcher.sh, install-*, enable-mac-retina-hires.sh, …
```

CyderBits 應對齊同一模式：

```
CyderBits.app
  MacOS/CyderBits → cyder_create_game_app.sh --gui
  Resources/ogom-scripts/
    cyder-common.sh, cyder_create_game_app.sh, extract-exe-icon.py, …
```

## 4. 方案摘要

### 4.1 打包器 → `cyder_create_game_app.sh`

`source cyder-common.sh`，擴充 packager 專用函式：

| 函式 | 職責 |
|------|------|
| `cyder_ask_yes_no` | osascript 是/否（已有 `cyder_maybe_prompt_exe_association` 可參考） |
| `cyder_choose_output_dir` | choose folder |
| `cyder_slugify` | app / bundle id 用 |
| `cyder_apply_mac_hires` | 包一層呼叫 `enable-mac-retina-hires.sh`（設 `WINEPREFIX`） |
| `cyder_create_game_app` | 主流程（對應現有 `create_game_app()`） |

行為與現有 CLI 旗標一致：

- `--standalone` / `--portable-engine` / `--prefix-mode bottle|game_dir`
- `--no-gecko-prompt` / `--no-mac-hires` / `--no-msync`
- `--gui` / `--exe` / `--output` / `--engine-src`

### 4.2 game 啟動器 → `cyder_game_launcher.sh`

讀 `Contents/Resources/meta.json`，決定：

- `portable_engine` → `Resources/wine` vs `~/Library/.../Engines/`
- `prefix_mode` → `Bottles/<id>` vs `game_dir`
- `standalone` → exe 在 `Resources/game/` vs 原路徑
- `msync` / `no_gecko_prompt` / locale（`cyder_wine_locale_exports`）

以 `cyder_run_wine_exe` 變體啟動（prefix 非 SharedPrefix 時傳入 bottle）。

**meta.json 解析：** 優先 `jq`（macOS 無內建則用最小 bash + `python3 -c` 僅讀 JSON **或** 固定欄位 grep——Phase 1 建議 **內嵌 heredoc python3 只讀 meta** 過渡，Phase 2 改 `jq`/純 bash）。

> **決策（Phase 1）：** game launcher **先** 用純 bash + `jq`（Homebrew 不強制；無 `jq` 時 fallback 精簡 `python3 -c 'import json,sys;…'` 單行）。打包器本體仍全 bash。

### 4.3 Icon → `extract-exe-icon.py`（最小 Python）

保留 PE 解析（`extract_exe_ico` + `exe_to_icns`），自 `cyder_create_game_app.py` **抽出** 至 `scripts/extract-exe-icon.py`：

```bash
python3 "$CYDER_SCRIPTS/extract-exe-icon.py" --exe game.exe --icns AppIcon.icns
```

後段仍為 `sips` + `iconutil`（與 `create-cyder-app.sh` 相同 iconset 檔名）。

打包腳本以 bash 呼叫；**不**把整包 `cyder_create_game_app.py` 打进 app。

### 4.4 退役

| 檔案 | Phase 1 後 |
|------|------------|
| `cyder_common.py` | 刪除或僅留 git 歷史；邏輯已在 `cyder-common.sh` |
| `cyder_create_game_app.py` | 刪除前保留一版 tag；測試遷移後移除 |
| `cyder_launcher.py` | 保留（dev 轉呼叫 shell，可選） |

## 5. 已調查替代方案（不採用為主路徑）

| 方案 | 結果 |
|------|------|
| `winemenubuilder -t game.exe out.png` | 未 patch 的 Wine 只讀 `.lnk`；錯誤 `could not read .lnk, 0x80004005` |
| MR 6489 / 6555（exe 直接 `-t`） | 未合進 upstream；需自建 patch |
| `sips` 直接讀 `.exe` | 失敗；需先 `.ico` |
| `wrestool`（icoutils） | 可行但新增 brew 依賴；可作 Phase 2 選項 |

## 6. 已知 bug（一併修）

### 6.1 Standalone + 輸出目錄 = exe 同層

`rsync -a game_dir/` 會把正在建立的 `*.app` 複製進 `Resources/game/`。

**修復：**

- 預設輸出 `~/Desktop`（GUI 維持，CLI 文件強調）
- standalone `rsync` 排除 `*.app`（`--exclude='*.app'`）
- 若 `output_dir` 與 `exe.parent` 相同且 `standalone=1`，osascript 警告或拒絕

### 6.2 `create-cyderbits-app.sh` 腳本不全

相較 `create-cyder-app.sh`，未複製 `cyder-common.sh`、`enable-mac-retina-hires.sh` 等；bash 化時一併對齊。

## 7. 分 Phase 路線

```text
Phase 1（本設計）
  cyder_create_game_app.sh + cyder_game_launcher.sh
  擴充 cyder-common.sh（packager helpers）
  抽出 extract-exe-icon.py
  更新 create-cyderbits-app.sh、測試、文件
  修 standalone rsync / 輸出路徑

Phase 2（可選）
  meta.json 純 bash（無 jq / 無 python fallback）
  icon：wrestool 或固定 CyderBits logo 開關
  合併 extract-exe-icon 為單檔 PyInstaller / 完全移除 Python
```

與 **Wine Engine 瘦身**、**CyderBits Phase 2（bottle-in-app）** 正交，可獨立排程。

## 8. 測試與驗收

| 閘 | 條件 |
|----|------|
| G0 | `bash scripts/cyder_create_game_app.sh --help` |
| G1 | `open dist/CyderBits.app` → GUI 可完成打包 |
| G2 | 雙擊產出的 game `.app` → Wine 啟動（**無** game app 內嵌 Python） |
| G3 | `BlueLauncher.exe` icon → `AppIcon.icns`（`extract-exe-icon.py`） |
| G4 | `--prefix-mode game_dir` BlueCG smoke |
| G5 | standalone 輸出到 Desktop；同層不再自我打包 |
| G6 | `tests/test-cyderbits-app.sh` 改為檢查 shell 腳本，非 `cyder_common.py` |

## 9. 待決

- [ ] game launcher：Phase 1 用 `jq` 還是單行 `python3 -c` fallback（建議：**jq 優先，無則 python3 讀 json 僅 game 啟動**）
- [ ] `extract-exe-icon.py` 是否隨 CyderBits.app 分發（建議：**是**，體積 <30KB）
- [ ] 退役 `cyder_create_game_app.py` 是否保留 `scripts/legacy/` 一版（建議：**否**，git 歷史足夠）

## 10. 參考

- Cyder shell 化：[2026-07-05-cyder-launcher-phase1.md](../plans/2026-07-05-cyder-launcher-phase1.md)
- Icon 調查：對話紀錄（`sips` / `winemenubuilder` / `exe_to_icns` iconset 修復 commit `84c0611`）
