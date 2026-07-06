# Wine Engine 瘦身 Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在打包 Cyder.app 前，對 `install/wine-x86_64` 剝除非 runtime 檔案並 prune Windows PE（Plan B-1 + 保守 Plan C），預估 engine 從 ~997 MB PE + 64 MB 雜項 → 省 **~180 MB**，且不破坏 BlueLauncher / bootstrap。

**Architecture:** 新增 allowlist/manifest 與 `strip-wine-install.sh`、`prune-wine-pefiles.sh`；`create-cyder-app.sh` / `create-cyderbits-app.sh` 在 rsync 前對 staging copy 操作（不直接改開發用 `install/` 除非 opt-in）。分析腳本可 diff Sikarugir 重建清單。

**Tech Stack:** bash、Wine x86_64 install tree、現有 `verify-bluecg.sh` / `test-cyder-bootstrap.sh`

**Spec:** [2026-07-06-wine-engine-slim-design.md](../specs/2026-07-06-wine-engine-slim-design.md)

**後續 Phase（本 plan 不實作）：**

- **Phase 2：** 精簡 Wine build（B-2，PE ~295 MB）— 見 spec §6  
- **Phase 3：** App 不內嵌 engine、首次下載 tar.xz — 見 spec §6  

---

## File map (Phase 1)

| File | Responsibility |
|------|----------------|
| `tools/wine-pe-allowlist/sikarugir-x64.txt` | Sikarugir x86_64-windows 檔名（小寫，一行一檔） |
| `tools/wine-pe-allowlist/sikarugir-x86.txt` | Sikarugir i386-windows 檔名 |
| `tools/wine-pe-allowlist/cyder-default.categories` | Plan C 類別 → glob 規則 |
| `scripts/analyze-wine-pe.sh` | 量測、B/C 報告、可選更新 allowlist |
| `scripts/strip-wine-install.sh` | 刪 include、share/man、dev bin、lib/**/*.a |
| `scripts/prune-wine-pefiles.sh` | `--plan b1` / `--plan c --profile cyder-default` |
| `scripts/create-cyder-app.sh` | staging copy → strip → prune → rsync |
| `scripts/create-cyderbits-app.sh` | 同上 |
| `tests/test-strip-wine-install.sh` | include/.a 已刪、wine 仍在 |
| `tests/test-prune-wine-pe-b1.sh` | B-1 後檔名 ⊆ allowlist ∪ 必要核心 |
| `docs/scripts.md` | 腳本表 |
| `docs/cyder.md` | 一句話：engine 已 prune（可選） |

---

### Task 1: 匯出 Sikarugir allowlist

**Files:**
- Create: `tools/wine-pe-allowlist/sikarugir-x64.txt`
- Create: `tools/wine-pe-allowlist/sikarugir-x86.txt`
- Create: `scripts/analyze-wine-pe.sh`

- [ ] **Step 1:** 實作 `analyze-wine-pe.sh export-sikarugir`，從 `dist/Sikarugir/Engines/wswine.bundle/lib/wine/*-windows` 匯出檔名（小寫）至 `tools/wine-pe-allowlist/`  
- [ ] **Step 2:** 提交 allowlist（~743 + ~802 行）  
- [ ] **Step 3:** 同腳本 `report` 子命令：印 Cyder vs Sikarugir 大小表（spec §2 格式）

---

### Task 2: `strip-wine-install.sh`

**Files:**
- Create: `scripts/strip-wine-install.sh`
- Test: `tests/test-strip-wine-install.sh`

- [ ] **Step 1:** 接受 `WINE_ROOT` 參數；刪除：
  - `$WINE_ROOT/include/`
  - `$WINE_ROOT/share/man/`
  - `$WINE_ROOT/bin/` 內 `winegcc`, `widl`, `wrc`, `wmc`, `winebuild`（保留 `wine`, `wine64`, `wineserver` 等 runtime）
  - `$WINE_ROOT/lib/wine/*-windows/**/*.a` 與 `$WINE_ROOT/lib/**/*.a`（若存在）
- [ ] **Step 2:** `--dry-run` 只印將刪路徑與估算 bytes  
- [ ] **Step 3:** 測試：對 temp copy 的 mini tree 或本機 `install/` copy 驗證  

```bash
bash tests/test-strip-wine-install.sh
```

---

### Task 3: Plan C category manifest

**Files:**
- Create: `tools/wine-pe-allowlist/cyder-default.categories`

