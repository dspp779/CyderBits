# CyderBits Bash 化 Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CyderBits.app 與產出的 game `.app` 執行期不依賴完整 Python 打包器；以 `cyder-common.sh` 為核心，僅 icon 抽取保留 `extract-exe-icon.py`。

**Architecture:** 對齊 Cyder.app：`cyder_create_game_app.sh`（打包）+ `cyder_game_launcher.sh`（game 啟動）+ 擴充 `cyder-common.sh`；`create-cyderbits-app.sh` 改 ship `ogom-scripts/` 與 shell launcher。

**Spec:** [2026-07-06-cyderbits-bash-design.md](../specs/2026-07-06-cyderbits-bash-design.md)

---

## File map (Phase 1)

| File | Responsibility |
|------|----------------|
| `scripts/cyder-common.sh` | 新增 packager / game 共用函式 |
| `scripts/cyder_create_game_app.sh` | 打包 CLI + `--gui`（取代 `.py` 主流程） |
| `scripts/cyder_game_launcher.sh` | 讀 `meta.json` 啟動 Wine |
| `scripts/extract-exe-icon.py` | 自 `.py` 抽出 PE icon → icns |
| `scripts/create-cyderbits-app.sh` | ship shell 腳本；launcher 改 bash |
| `tests/test-cyderbits-app.sh` | 檢查 bundle 內容與 shell 可執行 |
| `tests/test-cyder-create-game-app.sh` | dry-run / mock 打包 smoke |
| `docs/scripts.md`, `docs/cyderbits.md` | 更新 |

退役（Task 7 後）：`cyder_common.py`、`cyder_create_game_app.py`（或移入 `scripts/legacy/` 若待決選是）

---

### Task 1: 擴充 `cyder-common.sh`

**Files:** Modify `scripts/cyder-common.sh`

- [ ] **Step 1:** `CYDER_BOTTLES="$CYDER_SUPPORT/Bottles"` 常數
- [ ] **Step 2:** `cyder_ask_yes_no "prompt" [default_no]` — osascript
- [ ] **Step 3:** `cyder_choose_output_dir [default]` — choose folder
- [ ] **Step 4:** `cyder_slugify name` — 與 Python 版相容
- [ ] **Step 5:** `cyder_apply_mac_hires wine_bin prefix` — 呼叫 `enable-mac-retina-hires.sh`
- [ ] **Step 6:** `cyder_run_wine_exe_with_prefix wine_bin exe prefix` — 泛化 `cyder_run_wine_exe`（非 SharedPrefix）

---

### Task 2: `extract-exe-icon.py`

**Files:** Create `scripts/extract-exe-icon.py`（自 `cyder_create_game_app.py` 遷移 PE/icon 函式）

- [ ] **Step 1:** 遷移 `extract_exe_ico`、`exe_to_icns` 及依賴（iconset 檔名已修正）
- [ ] **Step 2:** CLI：`--exe PATH --icns PATH`；失敗 exit 1
- [ ] **Step 3:** 更新 `tests/test-exe-to-icns.sh` 改 import 新路徑

```bash
python3 scripts/extract-exe-icon.py --exe dist/BlueLauncher.exe --icns /tmp/t.icns
```

---

### Task 3: `cyder_game_launcher.sh`

**Files:** Create `scripts/cyder_game_launcher.sh`

- [ ] **Step 1:** 用法：`cyder_game_launcher.sh /path/to/meta.json`
- [ ] **Step 2:** 解析 meta（`jq` 或 fallback `python3 -c` 讀 JSON）
- [ ] **Step 3:** 解析 engine / prefix / exe 路徑（對應 spec §4.2）
- [ ] **Step 4:** `WINEMSYNC`、`WINEDLLOVERRIDES`、locale、`nohup arch -x86_64 wine …`
- [ ] **Step 5:** 單元測試：fixture `meta.json` + `--dry-run` 印出 cmd

---

### Task 4: `cyder_create_game_app.sh`

**Files:** Create `scripts/cyder_create_game_app.sh`

- [ ] **Step 1:** `source cyder-common.sh`；`getopts` 對齊現有 Python CLI 旗標
- [ ] **Step 2:** `--gui`：choose exe → output → 一連串 `cyder_ask_yes_no`
- [ ] **Step 3:** `cyder_ensure_shared_engine`；bottle `cyder_init_bottle`；hi-res `cyder_apply_mac_hires`
- [ ] **Step 4:** standalone：`rsync --exclude='*.app'`；拒絕或警告 output ⊆ game_dir
- [ ] **Step 5:** 寫 `meta.json`（`jq -n` 或 heredoc）
- [ ] **Step 6:** 呼叫 `extract-exe-icon.py`；失敗時沿用 CyderBits logo 或無 icon
- [ ] **Step 7:** 寫 `Info.plist`、`MacOS/CyderGame` → `exec …/cyder_game_launcher.sh "$RES/meta.json"`
- [ ] **Step 8:** `codesign --force --deep --sign -` game app

---

### Task 5: `create-cyderbits-app.sh`

**Files:** Modify `scripts/create-cyderbits-app.sh`

- [ ] **Step 1:** `ogom-scripts/` 複製：`cyder-common.sh`、`cyder_create_game_app.sh`、`cyder_game_launcher.sh`、`extract-exe-icon.py`、`enable-mac-retina-hires.sh`、`env-x86_64.sh`、`bundle-wine-dylibs.sh`、`sign-wine.sh`
- [ ] **Step 2:** MacOS launcher 改：
  ```bash
  export CYDER_ENGINE_SRC="$RES/engine-payload"
  export CYDER_SCRIPTS="$RES/ogom-scripts"
  exec "$RES/ogom-scripts/cyder_create_game_app.sh" --gui --engine-src "$RES/engine-payload"
  ```
- [ ] **Step 3:** 移除 `cp cyder_create_game_app.py` / `cyder_common.py`
- [ ] **Step 4:** 重建 `dist/CyderBits.app` 並手動 smoke

---

### Task 6: 測試與回歸

- [ ] **Step 1:** 更新 `tests/test-cyderbits-app.sh`（檢查 shell + extract-exe-icon.py）
- [ ] **Step 2:** 新增 `tests/test-cyder-create-game-app.sh`（`--help`、可選 `--dry-run`）
- [ ] **Step 3:** 打包 `BlueLauncher.exe` → game `.app`；雙擊啟動
- [ ] **Step 4:** standalone 輸出 Desktop vs 同層 regression

---

### Task 7: 退役 Python 打包器與文件

**Files:** Delete or legacy; modify `docs/scripts.md`, `docs/cyderbits.md`, `README.md`

- [ ] **Step 1:** 刪除 `cyder_common.py`、`cyder_create_game_app.py`（或 legacy）
- [ ] **Step 2:** `docs/scripts.md` 依賴圖改 bash
- [ ] **Step 3:** `docs/cyderbits.md` CLI 範例改 `bash scripts/cyder_create_game_app.sh`
- [ ] **Step 4:** split design 註記 CyderBits bash 化完成

---

## Phase 2 概要（未排 task）

- game launcher 完全無 Python（純 bash meta 解析或固定 schema）
- icon：`wrestool` 選項或 `--no-exe-icon` 預設 CyderBits logo
- 評估是否連 `extract-exe-icon.py` 一併移除

---

## Execution handoff

Phase 1 完成後 Cyder / CyderBits **執行期依賴對齊**：shell + Wine + 單一小型 Python（僅 build-time icon）。可與 Engine 瘦身 Phase 1 並行實作。
