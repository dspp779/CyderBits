# 初次開啟 → 偏好設定：dry-run timeline

日期：2026-08-20  
狀態：**部分 superseded**（2026-08-21）— App 已不再 fire-and-forget MSI prefetch；量測腳本改為串行 ensure-engine → ensure-graphics → bootstrap-only。Mono/Gecko 不在 bootstrap 內。  
範圍：量測「第一次開 Cyder 到可開偏好設定」的 wall-clock，產出 timeline。

相關：
- `scripts/cyder-measure-startup.sh`（現有串行量測，不模擬 prefetch∥bootstrap）
- `scripts/cyder_app_main.swift`（`prepareEnvironmentAndShowSettings` / `ensureEnvironment` / `prefetchBootstrapMSI`）
- `docs/superpowers/specs/2026-08-20-bootstrap-p3-p5-progress-skip-graphics-design.md`

## 目標

1. **Phase A**：以隔離 `CYDER_SUPPORT` 腳本模擬 App 的 `ensureEnvironment` 順序與並行，記錄各 span 絕對／相對時間，產出 timeline。
2. **Phase B（可選）**：在 App 內補 timing 點，冷開 `dist/Cyder.app` 對齊 Phase A 的 wall-clock（含 UI 啟動開銷）。
3. Timeline 必須能表達 **overlap**（至少 prefetch MSI ∥ bootstrap）。

## 非目標

- 不修改產品啟動／偏好設定行為。
- 不動 live `~/Library/Application Support/Cyder`。
- 不重打包 engine（除非 `dist/Cyder.app` 缺量測所需資源）。
- Phase A 不宣稱量到 NSWindow 渲染或 App 進程啟動時間。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 方案 | 混合：先 Phase A 腳本，再可選 Phase B App 儀器 |
| 模擬對象 | `ensureEnvironment` + 「可呼叫 `showSettings`」代理點 |
| Prefetch | 背景啟動後立刻跑 `--bootstrap-only`（對齊 Swift fire-and-forget） |
| 時間基準 | 單一 `T0`（monotonic）；每 span 記 `start_ms` / `end_ms` |
| 子階段 | 併入 `bootstrap-timing.jsonl`（相對 bootstrap span 或絕對皆可，輸出時對齊同一時間軸） |
| 輸出 | `spans.jsonl`、`results.json`、`timeline.md`（Mermaid gantt）；可選 Cursor canvas |
| Support | 每次 dry-run 使用 `OUT/first-support`（乾淨目錄） |

## Phase A 架構

對齊 App 冷開偏好設定路徑（`needsEngine` / `needsBootstrap` 為真時）：

```
T0  dry-run start（代理：已決定開偏好設定）
 │
 ├─ ensure-engine-only          [串行]
 ├─ ensure-graphics-only        [串行；版本一致則 skip / 0ms]
 ├─ prefetch-msi (background) ─┐ [並行起點]
 └─ bootstrap-only ────────────┤
      ├─ download / wineboot /  │
      │   mono / gecko / …      │  (bootstrap-timing.jsonl)
      └─ …                     ─┘
 ├─ health-check（僅當 bootstrap 未回 healthChecked=1）
 └─ T_settings  （代理：可 showSettings）
```

### Span 契約（`spans.jsonl` 每行）

```json
{
  "name": "bootstrap-only",
  "start_ms": 1234.5,
  "end_ms": 23456.7,
  "status": 0,
  "parent": null
}
```

子階段可設 `"parent": "bootstrap-only"`。`prefetch-msi` 的 `end_ms` 為背景程序結束時間（可晚於 bootstrap 開始）。

### 腳本落點

- 新增：`scripts/cyder-measure-first-open-preferences.sh`（或擴充既有 measure 腳本加 `--first-open-prefs` 模式）。
- 偏好**獨立腳本**：避免打亂現有 subsequent-open 串行統計。
- 依賴既有：`dist/Cyder.app`、`cyder_launcher.sh`、`cyder-prefetch-bootstrap-msi.sh`。

### Timeline 輸出

`timeline.md` 使用 Mermaid gantt，section 建議：

1. App 代理路徑（engine / graphics / prefetch / bootstrap / health / settings-ready）
2. Bootstrap 子階段（對齊同一 `T0`）

可選：更新或新建 canvas，把同一份 `spans` 視覺化。

## Phase B（可選，本輪可不實作）

在 Swift 記錄：

| 點 | 時機 |
|----|------|
| `prefs.intent` | `finalizePostLaunchModeDecision` → 開 prefs |
| `prefs.ensure.start` / `.end` | `ensureEnvironment` |
| `prefs.prefetch.start` | `prefetchBootstrapMSI` 成功 `run` |
| `prefs.settings.shown` | `showSettings()` 首次呼叫 |

寫入既有 diagnostics / 專用 jsonl；一次冷開後對齊 Phase A。

## 驗收

1. 隔離 support 下跑完 Phase A；不碰 live bottle。
2. `spans.jsonl` 含至少：`ensure-engine-only`、`ensure-graphics-only`（或 skip）、`prefetch-msi`、`bootstrap-only`、`settings-ready`；若有 health 則含 `health-check`。
3. Prefetch 的時間區間與 bootstrap **可重疊**（`prefetch.start < bootstrap.end` 且 `bootstrap.start < prefetch.end`，在 prefetch 仍在跑時）。
4. `timeline.md` Mermaid gantt 可渲染；`results.json` 含 wall-clock 到 `settings-ready`。
5. Phase B 若未做，文件明確標「未驗證 App UI 開銷」。

## 風險與假設

- 假設本機已有可用 `dist/Cyder.app`（含 engine artifact）。
- 首次 dry-run 可能下載 Mono/Gecko MSI（網路）；prefetch 與 bootstrap 內 download 可能競用快取，屬真實行為。
- `ensure-engine-only` 若 runtime 已有相容引擎，時間會偏短；仍應記錄實際路徑。
- Phase A 的 `T_settings` 是「環境就緒、可呼叫 showSettings」代理，**不是**視窗 didAppear。

## Spec self-review（2026-08-20）

- [x] 無 TBD／placeholder
- [x] Phase A／B 邊界清楚；overlap 驗收可檢查
- [x] 與現有 measure 腳本關係：獨立腳本，不破壞 subsequent-open 統計
- [x] 範圍不含產品行為變更