- [ ] **Step 1:** 定義類別（spec §5 Plan C 表）：
  - `legacy_ie_html`：`mshtml*.dll`, `ieframe.dll`, `shdocvw.dll`, `jscript.dll`, `vbscript.dll`, …
  - `printing`：`winspool*`, `localspl.dll`, `spoolss.dll`, …
  - `media_codecs`：`quartz.dll`, `qcap.dll`, `qedit.dll`, …
  - `odbc_database`, `scanner_imaging`, `fax_modem`, `telephony`
  - **排除類別（永不刪）：** `dotnet_keep` → `mscoree.dll`, `fusion.dll`（預設只保留不刪）
  - **可選類別（預設 skip）：** `msxml_optional`
- [ ] **Step 2:** profile `cyder-default` = ie + printing + media + odbc + scanner + fax + telephony  

---

### Task 4: `prune-wine-pefiles.sh`

**Files:**
- Create: `scripts/prune-wine-pefiles.sh`
- Test: `tests/test-prune-wine-pe-b1.sh`

- [ ] **Step 1:** `--plan b1`：在 `x86_64-windows` / `i386-windows` 刪除**不在**對應 `sikarugir-*.txt` 內的檔（大小寫不敏感）  
- [ ] **Step 2:** `--plan c --profile cyder-default`：依 manifest 刪匹配檔（兩棵樹）  
- [ ] **Step 3:** `--dry-run`、刪除前後 `du` 摘要  
- [ ] **Step 4:** 測試 B-1：staging 後檔名數 ≤ allowlist + 記錄刪除數  

```bash
bash tests/test-prune-wine-pe-b1.sh
```

---

### Task 5: 整合打包流程

**Files:**
- Modify: `scripts/create-cyder-app.sh`
- Modify: `scripts/create-cyderbits-app.sh`

- [ ] **Step 1:** 在 `bundle-wine-dylibs` / `sign-wine` 之後：
  1. `STAGING=$(mktemp -d)`  
  2. `rsync -a "$WINE_INSTALL/" "$STAGING/"`  
  3. `bash scripts/strip-wine-install.sh "$STAGING"`  
  4. `bash scripts/prune-wine-pefiles.sh --plan b1 "$STAGING"`  
  5. `bash scripts/prune-wine-pefiles.sh --plan c --profile cyder-default "$STAGING"`  
  6. `rsync -a "$STAGING/" "$RES/engine-payload/"`  
- [ ] **Step 2:** 印出 engine-payload `du -sh` 與 PE 子目錄大小  
- [ ] **Step 3:** 環境變數 `CYDER_SKIP_ENGINE_PRUNE=1` 跳過（開發對照用）  

---

### Task 6: 回歸驗證

- [ ] **Step 1:** `bash scripts/create-cyder-app.sh`  
- [ ] **Step 2:** `bash tests/test-cyder-bootstrap.sh`  
- [ ] **Step 3:** `bash scripts/verify-bluecg.sh`（G3 BlueLauncher）  
- [ ] **Step 4:** 記錄 prune 前後 `du` 至 plan 或 CI log  

---

### Task 7: 文件

**Files:**
- Modify: `docs/scripts.md`
- Modify: `docs/cyder.md`（可選一句）

- [ ] **Step 1:** 新增 strip / prune / analyze 腳本說明  
- [ ] **Step 2:** 連結 spec §5–§6  

---

## Phase 2 概要（未排 task）

1. 比對 CrossOver `sources/wine/tools/gitlab/build-mac` 與 Sikarugir `wswine.bundle` PE 差異  
2. 調查 configure 旗標或 install 後處理，使同名 DLL 體積接近 Sikarugir  
3. 目標：PE **~295 MB**；產出 versioned `engine-*.tar.xz`  
4. 驗收：spec §8 G0–G4 + 與 golden allowlist diff  

## Phase 3 概要（未排 task）

1. `Cyder.app` 移除 `engine-payload`；首次啟動下載 engine  
2. `cyder-common.sh` `ensure_shared_engine` 改為 fetch + verify + extract  
3. 目標：app **~5 MB**；首次下載 **~150–200 MB** 壓縮包  
4. 需 UI：下載進度、離線提示、checksum  

---

## Execution handoff

Phase 1 完成後：

1. 更新 spec §10 待決（msxml profile 等）  
2. 視 G3/G4 結果決定是否進入 Phase 2  
3. Phase 3 可與 Phase 2 並行設計，但實作建議在 Phase 2 engine 體積穩定後  

**Two execution options:**

1. **Subagent-Driven Development** — 本 session 逐 Task 派發子 agent  
2. **Inline Execution** — 同一 session 按 Task 1→7 執行，Task 6 作 checkpoint  
