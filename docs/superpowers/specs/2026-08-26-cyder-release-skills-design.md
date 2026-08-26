# Cyder 正式發佈 Skills 設計

日期：2026-08-26  
狀態：approved  
觸發：0.13.1 重 pack 時以 symlink 餵 `pack-graphics-payloads.sh`，把 DXVK／DXMT 打成 372B stub，導致 `Cyder.app.zip` 異常變小。

相關：

- `docs/release-pipeline.zh-TW.md`
- `cyder-wine-engine/docs/incremental-build-and-patches.md`
- `cyder-wine-engine/docs/ai-agent-setup.md`
- 既有 skills：`incremental-wine-build`、`cyder-wine-engine-redirect`

---

## 目標

1. 用**多個專案 skills + 一條編排 skill**覆蓋整條正式通道（選項 3）：引擎 Developer ID pack → App pin → 公證 release → 強制驗收。
2. 把這次失敗模式寫成**可執行驗收**與（建議同期落地的）**腳本硬閘**，避免只靠 markdown 提醒。
3. 不另做跨專案 Cursor plugin；流程綁 ogom ↔ cyder-wine-engine 邊界，skills 放各 repo 的 `.agents/skills/`。

## 非目標

- 不取代日常增量 Wine 建置（仍由 `incremental-wine-build` 負責）。
- 不把簽署憑證／notary 密鑰寫進 skill 或 git。
- 不在本設計內實作完整 CI；腳本 gate 以本機／agent 呼叫為主，CI 可之後接同一 verify script。
- 不強制一次 PR 改完所有腳本；skill 可先落地，硬閘可同 PR 或緊接 follow-up。

---

## §1 四個 skills 邊界

| Skill | Repo | 職責 | 不負責 |
|-------|------|------|--------|
| **`cyder-release`** | ogom | 編排正式通道：版本確認 → 引擎 pack → import pin → `release-cyder.sh --channel release` → 呼叫 verify → 報告產物 | 日常 Wine 增量；略過 verify |
| **`engine-release-pack`** | cyder-wine-engine | 出貨引擎：Developer ID、dual MoltenVK 閘門、**真實** graphics pack（禁 symlink 來源）、minOS／archive 內簽章驗證 | App 公證；MapleStory 實驗／adhoc 本機測試 |
| **`cyder-release-verify`** | ogom | 只讀驗收：graphics 體積與非 symlink 內容、engine label／pin、zip 相對 baseline、spctl／stapler | 建置、改 pin、重跑公證（失敗只報告） |
| **`incremental-wine-build`**（既有） | cyder-wine-engine | 日常 patch／增量 make／本機測試 | 正式 Developer ID 出貨（改指向 `engine-release-pack`） |

既有 **`cyder-wine-engine-redirect`**（ogom）：從 App repo 導向引擎時，註明正式 pack → `engine-release-pack`；整條發佈 → `cyder-release`。

### 編排順序（`cyder-release`）

```text
1. 讀 config/cyder-app-version.txt；確認 --channel release、乾淨 semver
2. 在 cyder-wine-engine 執行 engine-release-pack（產出 zstd + manifest）
3. ogom: import-engine-release.sh --manifest … --apply
4. bash scripts/release-cyder.sh --channel release --version <semver>
5. 執行 cyder-release-verify（對 baseline）
6. 失敗 → 停止；說明應重跑：graphics pack / engine pack / 整條 release
```

重發（例如只修 graphics）時：編排可跳過「未變動的引擎 rebuild」，但仍必須跑 **verify**；若 verify 指 graphics，則必須先 `engine-release-pack` 的 graphics 段或等價的 `pack-graphics-payloads.sh`（真實目錄來源）再 `release-cyder.sh`。

---

## §2 觸發 description 與檔案清單

### Descriptions（載入用，英文為主以利 agent 匹配）

**cyder-release**

> Orchestrate a Cyder formal release: engine Developer ID pack, import pin, `release-cyder.sh --channel release`, then `cyder-release-verify`. Use when cutting a shipping version, notarizing Cyder.app, or re-releasing after a failed zip/graphics check.

**engine-release-pack**

> Pack a shipping Wine engine with Developer ID signing, dual-variant MoltenVK gates, and real DXVK/DXMT graphics payloads (never symlink sources). Use when producing Cyder012+ release tarballs or repairing adhoc/broken graphics packs for release.

**cyder-release-verify**

> Verify a built Cyder.app / Cyder.app.zip before or after notarization: graphics payload size and non-symlink contents, engine label/pin, zip size vs baseline, spctl and stapler. Use after release builds, re-releases, or when the app zip looks unexpectedly small.

### 檔案落地

| 路徑 | 動作 |
|------|------|
| `ogom/.agents/skills/cyder-release/SKILL.md` | 新建編排 |
| `ogom/.agents/skills/cyder-release-verify/SKILL.md` | 新建驗收說明 |
| `ogom/.agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh` | 可執行驗收；skill 只呼叫它 |
| `cyder-wine-engine/.agents/skills/engine-release-pack/SKILL.md` | 新建正式 pack |
| `cyder-wine-engine/scripts/pack-graphics-payloads.sh` | 硬閘：拒絕 symlink 來源 + 最小輸出體積 |
| `ogom/.agents/skills/cyder-wine-engine-redirect/SKILL.md` | 補正式路徑 |
| `cyder-wine-engine/.agents/skills/incremental-wine-build/SKILL.md` | pack 段指向 `engine-release-pack` |
| `ogom/docs/release-pipeline.zh-TW.md` | 連結 skills |
| `cyder-wine-engine/docs/ai-agent-setup.md` | 登記新 skills |
| 可選：兩 repo 各一條薄 `.cursor/rules/*.mdc` | 指向 skills，不複製長 checklist |

