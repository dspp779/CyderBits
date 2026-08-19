# 退役 CX25 OEM 與 CX25 建置目標

日期：2026-08-17  
狀態：設計已核准（方案 B）  
範圍：Cyder（`ogom`）與 sibling `cyder-wine-engine`

相關：

- `docs/games/maplestory/oem-cx25-maplestory-patches.md`（歷史研究；保留）
- `cyder-wine-engine/docs/maplestory-cx26-migration-and-test-plan.zh-TW.md`（已寫「不再維護第二套 CX25 source build」）
- `docs/superpowers/specs/2026-07-28-cyder-dxvk-hud-oem-bundle-design.md`（OEM bundle 命名；本次刪除該產品線）

## 目標

1. 刪除 MapleStory OEM 產品線：不能再產出 `Cyder-maplestory-oem25.app`，也不能再 pack OEM25 engine archive。
2. 刪除 CX25 引擎建置目標：`build-wine.sh --cx 25`、`CX_VERSION=25`、`crossover-sources-25.1.1.tar.gz` 解壓路徑全部失敗並退出。
3. 主線只剩正式 `Cyder.app` + CX26。台版新楓之谷走這條路徑。
4. 歷史研究文件與 bisect 證據留下，但活的建置／發佈步驟改成「已退役」。

## 非目標

- 不刪、不重寫 CX26 MapleStory patches（`patches/maplestory-cx26-*.patch`）。
- 不改寫歷史 worklog、舊 release notes、upstream-PR 筆記的過去時態敘述。
- 不把 ogom 裡整份過期的 `scripts/build-wine.sh` 家族搬出 repo；只拿掉其中的 CX25。引擎建置的 canonical owner 仍是 `cyder-wine-engine`。
- 不在 git 裡刪本機產物（`build/cx25`、`install/wine-cx25*`、OEM bottle）。本機清理另做。
- 不把 `crossover-sources-25*.tar.gz` 從開發者磁碟強制刪除（gitignore 的 archives）。
- 不新增「依 MapleStory.exe 在 wineboot 當下寫入 cxbottle.conf」的新功能。

## 決策摘要

| 項目 | 決定 |
|------|------|
| OEM App／engine pack | 刪腳本與 pin，不留 stub |
| `--cx` 旗標 | 留下，只接受 `26`；`25` 明確失敗 |
| 失敗訊息 | 各腳本同一句：`CX25 support was retired; this tree only builds CrossOver 26.` |
| `prepare-build-deps --all` | 只準備 CX26 |
| OEM flavor runtime | 刪 `CYDER_OEM_FLAVOR`、`CyderOEMBootstrap`、`cyder_is_maplestory_oem` |
| MapleStory locale | 既有 `resolve-wine-locale.sh`（預設 `zh_TW.UTF-8`） |
| MapleStory raw audio | CX26 `maplestory-cx26-core.patch`；不再靠 OEM `RAW_AUDIO_PARSE` cxbottle 注入 |
| `oem25-bisect/` 與 OEM 研究文 | 保留；README／索引加退役句 |
| 本機目錄 | 不進這次 commit |

---

## §1 引擎：CX25 建置目標退役

Canonical 修改在 `/Users/jjc/cyder-wine-engine`。ogom 仍追蹤一份舊複本（`scripts/build-wine.sh`、`env-x86_64.sh`、`prepare-build-deps.sh`、`build-graphics-stack.sh`），必須做**同樣的 CX25 拒絕**，否則 ogom 測試會繼續把 CX25 當活路徑。

### 1.1 接受的版本

- `CX_VERSION` 預設 `26`。
- `--cx` 只接受 `26`。
- `--cx 25`、`CX_VERSION=25`、`prepare-build-deps.sh --cx 25` 都以 exit 1 結束，stderr 含：

```text
CX25 support was retired; this tree only builds CrossOver 26.
```

不要再用 `Unknown --cx value: 25 (expected 25 or 26)`，那會暗示 25 仍是合法值。

### 1.2 要改的腳本

