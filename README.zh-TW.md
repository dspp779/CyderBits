<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**在 Mac 上跑 Windows 遊戲 — Cyder 0.15.0 以 DirectDraw 與 GDI 為驗證基準，並可依遊戲選擇圖形（DXVK、DXMT、D3DMetal）。**

驗證路徑仍是傳統 2D Win32 圖形：**DirectDraw → Wine wined3d/OpenGL** 與 GDI。Cyder 0.15.0 使用 `CX26.3.0-W11-Cyder014` engine 與 MoltenVK 1.4.2，需要 **macOS 12 以上**；DXVK／DXMT 以獨立 graphics payload 提供，D3DMetal 透過 GPTK 提供。實際遊戲相容性仍需依遊戲、macOS 版本、GPU 與 backend 個別驗證。

本 repo（CyderBits）目前主要是**應用層**：Cyder 啟動器、遊戲庫、設定、CompatDB 與打包器。實際執行 Windows `.exe` 的 Wine 核心在獨立專案 [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)。

本專案提供兩個工具：**Cyder** — 一鍵啟動 `.exe` — 與 **CyderBits** — 把 `.exe` 包成可雙擊的 macOS `.app`。

**語言：** [English](README.md) · [繁體中文](README.zh-TW.md)

## Cyder（啟動器）

| | |
|---|---|
| **用途** | 直接開啟 Windows `.exe`（共用 SharedPrefix） |
| **引擎** | 共用 Wine（`~/.cyder/runtime/Engines/`，刻意避免空白） |
| **文件** | [docs/cyder.md](docs/cyder.md) |

