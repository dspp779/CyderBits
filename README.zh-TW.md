<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**在 Mac 上跑經典 Windows 遊戲 — 先支援 DirectDraw 與 GDI。**

驗證路徑是傳統 2D Win32 圖形：**DirectDraw → Wine wined3d/OpenGL** 與 GDI。目前封裝的 `CX26.3.0-W11-Cyder004` engine 也包含 x86_64 **MoltenVK**（重新打包預設 `VULKAN_MODE=with` + `VULKAN_SOURCE=existing`），供 Wine Vulkan 使用；但 BlueCG 不走 Vulkan、DXVK、dxmt 或 D3DMetal。

CyderBits 在 Apple Silicon 上自建 CrossOver 系 Wine，並提供兩個工具：**Cyder** — 一鍵啟動 `.exe` — 與 **CyderBits** — 把 `.exe` 包成可雙擊的 macOS `.app`。

**語言：** [English](README.md) · [繁體中文](README.zh-TW.md)

## Cyder（啟動器）

| | |
|---|---|
| **用途** | 直接開啟 Windows `.exe`（共用 SharedPrefix） |
| **引擎** | 共用 Wine（`~/.cyder/runtime/Engines/`，刻意避免空白） |
| **文件** | [docs/cyder.md](docs/cyder.md) |

```bash
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

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

## 圖形 backend 狀態

| Backend | 專案狀態 | 說明 |
|---|---|---|
| DirectDraw / GDI | **支援且已驗證** | BlueCG 使用 DirectDraw；預設路徑是 wined3d/OpenGL，GDI 是相容性 fallback。 |
| wined3d / OpenGL | **目前預設** | BlueCG 驗證用 engine 含已測試的 `winemac.drv` same-view backing 修復，可支援 Retina/DPI resize。 |
| Vulkan / MoltenVK | **目前封裝 engine 已包含** | x86_64 Wine 內含 `libMoltenVK.dylib`（macOS 10.15 minos）；這不是 BlueCG 的繪圖路徑。`pack-engine-artifact.sh` 預設保留 MoltenVK；從原始碼重建仍可用 `--without-vulkan`。 |
| DXVK | **尚未整合** | 本 repo 沒有打包 DXVK runtime，也沒有遊戲驗證結果。 |
| dxmt | **尚未整合** | 尚無 dxmt 建置、封裝或相容性結果。 |
| D3DMetal | **不是產品 backend** | 只在歷史 source 實驗中被提及，尚未接入或驗證為 Cyder runtime 路徑。 |

詳見 [Wine configure 與圖形選項](docs/wine-configure-options.md)。

## Wine 原始碼

Wine 來自 **CrossOver 開源釋出** — 將 archive 放在 `tools/archives/`（見 [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)），建置時解壓至 `build/cx25/` 或 `build/cx26/`。

```bash
bash scripts/build-wine.sh --cx 26          # 預設 CX26
bash scripts/build-wine.sh --cx 25          # A/B 對照 CX25
bash scripts/sign-wine.sh
```

## 系統需求

- **Cyder.app：** macOS 10.15+（`LSMinimumSystemVersion`）；遊戲庫／設定 UI 需 **12+**（10.15–11.x 走 bash + osascript legacy UI）
- **開發／建置：** 建議 macOS 12+（日常開發建議 13+）
- Apple Silicon + Rosetta 2（Wine 為 **x86_64** build；Apple Silicon 自 macOS 11+ 起需 Rosetta）
- 磁碟需數 GB（原始碼、`.brew-x86`、build 產物；多數在 `.gitignore`）

## 快速開始

### 1. 建 Wine（首次，耗時長）

```bash
bash scripts/build-wine.sh --cx 26 --install-deps   # 首次（含 bootstrap brew）
bash scripts/build-wine.sh --cx 26
bash scripts/sign-wine.sh
```

### 2. 用 BlueCG 驗證

```bash
bash scripts/run-bluecg.sh
bash scripts/enable-mac-retina-hires.sh   # 可選：Retina + 200% DPI
```

## 已實作 workaround

- [繁中字體預設](docs/workarounds/font-default.md) — 預設把常見 Windows CJK 字體替代為 Songti TC。
- [RetinaMode 遊戲視窗設定](docs/workarounds/retina-mode.md) — RetinaMode、DPI 腳本與 resize 注意事項。
- [BlueCG A6 視窗修復](docs/workarounds/bluecg-a6-resize.md) — 已驗證 resize、Alt+Enter、最小化／還原的 same-view backing sync。
- [皮卡丘排球相容性](docs/games/pikachu-volleyball/README.md) — 使用無空白 runtime 路徑，並關閉 MSync 與 ESync。

### 3. 執行或包裝 EXE

```bash
# Cyder 啟動器 — 直接開 .exe
bash scripts/create-cyder-app.sh
open dist/Cyder.app

# CyderBits 打包器 — 包成 game .app
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
# 或：python3 scripts/cyder_create_game_app.py --gui
```

## 目錄結構

```text
├── logo/                       # cyderbits.png（app 圖示）、cyderbits-transparent.png（README）
├── config/entitlements.plist
├── patches/
├── scripts/
├── tests/
├── docs/
├── tools/
│   ├── archives/               # crossover + llvm-mingw 壓縮檔（.gitignore）
│   └── libarchive/             # GnuWin bsdtar payload
├── build/                      # 解壓後原始碼與 llvm-mingw（.gitignore）
├── .brew-x86/                  # .gitignore
├── install/
│   ├── wine-cx25-x86_64/       # CX25 engine（.gitignore）
│   └── wine-cx26-x86_64/       # CX26 engine（.gitignore）
└── BlueCrossgateNew/           # BlueCG（.gitignore）
```

## 測試

```bash
bash tests/test-env-x86_64.sh
bash tests/test-prepare-build-deps.sh
bash tests/test-build-wine.sh
bash tests/test-sign-wine.sh
bash tests/test-run-bluecg.sh
bash tests/test-verify-bluecg.sh
```

## 文件

- [Cyder 0.6.0 發布說明](docs/releases/v0.6.0.md) — CX26.3 engine、macOS 10.15 runtime、Winetricks、動態 argv
- [docs/README.md](docs/README.md) — 索引
- [docs/cyder.md](docs/cyder.md) — Cyder 啟動器
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits 打包器
- [docs/bluecg.md](docs/bluecg.md) — BlueCG 流程
- [docs/scripts.md](docs/scripts.md) — 腳本參考
- [docs/superpowers/](docs/superpowers/) — 設計規格

## 授權與原始碼

Wine 來自 [CrossOver 開源釋出](https://www.codeweavers.com/crossover/source)。遊戲與大型二進位不在 git 內（例如 [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18) 請自行取得）。
