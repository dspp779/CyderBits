<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**在 Mac 上跑經典 Windows 遊戲 — 先支援 DirectDraw 與 GDI。**

鎖定 2D 與傳統 Win32 圖形（DirectDraw、GDI）；**尚未**支援 DXVK、Vulkan 與現代 3D 管線。

CyderBits 在 Apple Silicon 上自建 CrossOver 系 Wine，並提供兩個工具：**Cyder** — 一鍵啟動 `.exe` — 與 **CyderBits** — 把 `.exe` 包成可雙擊的 macOS `.app`。

**語言：** [English](README.md) · [繁體中文](README.zh-TW.md)

## Cyder（啟動器）

| | |
|---|---|
| **用途** | 直接開啟 Windows `.exe`（共用 SharedPrefix） |
| **引擎** | 共用 Wine（`~/Library/Application Support/Cyder/Engines/`） |
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

## Wine 原始碼

Wine 來自 **CrossOver 開源釋出** — 將 archive 放在 `tools/archives/`（見 [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)），建置時解壓至 `build/cx25/` 或 `build/cx26/`。

```bash
bash scripts/build-wine.sh --cx 26          # 預設 CX26
bash scripts/build-wine.sh --cx 25          # A/B 對照 CX25
bash scripts/sign-wine.sh
```

## 系統需求

- macOS 12+（建議 13+）
- Apple Silicon + Rosetta 2（Wine 為 **x86_64** build）
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

- [docs/README.md](docs/README.md) — 索引
- [docs/cyder.md](docs/cyder.md) — Cyder 啟動器
- [docs/cyderbits.md](docs/cyderbits.md) — CyderBits 打包器
- [docs/bluecg.md](docs/bluecg.md) — BlueCG 流程
- [docs/scripts.md](docs/scripts.md) — 腳本參考
- [docs/superpowers/](docs/superpowers/) — 設計規格

## 授權與原始碼

Wine 來自 [CrossOver 開源釋出](https://www.codeweavers.com/crossover/source)。遊戲與大型二進位不在 git 內（例如 [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18) 請自行取得）。
