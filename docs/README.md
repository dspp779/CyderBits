# 文件索引

> 專案根目錄：[README.md](../README.md)（English · **CyderBits**）· [README.zh-TW.md](../README.zh-TW.md)（繁中）

**CyderBits** — DirectDraw / GDI 舊遊戲 on Mac；**Cyder** — 一鍵啟動 `.exe`；**CyderBits.app** — 包裝 `.exe` 為 game `.app`。

## 發布資訊

| 版本 | 文件 | 重點 |
|------|------|------|
| 0.3.0 | [release note](releases/v0.3.0.md) | 錯誤診斷、session log、啟動可靠性與 Universal App |

## 使用指南

| 文件 | 對象 | 內容 |
|------|------|------|
| [cyder.md](cyder.md) | 一般使用者 | Cyder 啟動器：開 `.exe`、SharedPrefix、bootstrap |
| [cyderbits.md](cyderbits.md) | 一般使用者 | CyderBits 打包器：建立 game `.app`、選項與疑難排解 |
| [bluecg.md](bluecg.md) | 開發 / 驗證 | BlueCG 自建 Wine、執行、高解析度與已知問題 |
| [wine-configure-options.md](wine-configure-options.md) | 開發 / 建置 | Wine `configure` 旗標說明與老遊戲取捨 |
| [bluecg-winemac-resize-black-screen.md](bluecg-winemac-resize-black-screen.md) | 開發 / 追蹤 | BlueCG 視窗縮放黑屏的背景、issue 與原始調查 |
| [bluecg-winemac-a6-engine.md](bluecg-winemac-a6-engine.md) | 開發 / 發布 | A6 最終 patch、Cyder003 engine artifact 與驗收資訊 |
| [scripts.md](scripts.md) | 開發者 | `scripts/` 腳本一覽與依賴關係 |

## 設計與計畫（superpowers）

歷史決策與細部規格，實作時以程式碼為準；若與腳本行為不一致，請更新對應文件。

| 文件 | 主題 |
|------|------|
| [superpowers/specs/2026-07-03-bluecg-wine-build-design.md](superpowers/specs/2026-07-03-bluecg-wine-build-design.md) | BlueCG 自建 Wine 總設計 |
| [superpowers/plans/2026-07-03-bluecg-wine-build.md](superpowers/plans/2026-07-03-bluecg-wine-build.md) | 實作計畫與任務 |
| [superpowers/specs/2026-07-04-bluecg-wine-build-plan-revision-design.md](superpowers/specs/2026-07-04-bluecg-wine-build-plan-revision-design.md) | 計畫修訂 |
| [superpowers/specs/2026-07-04-mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md) | Mac Retina 高解析度 registry |
| [superpowers/specs/2026-07-04-portable-app-packaging-design.md](superpowers/specs/2026-07-04-portable-app-packaging-design.md) | 可攜 Wine / app 打包 |
| [superpowers/specs/2026-07-04-cyder-mvp-design.md](superpowers/specs/2026-07-04-cyder-mvp-design.md) | Cyder MVP 決策摘要 |
| [superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md](superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md) | Cyder / CyderBits 產品分流 |
| [superpowers/plans/2026-07-05-cyder-launcher-phase1.md](superpowers/plans/2026-07-05-cyder-launcher-phase1.md) | Cyder 執行器 Phase 1（已完成） |
| [superpowers/specs/2026-07-06-wine-engine-slim-design.md](superpowers/specs/2026-07-06-wine-engine-slim-design.md) | **Wine Engine 瘦身** — Windows on Wine PE 設計 |
| [superpowers/plans/2026-07-06-wine-engine-slim-phase1.md](superpowers/plans/2026-07-06-wine-engine-slim-phase1.md) | Engine 瘦身 Phase 1 實作計畫 |
| [superpowers/specs/2026-07-06-cyderbits-bash-design.md](superpowers/specs/2026-07-06-cyderbits-bash-design.md) | **CyderBits Bash 化** — 打包器 / game app 去 Python |
| [superpowers/plans/2026-07-06-cyderbits-bash-phase1.md](superpowers/plans/2026-07-06-cyderbits-bash-phase1.md) | CyderBits Bash 化 Phase 1 實作計畫 |

## 未來開發路線

以下為已文件化、尚未全部實作的優先方向；細節以各 spec / plan 為準。

| 路線 | Phase | 目標 | 狀態 | 文件 |
|------|-------|------|------|------|
| **Wine Engine 瘦身** | 1 | 剝 `include/`、Plan B-1 allowlist、保守 Plan C；app ~820 MB | 待實作 | [design](superpowers/specs/2026-07-06-wine-engine-slim-design.md) · [plan](superpowers/plans/2026-07-06-wine-engine-slim-phase1.md) |
| **Wine Engine 瘦身** | 2 | 精簡 CrossOver 級 build，PE ~295 MB | 待調查 | 同上 spec §6 |
| **Wine Engine 瘦身** | 3 | App 不內嵌 engine，首次下載 tar.xz（~4 MB app） | 可選 | 同上 spec §6 |
| **CyderBits Bash 化** | 1 | 打包器 + game launcher 改 shell；icon 保留 `extract-exe-icon.py` | 待實作 | [design](superpowers/specs/2026-07-06-cyderbits-bash-design.md) · [plan](superpowers/plans/2026-07-06-cyderbits-bash-phase1.md) |
| **CyderBits 重構** | 2 | Bottle 進 game `.app`、APFS CoW template | 待實作 | [split design](superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md) §Phase 2 |
| **Cyder 生態** | 3 | 容器管理 UI、多引擎切換、加入最愛 | 構想 | 同上 §Phase 3 |

**CyderBits 背景：** `Cyder.app` 已純 shell；`CyderBits.app` 仍 `python3 cyder_create_game_app.py`，產出的 game `.app` 亦內嵌 Python 讀 `meta.json`。Bash 化後對齊 Cyder 模式，僅 PE icon 抽取保留小型 `extract-exe-icon.py`（`winemenubuilder -t` / `sips` 直接讀 exe 不可行）。

**Engine 瘦身背景：** 現況 `Cyder.app` ~1.1 GB，幾乎全是 `engine-payload/` 內 Windows PE 假 DLL（~997 MB）與 `include/`（~62 MB）。對照 Sikarugir `wswine.bundle` PE 僅 ~295 MB。Cyder 已用 prefix Mono + `mshtml=`，故可安全 prune 大量 IE/HTML 與非 runtime 檔；**須保留 `mscoree.dll`**（BlueLauncher .NET）。

## 其他

- [../patches/README.md](../patches/README.md) — 選用 Wine 原始碼 patch