依[快速開始](#快速開始)建置測試版，或從 [GitHub Releases](https://github.com/dspp779/CyderBits/releases) 下載正式版。

## CyderBits（打包器）

| | |
|---|---|
| **用途** | 選 Windows `.exe` → 產生 macOS 遊戲 `.app` |
| **Prefix** | 每遊戲 bottle（`~/Library/Application Support/Cyder/Bottles/`，Phase 1） |
| **文件** | [docs/cyderbits.md](docs/cyderbits.md) |

```bash
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
```

## 驗證用遊戲

開發與 smoke test 以 **[BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)**（魔力寶貝，DirectDraw PE32）為基準。請自行將遊戲放到本機 `BlueCrossgateNew/`（不納入 git）。

```bash
bash scripts/run-bluecg.sh
```

## 🎮 已測試遊戲相容性

目前已測試過並確認可運行的遊戲清單如下，完整測試細節、啟動參數與 Workaround 請參閱 **[📋 遊戲相容性矩陣 (Compatibility Matrix)](docs/games/compatibility-matrix.md)**。

| 類別 | 遊戲名稱 | 測試狀態 | 關鍵設定 / 備註 |
|:---:|:---|:---:|:---|
| **單機** | 世紀帝國 2 (3.8) | ⚠️ 可玩 | 每 5 秒會頓一下 (已知 Wine/macOS 問題) |
| **單機** | 大富翁 4 | 🟡 需 ddraw | 原版黑畫面，需搭配 `cnc-ddraw` 顯示才正常 |
| **單機** | 皮卡丘打排球 | 🟡 特殊條件 | 建議關閉 MSync；CrossOver 需開啟儲存 log 檔 |
| **單機** | 洛克人 X3 / X4 | ⚠️ 提示可玩 | 啟動會跳 DirectX 初始化錯誤，按掉後可正常遊玩 |
| **單機** | 洛克人 X5 | ⚠️ 畫面縮放 | 可正常遊玩，畫面縮在左上角 |
| **單機** | 越南大戰 | 🟢 可玩 | 停用 Retina Mode 即可正常遊玩 |
| **單機** | 暗黑破壞神 2 | 🟢 可玩 | 停用 Retina Mode 即可正常遊玩 |
| **單機** | 魔獸爭霸 3 | 🟢 可玩 | 搭配啟動參數 `-nativefullscr` 開啟最高解析度 |
| **單機** | 小朋友齊打交 2 (1.9c) | 🟢 可玩 | 可直接執行遊玩 |
| **單機** | 小朋友齊打交 2 (2.0a) | 🟡 需依賴庫 | 需透過 `winetricks` 安裝 `vcrun2005`, `wmp9`, `quartz`, `devenum`, `vb6run` |
| **線上** | MECCHA CHAMELEON（Steam） | 🟡 需 DXMT／D3DMetal | 0.15.0 起自動使用 DXMT 與 `-dx11`（DXVK 下主選單背景全黑） |
| **單機** | Cities: Skylines II | 🟡 僅 Apple Silicon | 0.15.0 起自動使用 DXMT；可進主選單、新建城市、存檔與讀檔。建造與長時間遊玩未測；GPU Family Mac 1 的 Intel Mac 無法執行（[指引](docs/games/cities-skylines-2/README.md)） |
| **線上** | 水藍魔力 (BlueCG) | 🟢 可玩 | 專案驗證基準 (DirectDraw / GDI) |
| **線上** | 新楓之谷 | 🟡 部分驗證 | 需 MapleStory Launcher、[CitrusGate](https://github.com/dspp779/CitrusGate) 與有效 OTP；CX26 版本仍需完成地圖級驗收 |
| **線上** | 新楓之谷 經典版 | 🟡 部分驗證 | 需 [CitrusGate](https://github.com/dspp779/CitrusGate) 傳送 OTP；QDO workaround 與背景程序清理仍有已知限制 |
| **線上** | 爆爆王 | 🟡 歷史驗證 | 服務可用性與目前版本相容性尚未在目前版本重新驗證 |

## 圖形 backend 狀態

| Backend | 專案狀態 | 說明 |
|---|---|---|
| DirectDraw / GDI | **支援且已驗證** | BlueCG 使用 DirectDraw；預設路徑是 wined3d/OpenGL，GDI 是相容性 fallback。 |
| wined3d / OpenGL | **目前預設** | BlueCG 驗證用 engine 含已測試的 `winemac.drv` same-view backing 修復，可支援 Retina/DPI resize。 |
| Vulkan / MoltenVK | **由 engine 提供** | MoltenVK 1.4.2，經 wait-poll shim 載入（`.real` → `1.4.2`）。0.15.0 起移除 1.2.10 與版本選項；舊款 Intel 內顯尚未以 1.4.2 實測（[#7](https://github.com/dspp779/CyderBits/issues/7)）。這不是 BlueCG 的主要繪圖路徑。 |
| DXVK | **已整合 runtime payload** | DXVK 由 Cyder.app 的 `Resources/graphics/` 外部 payload 提供，透過 CompatDB builtin + prepend 載入；DXVK 2 仍暫不出貨。 |
| DXMT | **已整合 runtime payload** | 上游 DXMT 0.80（Developer ID 簽署），以外部 payload 提供。需要 macOS 15+ **且** GPU 支援 Metal GPU Family Mac 2（Apple Silicon）。圖形為「預設」時，新楓之谷、經典版、Cities: Skylines II 與 MECCHA CHAMELEON 自動使用；其他 Mac 上新楓之谷改用 DXVK、MECCHA CHAMELEON 改用 D3DMetal 或 DXVK，Cities: Skylines II 在啟動前顯示 `CYD-GFX-002`。 |
| D3DMetal | **已接入產品 backend** | 透過 GPTK／Apple D3DMetal，需 macOS 14+ 與可用 GPTK；實際遊戲相容性需逐款驗證。 |

詳見 [Wine configure 與圖形選項](docs/wine-configure-options.md)、
[DXVK 編譯備忘](docs/build-dxvk.zh-TW.md)。

## Wine 引擎

實際執行 `.exe` 的核心在 [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)。Wine 來自 **CrossOver 開源釋出**（見 [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)）。引擎的建置、patch、簽署與打包都在該 repo 進行；`Cyder.app` 內嵌 `config/cyder-engine-manifest.json` 指定的引擎版本。專案邊界見 [docs/cyder-wine-engine-project.md](docs/cyder-wine-engine-project.md)。

## 系統需求

- **Cyder.app：** **macOS 12+**（`LSMinimumSystemVersion` 12.0）。macOS 10.15 或 11 請使用 [Cyder 0.14.1](docs/releases/v0.14.1.md)，它是最後支援這些系統的版本。
- **圖形：** DXMT 需要 macOS 15+ 與 Metal GPU Family Mac 2；D3DMetal 需要 macOS 14+ 與 GPTK。
- **遊戲位置：** 建議放在 `~/Games`；Documents、Desktop、Downloads、雲端或外接磁碟可能只授權 EXE，卻阻擋同資料夾的 DLL
- **開發／建置：** 建議 macOS 12+（日常開發建議 13+）
- Apple Silicon 需要 Rosetta 2（Wine 為 **x86_64** build）
- 磁碟需數 GB（原始碼、`.brew-x86`、build 產物；多數在 `.gitignore`）

## 快速開始

### 1. 取得 Wine 引擎

`Cyder.app` 需要 `config/cyder-engine-archive.txt` 指定的引擎 archive。請在相鄰的 [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine) checkout 建置並打包（首次建置耗時長，請依該 repo 的從零建置文件），或以 `--engine-archive` 指定現有 archive。

### 2. 建置並開啟 Cyder

```bash
bash scripts/release-cyder.sh --channel test --out-dir "${TMPDIR:-/tmp}/cyder-test-build"
open "${TMPDIR:-/tmp}/cyder-test-build/Cyder.app"
```

這個 ad-hoc 版本可以檢查視窗與設定。要啟動遊戲必須以 Developer ID 簽署，見 [docs/development-testing.md](docs/development-testing.md)。

### 3. 用 BlueCG 驗證

```bash
bash scripts/run-bluecg.sh
bash scripts/enable-mac-retina-hires.sh   # 可選：Retina + 200% DPI
```

逐步檢查項目：[docs/games/bluecg/testing.md](docs/games/bluecg/testing.md)。

### 4. 把 EXE 包成遊戲 App

```bash
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
# 或：python3 scripts/cyder_create_game_app.py --gui
```

## 已實作 workaround

- [中文字型預設](docs/workarounds/font-default.md) — 將常見 Windows 中日韓字型預設對應到宋體-繁。
- [RetinaMode 視窗設定](docs/workarounds/retina-mode.md) — RetinaMode + DPI 腳本與縮放注意事項。
- [BlueCG A6 縮放修正](docs/workarounds/bluecg-a6-resize.md) — 縮放、Alt+Enter、最小化／還原的 same-view backing sync。
- [皮卡丘打排球相容性](docs/games/pikachu-volleyball/README.md) — 使用無空格 runtime 路徑並停用 MSync 與 ESync。

## 目錄結構

```text
├── scripts/                    # Cyder.app 原始碼（Bash + Swift）、建置與發佈腳本
├── tests/                      # 離線測試；以 tests/run.sh 執行
├── compatdb/                   # 各遊戲相容性規則與編譯後的資料庫
├── recipes/                    # CyderBits 打包器的遊戲 App recipe
├── config/                     # App 版本、引擎 pin、entitlements
├── patches/                    # 圖形與參考用 patch
├── vendor/cnc-ddraw/           # 內附的 cnc-ddraw
├── docs/                       # 文件（見 docs/README.md）
├── .agents/skills/             # 給 AI agent 的逐步指引（入口：AGENTS.md）
├── logo/                       # App 圖示與 README logo
├── build/ install/ .brew-x86/ tools/archives/   # 連結到 cyder-wine-engine checkout（.gitignore）
└── BlueCrossgateNew/           # BlueCG 遊戲與 prefix（.gitignore）
```

## 測試

```bash
bash tests/run.sh --changed   # 受目前修改影響的測試（相對於 main）
bash tests/run.sh <關鍵字>    # 檔名包含關鍵字的測試
bash tests/run.sh             # 全部測試：每次 push 前在背景跑一次
```

哪種改動該做哪種檢查、測試版建置、簽署與實機檢查：[docs/development-testing.md](docs/development-testing.md)。

## 文件

- [CHANGELOG.md](CHANGELOG.md) — 各版本變更摘要
- [Cyder 0.15.0 發布說明](docs/releases/v0.15.0.md) — Cyder014 引擎、需要 macOS 12+、Apple Silicon 上的 Cities: Skylines II、新楓之谷 WZ 預讀、DXMT GPU 檢查、啟動偵測修正
- [Cyder 0.14.1 發布說明](docs/releases/v0.14.1.md) — 最後支援 macOS 10.15／11 的版本
- [docs/README.md](docs/README.md) — 所有文件與歷次發布說明的索引
- [docs/cyder.md](docs/cyder.md) — Cyder 啟動器
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits 打包器
- [docs/games/compatibility-matrix.md](docs/games/compatibility-matrix.md) — 已測試遊戲
- [docs/development-testing.md](docs/development-testing.md) — 測試、測試版建置、實機與遊戲檢查
- [docs/launch-detection.md](docs/launch-detection.md) — Cyder 如何判斷程式已啟動（`CYD-WIN-002`，英文）
- [docs/release-pipeline.zh-TW.md](docs/release-pipeline.zh-TW.md) — 簽署、公證與發佈流程
- [docs/cyder-wine-engine-project.md](docs/cyder-wine-engine-project.md) — 應用層 vs [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)
- [docs/bluecg.md](docs/bluecg.md) — BlueCG 流程
- [docs/scripts.md](docs/scripts.md) — 腳本參考
- [docs/build-dxvk.zh-TW.md](docs/build-dxvk.zh-TW.md) — DXVK 編譯注意事項
- [AGENTS.md](AGENTS.md) — AI agent 的規則與 skill

## 授權與原始碼

Wine 來自 [CrossOver 開源釋出](https://www.codeweavers.com/crossover/source)。遊戲與大型二進位不在 git 內（例如 [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18) 請自行取得）。