**不做：** 獨立 Cursor Marketplace plugin。

---

## §3 `cyder-release-verify` 強制門檻

對 `Cyder.app`（若存在）與／或 `Cyder.app.zip`：

1. **Graphics payloads**  
   - `Contents/Resources/graphics/dxvk-*.tar.zst` 與 `dxmt-*.tar.zst` 各 **> 1 MiB**（建議門檻：dxvk ≥ 2 MiB、dxmt ≥ 8 MiB，對齊現行 ~3.5 / ~12 MiB）。  
   - `zstd -dc … | tar -tv`：**頂層不得為 symlink**（`^l`）；應含真實 DLL／dylib 路徑（例如 `d3d11.dll` / `winemetal.so` 或專案約定標記檔）。

2. **Engine**  
   - `Resources/engine-*.tar.zst` 存在。  
   - `Resources/engine-version.txt`（或 sidecar）與 `config/cyder-engine-version.txt` pin 一致（含點號 label 對齊規則與現有 `cyder_engine_versions_equal` 語意一致即可）。

3. **Zip 相對 baseline**  
   - `--baseline` 預設：`dist/Cyder-*.zip` 中**次新**的正式檔（排除當次輸出 `Cyder.app.zip`）；可顯式傳入（如 `dist/Cyder-0.13.0.zip`）。  
   - 若 baseline 與當次皆含完整 graphics：當次 zip 檔案大小應 **≥ baseline − 1 MiB**（允許小幅壓縮波動）。若當次 engine 明顯變大（例如 +2 MiB）而 zip 變小超過閾值 → **失敗**並提示檢查 graphics。

4. **Gatekeeper**（對已公證 App）  
   - `spctl -a -vv` → Notarized Developer ID。  
   - `xcrun stapler validate` OK。  
   - 若 `--skip-notarization-checks`（僅建置後、公證前）可跳過本項。

Exit ≠ 0 時：`cyder-release` **必須停止**，並列出建議重跑段落。

### CLI 草案

```bash
bash .agents/skills/cyder-release-verify/scripts/verify-cyder-release.sh \
  --app dist/Cyder.app \
  --zip dist/Cyder.app.zip \
  --baseline dist/Cyder-0.13.0.zip
```

---

## §4 `engine-release-pack` 步驟與硬閘

Skill 指示 agent（或薄 wrapper script，可選）依序：

1. `OGOM`／cwd = cyder-wine-engine；`SIGN_IDENTITY` = Developer ID（非 `-`）。  
2. `WINE_INSTALL` 必須是**真實目錄樹**（`install/wine-cx26-x86_64` 或完整解壓的 engine tree），**禁止**用 symlink 充當 `lib/dxvk`／`lib/dxmt`／`lib/dxvk2` 來過 pack gate。  
3. 先 `pack-graphics-payloads.sh --engine "$WINE_INSTALL" --force`（或 pack-engine 內建呼叫），再 `pack-engine-artifact.sh --zst --force`。  
4. Cyder012+：dual MoltenVK 佈局驗證（既有 pack gate）。  
5. 解壓抽樣：`codesign -dv` 至少檢查 `bin/wine`、`libMoltenVK.dylib`、versioned reals → Developer ID。  
6. 產出 manifest + sha256；回報路徑給 `cyder-release` 做 import。

### `pack-graphics-payloads.sh` 硬閘（建議同實作波次）

- 若 `"$ENGINE/lib/dxvk"`（及 dxvk2／dxmt）為 symlink → **exit 1**，訊息明確。  
- 寫出 archive 後：檔案大小低於門檻 → **exit 1**。  
- （可選）pack 進 staging 時用 `cp -R` 前 `realpath`／拒絕 symlink，雙重保險。

---

## §5 與既有文件／工具關係

| 既有 | 關係 |
|------|------|
| `incremental-wine-build` | 日常建置；正式出貨改呼叫／轉述 `engine-release-pack` |
| `cyder-wine-engine-redirect` | 補「正式發佈用 cyder-release」 |
| `docs/release-pipeline.zh-TW.md` | 人類 runbook；頂部加 skills 索引 |
| `scripts/release-cyder.sh` | 可選：結尾呼叫 verify（fail-closed）；非必須第一波 |
| Superpowers brainstorming／writing-plans | 本 spec 通過後用 writing-plans 產實作計畫 |

---

## §6 成功標準

1. Agent 在「跑正式通道／重發」時載入 `cyder-release`，且不略過 verify。  
2. 重現「symlink → 372B graphics」時，`pack-graphics-payloads` 或 verify **至少一處**失敗。  
3. 修好後的 zip：graphics 體積與 0.13.0 同級；engine 變大時 zip 不異常縮小。  
4. `docs/ai-agent-setup.md`／release-pipeline 可發現新 skills。

## §7 實作波次（供後續 plan）

1. **Verify script + `cyder-release-verify` skill**（最快擋住壞 zip）。  
2. **`pack-graphics-payloads` 硬閘**。  
3. **`engine-release-pack` skill**。  
4. **`cyder-release` 編排 skill** + 既有 skill／文件微調。  
5. 可選：`release-cyder.sh` 結尾接 verify；薄 Cursor rules。

---

## 決策摘要

| 項目 | 決定 |
|------|------|
| 範圍 | 整條正式通道 |
| 結構 | 編排 + pack + verify + 既有 incremental |
| Verify | 獨立第四 skill + 可執行 script |
| Plugin | 不做 |
| Baseline zip | 預設次新 `dist/Cyder-*.zip`，可覆寫 |
| 硬閘 | graphics symlink／過小 archive 必須進腳本 |
