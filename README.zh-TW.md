<p align="center">
  <img src="logo/cyderbits-transparent.png" alt="CyderBits" width="160">
</p>

# CyderBits

**在 Mac 上跑經典 Windows 遊戲 — 先支援 DirectDraw 與 GDI。**

鎖定 2D 與傳統 Win32 圖形（DirectDraw、GDI）；**尚未**支援 DXVK、Vulkan 與現代 3D 管線。

CyderBits 在 Apple Silicon 上自建 CrossOver 系 Wine，並提供 **Cyder** — 把 `.exe` 包成可雙擊的 macOS `.app`。

**語言：** [English](README.md) · [繁體中文](README.zh-TW.md)

## Cyder（使用者工具）

| | |
|---|---|
| **用途** | 選 Windows `.exe` → 產生 macOS 遊戲 `.app` |
| **引擎** | 共用 Wine（`~/Library/Application Support/Cyder/Engines/`） |
| **文件** | [docs/cyder.md](docs/cyder.md) |

```bash
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

## 驗證用遊戲

開發與 smoke test 以 **[BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18)**（魔力寶貝，DirectDraw PE32）為基準。請自行將遊戲放到本機 `BlueCrossgateNew/`（不納入 git）。

```bash
bash scripts/run-bluecg.sh
```

## Wine 原始碼

Wine 來自 **CrossOver 開源釋出** — 解壓至 `sources/`（見 [CodeWeavers CrossOver Source](https://www.codeweavers.com/crossover/source)），建置使用 `sources/wine/`。

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

## 系統需求

- macOS 12+（建議 13+）
- Apple Silicon + Rosetta 2（Wine 為 **x86_64** build）
- 磁碟需數 GB（原始碼、`.brew-x86`、build 產物；多數在 `.gitignore`）

## 快速開始

### 1. 建 Wine（首次，耗時長）

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

### 2. 用 BlueCG 驗證

```bash
bash scripts/run-bluecg.sh
bash scripts/enable-mac-retina-hires.sh   # 可選：Retina + 200% DPI
```

### 3. 用 Cyder 包裝 EXE

```bash
bash scripts/create-cyder-app.sh
open dist/Cyder.app
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
├── sources/wine/               # CrossOver Wine（.gitignore）
├── .brew-x86/                  # .gitignore
├── install/wine-x86_64/        # .gitignore
└── BlueCrossgateNew/           # BlueCG（.gitignore）
```

## 測試

```bash
bash tests/test-env-x86_64.sh
bash tests/test-build-wine.sh
bash tests/test-sign-wine.sh
bash tests/test-run-bluecg.sh
bash tests/test-verify-bluecg.sh
```

## 文件

- [docs/README.md](docs/README.md) — 索引
- [docs/cyder.md](docs/cyder.md) — Cyder 使用
- [docs/bluecg.md](docs/bluecg.md) — BlueCG 流程
- [docs/scripts.md](docs/scripts.md) — 腳本參考
- [docs/superpowers/](docs/superpowers/) — 設計規格

## 授權與原始碼

Wine 來自 [CrossOver 開源釋出](https://www.codeweavers.com/crossover/source)。遊戲與大型二進位不在 git 內（例如 [BlueCG](https://www.bluecg.net/forum.php?mod=viewthread&tid=18) 請自行取得）。
