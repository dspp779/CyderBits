# 腳本參考

所有腳本假設在 repo 根目錄執行。多數會 `source scripts/env-x86_64.sh` 設定路徑與 x86_64 工具鏈。

## 環境與建置

| 腳本 | 用途 |
|------|------|
| `env-x86_64.sh` | `OGOM`、`.brew-x86`、`WINE_INSTALL`、`ENTITLEMENTS_PLIST`、`arch -x86_64` 等 |
| `build-wine.sh` | configure + make + install Wine 至 `install/wine-x86_64` |
| `sign-wine.sh` | ad-hoc codesign + entitlements（`config/entitlements.plist`） |
| `bundle-wine-dylibs.sh` | 將 Homebrew dylib 複製進 Wine 樹並改 `@loader_path` |
| `link-wine-runtime-libs.sh` | 包裝用 wrapper → `bundle-wine-dylibs.sh` |
| `run-build-wine-bg.sh` | 背景建置 helper |
| `wait-and-build-wine.sh` | 等待條件後建置 |

## BlueCG 執行與調校

| 腳本 | 用途 |
|------|------|
| `run-bluecg.sh` | 啟動 BlueCG（DDRAW、Gecko、locale） |
| `verify-bluecg.sh` | G1–G4 smoke 與 playbook |
| `enable-mac-retina-hires.sh` | RetinaMode + LogPixels=192（`--off` 還原） |
| `configure-mshtml.sh` | prefix 層級啟用/停用 mshtml |
| `install-wine-mono.sh` | 安裝 wine-mono（BlueLauncher .NET） |
| `resolve-wine-locale.sh` | 解析 Wine 用 locale（輸出至 stdout） |

## 打包

| 腳本 | 用途 |
|------|------|
| `create-bluecg-app.sh` | `dist/BlueCG.app`（Wine + prefix） |
| `create-cyder-app.sh` | `dist/Cyder.app`（引擎 payload + Cyder 主程式） |
| `cyder_create_game_app.py` | 建立單一遊戲 `.app`（GUI / CLI） |

## 依賴關係（簡圖）

```text
build-wine.sh
    → sign-wine.sh
    → bundle-wine-dylibs.sh（打包 / Cyder 前）

create-cyder-app.sh
    → bundle-wine-dylibs.sh, sign-wine.sh
    → cyder_create_game_app.py（執行時）

cyder_create_game_app.py
    → ensure_shared_engine（rsync + sign）
    → init_bottle / apply_mac_hires
    → exe_to_icns, write_game_launcher

run-bluecg.sh
    → resolve-wine-locale.sh
```

## 測試

| 腳本 | 對應 |
|------|------|
| `tests/test-env-x86_64.sh` | `env-x86_64.sh` |
| `tests/test-build-wine.sh` | `build-wine.sh`（smoke） |
| `tests/test-sign-wine.sh` | `sign-wine.sh` |
| `tests/test-run-bluecg.sh` | `run-bluecg.sh` |
| `tests/test-verify-bluecg.sh` | `verify-bluecg.sh` |

## cyder_create_game_app.py 旗標

```
--gui                  osascript 選檔 + 選項對話框
--exe PATH             Windows 執行檔
--output DIR           輸出目錄（預設 Desktop）
--standalone           複製遊戲目錄進 app
--portable-engine      內嵌 Wine
--prefix-mode bottle|game_dir
--no-gecko-prompt
--no-mac-hires
--no-msync
--engine-src DIR       Wine 安裝來源（預設 install/wine-x86_64）
```

## 環境變數（Cyder / Wine）

| 變數 | 說明 |
|------|------|
| `WINEPREFIX` | Wine bottle 路徑 |
| `WINEMSYNC` | `1` 啟用 macOS msync（Cyder 預設） |
| `WINEDLLOVERRIDES` | 如 `mshtml=` 跳過 Gecko |
| `CYDER_ENGINE_SRC` | Cyder.app 內引擎 payload 路徑 |
| `CYDER_SCRIPTS` | Cyder.app 內 helper 腳本路徑 |
| `CYDER_WINE_LOCALE_FALLBACK` | locale fallback（預設 `zh_TW.UTF-8`） |
