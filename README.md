# ogom

在 Apple Silicon Mac 上自建 CrossOver 系 Wine，執行 Windows 遊戲；並提供 **Cyder**（Old Game on Mac）把 `.exe` 包成可雙擊的 macOS `.app`。

## 專案組成

| 元件 | 說明 |
|------|------|
| **Wine 自建** | 從 `sources/wine`（CrossOver 26.2 原始碼）建 x86_64 版，經 Rosetta 執行 |
| **BlueCG** | 驗證目標遊戲（魔力寶貝 BlueCrossgateNew）；`scripts/run-bluecg.sh` |
| **Cyder** | 選 `.exe` → 產生遊戲 `.app`；共用 Wine 引擎與 per-game bottle |

## 系統需求

- macOS 12+（建議 13+）
- Apple Silicon + Rosetta 2（Wine 為 **x86_64** build）
- 磁碟：Wine 原始碼、`.brew-x86`、build 產物約需數 GB（多數目錄在 `.gitignore`）

## 快速開始

### 1. 建 Wine（首次，耗時長）

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
```

### 2. 跑 BlueCG（開發驗證）

```bash
bash scripts/run-bluecg.sh
# 高解析度（Retina + 200% DPI）
bash scripts/enable-mac-retina-hires.sh
```

### 3. 使用 Cyder（包裝任意 EXE）

```bash
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

或 CLI：

```bash
python3 scripts/cyder_create_game_app.py --gui
```

詳見 [docs/cyder.md](docs/cyder.md)。

## 目錄結構（精簡）

```text
ogom/
├── config/entitlements.plist   # Wine JIT / dyld 簽章 entitlement
├── logo/cyderbits.png          # Cyder.app 圖示
├── patches/                    # 選用原始碼 patch（見 patches/README.md）
├── scripts/                    # 建置、執行、打包腳本
├── tests/                      # 腳本 smoke tests
├── docs/                       # 說明文件（見 docs/README.md）
├── sources/wine/               # Wine 原始碼（.gitignore，需自行準備）
├── .brew-x86/                  # 專案內 x86_64 Homebrew（.gitignore）
├── install/wine-x86_64/        # Wine 安裝前綴（.gitignore）
└── BlueCrossgateNew/           # 遊戲與 prefix（.gitignore）
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

- [docs/README.md](docs/README.md) — 文件索引
- [docs/cyder.md](docs/cyder.md) — Cyder 使用與選項
- [docs/bluecg.md](docs/bluecg.md) — BlueCG 建置與執行
- [docs/scripts.md](docs/scripts.md) — 腳本參考
- [docs/superpowers/](docs/superpowers/) — 設計規格與實作計畫（歷史決策）

## 授權與原始碼

Wine 原始碼來自 CrossOver / CodeWeavers 發行 tarball；遊戲檔案與大型二進位請自行放置，不納入 git。