| 檔案（兩 repo 各一份，除非註明） | 行為 |
|------|------|
| `scripts/env-x86_64.sh` | 刪 `25)` prefix 分支；只留 CX26 source／install |
| `scripts/build-wine.sh` | help 改 `--cx 26`；case 只接受 26；25 走退役訊息。可刪「`--maplestory` 僅支援 cx 26」的雙重檢查，因為 25 已進不來 |
| `scripts/prepare-build-deps.sh` | 刪 `crossover-sources-25.1.1.tar.gz` 對應；`--all` 與無參數預設都只準備 26 |
| `scripts/build-graphics-stack.sh` | 同 `--cx` 規則 |
| `scripts/build-media-stack.sh` | `--cx 25` 改用同一句退役訊息（engine 這份已拒絕非 26） |

只存在於 engine：

- 刪 `scripts/pack-maplestory-oem25-engine.sh`
- 刪 `config/engine-release-maplestory-oem25.json`

### 1.3 測試契約（取代「CX25 不得套 CX26 patch」）

CX25 無法建置之後，舊的「dry-run CX25 不得出現 frame-walk patch」沒有意義。改成：

1. `bash scripts/build-wine.sh --cx 25 --dry-run` 失敗，輸出含退役訊息。
2. `CX_VERSION=25 source scripts/env-x86_64.sh` 失敗，輸出含退役訊息。
3. `bash scripts/prepare-build-deps.sh --cx 25 --dry-run` 失敗，輸出含退役訊息。
4. `bash scripts/prepare-build-deps.sh --all --dry-run` **不得**出現 `crossover-sources-25.1.1.tar.gz` 或 `build/cx25`。
5. `test-maplestory-patch-stack.sh`：`--cx 25 --maplestory` 改斷言退役訊息（不再斷言 `supports only --cx 26`）。
6. CX26 dry-run 與 MapleStory patch stack 測試維持不變。

ogom 與 engine 的 `tests/test-build-wine.sh` 都要改。ogom 另有 `tests/test-env-x86_64.sh`、`tests/test-prepare-build-deps.sh`。

---

## §2 Cyder：刪 OEM 產品線

只存在於 ogom。刪檔，不留 wrapper：

- `scripts/create-cyder-maplestory-oem-app.sh`
- `scripts/cyder_maplestory_oem_main.sh`
- `scripts/cyder_oem_bootstrap_main.sh`
- `config/cyder-oem-engine-archive.txt`
- `config/cyder-oem-engine-version.txt`
- `patches/maplestory-oem25-source-distversion.patch`
- 根目錄 `test.sh`（CX25 `wineboot` 一次性實驗）

`scripts/release-cyder.sh` 本來就不包 OEM，不需為 OEM 加開關。

---

## §3 共用 runtime：拿掉 OEM flavor，留下 MapleStory.exe 行為

### 3.1 刪除

- `scripts/cyder_app_main.swift` 的 `CYDER_OEM_BOOTSTRAP_HELPER` / `oem-prepare` 分支。
- `scripts/cyder_settings.swift` 的 `CyderProduct.isMapleStoryOEM`。
- `scripts/cyder-common.sh` 的 `cyder_is_maplestory_oem`。
- `cyder_seed_crossover_bottle_conf` 依 OEM flavor 注入 `RAW_AUDIO_PARSE` 與 cxbottle `LANG`/`LC_*`。
- `cyder_apply_graphics_runtime_preferences` 裡 `|| cyder_is_maplestory_oem` 的 DXVK 限幀特例。

### 3.2 保留並收斂

- `cyder_is_maplestory_executable`：WZ cache 只靠 `MapleStory.exe` 檔名。
- 全域 Wine locale：`scripts/resolve-wine-locale.sh`（明確 env > macOS locale > `zh_TW.UTF-8`）。
- CX26 MapleStory 相容：engine 的 `maplestory-cx26-*.patch`（含 raw audio parser）。

不在 bottle 建立當下依 exe 名稱補寫 cxbottle.conf：那時還沒有 exe，且 CX26 正式路徑不依賴 OEM Perl flavor。

### 3.3 測試

- `tests/test-cyder-app-payload.sh`：刪對 `create-cyder-maplestory-oem-app.sh` 內容的斷言。
- `tests/test-cyder-crossover-bottle-conf.sh`：刪 OEM flavor 注入案例；generic seed 仍不得寫 `RAW_AUDIO_PARSE`。engine／bottle 名稱覆寫案例改用中性名稱（例如 `custom-engine` / `custom-bottle`），不要再用 `maplestory-oem25`。
- `tests/test-cyder-settings-swift.sh` 與 `tests/fixtures/cyder_settings_harness.swift`：刪 `CYDER_OEM_FLAVOR` / `isMapleStoryOEM`；保留「global default 仍是 `.default`」的圖形斷言。
- `tests/test-cyder-dxvk-multi-engine.sh`：若預設路徑指向 `install/wine-maplestory-oem25-source-x86_64`，改成 CX26 install prefix 或既有 env override，不再預設 OEM tree。

---

## §4 文件政策

### 4.1 活文件（改成 CX26-only / OEM 已退役）

ogom：

- `README.md`、`README.zh-TW.md`：刪 `build-wine.sh --cx 25` 與 `install/wine-cx25-x86_64` 樹狀說明。
- `docs/release-pipeline.zh-TW.md`、`docs/release-signing.zh-TW.md`：OEM pack／公證步驟改為「已退役，改走正式 Cyder + CX26」。
- `docs/games/maplestory/README.md`：調查主線改為 CX26 正式版；OEM 建置指令改退役說明，研究文連結保留。
- `docs/project-development-dashboard.zh-TW.md`：OEM 特別版整合改退役。
- `.github/ISSUE_TEMPLATE/cyder-problem-report.yml`：刪 `Cyder-maplestory-oem` 選項與文案。
- `patches/README.md`：OEM source distversion 列為歷史；`oem25-bisect/` 標「不再建 OEM／CX25 引擎」。

engine：

- `README.md`
- `AGENTS.md`、`.cursor/rules/incremental-build-and-patches.mdc`、`docs/incremental-build-and-patches.md`：把「frame-walk／wineserver 為 CX26-only、勿套到 CX25」收成「此樹只建 CX26」。
- `patches/README.md`：同上。
- `docs/engine-development-test-workflow.zh-TW.md` 若仍寫 `--cx 25`，刪掉活指令。

歷史 debug 文（例如 `docs/maplestory-classic-cx26-frame-walk-debug.md`）裡「CX25 排除測試」改成指向退役契約即可，不必重寫實驗過程。

### 4.2 歷史文件（保留，只加退役句）

在索引或文首加一句，不改結論：

- `docs/games/maplestory/oem-cx25-maplestory-patches.md`
- `docs/games/maplestory/oem-engine-differences.md`
- `docs/games/maplestory/oem25-tw-success-baseline.md`
- `docs/maplestory-oem25-dxvk-d3dmetal-test.md`
- `docs/upstream-prs/maplestory-oem25-distversion.md`
- `patches/oem25-bisect/README.md` 與 group 檔
- `docs/releases/v0.7.0*.md`、`v0.8.0*.md`
- engine `docs/maplestory-cx26-worklog.zh-TW.md`（實驗日誌，保持原樣；最多在文首註「CX25 OEM 建置已退役」）

退役句固定用語：

> CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

---

## §5 驗證

ogom（清理後仍存在的測試）：

```bash
bash tests/test-build-wine.sh
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-crossover-bottle-conf.sh
bash tests/test-cyder-settings-swift.sh
bash tests/test-cyder-dxvk-multi-engine.sh
```

engine：

```bash
bash tests/test-build-wine.sh
bash tests/test-maplestory-patch-stack.sh
```

理想上再跑 `bash tests/run.sh`（engine 全套）。不重編 Wine、不打包 App。

---

## §6 本機產物（不進 git）

實作 commit 不 `rm -rf` 這些路徑。需要時另清：

- `build/cx25/`、`install/wine-cx25-x86_64`、`install/wine-cx25-source-x86_64`
- `install/wine-maplestory-oem25*`
- `ogom/dist/artifacts/maplestory-oem25/`
- `~/Library/Application Support/Cyder-maplestory-oem25`
- `~/.cyder/runtime/Engines/maplestory-oem25`

---

## 實作順序

1. engine：拒絕 CX25 + 刪 OEM pack + 改測試。
2. ogom：同步拒絕 CX25（舊 `build-wine.sh` 家族）+ 改對應測試。
3. ogom：刪 OEM App 腳本／pin／`test.sh` + 瘦身 runtime + 改 Cyder 測試。
4. 兩 repo：活文件改退役；歷史文加一句。
5. 跑 §5 測試。
