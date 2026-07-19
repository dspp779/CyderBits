# 腳本參考

所有腳本假設在 repo 根目錄執行。多數會 `source scripts/env-x86_64.sh` 設定路徑與 x86_64 工具鏈。

## 環境與建置

| 腳本 | 用途 |
|------|------|
| `env-x86_64.sh` | `OGOM`、`CX_VERSION`、`.brew-x86`、`WINE_SRC`、`WINE_INSTALL`、`ENTITLEMENTS_PLIST` 等；**忽略 shell 的 `HOMEBREW_PREFIX=/opt/homebrew`** |
| `prepare-build-deps.sh` | 從 `tools/archives/` 解壓 llvm-mingw 與 CrossOver 原始碼至 `build/` |
| `build-wine.sh` | `--cx 25\|26`：prepare + configure + make + install 至 `install/wine-cx25-x86_64` 或 `wine-cx26-x86_64`；`--with-vulkan` / `--without-vulkan`；見 [wine-configure-options.md](wine-configure-options.md) |
| `build-graphics-stack.sh` | 從 CrossOver FOSS 建 MoltenVK（`--vulkan-source crossover` 時）；`--with-vkd3d` 預留 phase 2 |
| `sign-wine.sh` | ad-hoc codesign + entitlements（`config/entitlements.plist`） |
| `bundle-wine-dylibs.sh` | 將 Homebrew dylib 複製進 Wine 樹並改 `@loader_path` |
| `strip-wine-install.sh` | 剝除 engine 非 runtime（`include/`、dev `bin`、`*.a`、man）；打包前 staging |
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
| `install-libarchive-tar.sh` | 安裝 GnuWin bsdtar 為 prefix `syswow64/tar.exe` |
| `resolve-wine-locale.sh` | 解析 Wine 用 locale（輸出至 stdout） |

## Cyder 啟動器

| 腳本 | 用途 |
|------|------|
| `pack-engine-artifact.sh` | strip + bundle + sign + 預設 xz 最高壓縮比 → `engine-wine-x86_64-CX26-<winever>.tar.xz`；`--zstd` / `CYDER_ENGINE_FORMAT=zstd` 產出 `engine-CX26-<winever>.tar.zst` |
| `cyder-copy-engine-artifact.sh` | 複製預建 artifact 進 app `Resources/` |
| `create-cyder-app.sh` | `dist/Cyder.app`（`.exe` 啟動器 + engine artifact + bootstrap） |
| `cyder_launcher.sh` | 解析 `.exe`、bootstrap `bottles/shared`、執行 Wine；`--ensure-engine-only` / `--bootstrap-only` / `--launch-exe` 供 GUI 分階段呼叫 |
| `cyder-winetricks.sh` | 以 Cyder engine 的 unattended CLI 安裝固定版 Winetricks 元件；目標為 SharedPrefix，供 Cyder 原生元件選擇器呼叫 |
| `cyder_app_main.swift` | 編譯為 `Cyder.app/Contents/MacOS/Cyder`（Universal）；無 `.exe` 時顯示設定頁，有 `.exe` 時直接啟動 Wine，收到 same-prefix 的 `ActivatingAppPID` Foreground 通知後 activate 並退出 |
| `create-cyder-pid-test-app.sh` | 建立 `dist/CyderPIDTest.app` Universal 測試工具 |
| `cyder_pid_test_launcher.swift` | 可選 EXE、比較 wrapper PID 與 Wine `ActivatingAppPID`，測試普通及 cooperative activation |
| `cyder-common.sh` | 共用路徑、`ensure_shared_engine`、`bootstrap_shared_prefix`、`run_wine_exe` |
| `cyder-exe-association.swift` | 開發用：查詢 Launch Services `.exe` handler、手動 set/cleanup（**不**打包進 app、執行時不呼叫） |
| `cyder_launcher.py` | 開發用 CLI，轉呼叫 `cyder_launcher.sh` |
| `cyder_common.py` | CyderBits 打包器共用（Python） |

## CyderBits 打包

| 腳本 | 用途 |
|------|------|
| `create-cyderbits-app.sh` | `dist/CyderBits.app`（引擎 payload + 打包 GUI） |
| `create-bluecg-app.sh` | `dist/BlueCG.app`（Wine + prefix） |
| `cyder_create_game_app.py` | 建立單一遊戲 `.app`（GUI / CLI） |

## 依賴關係（簡圖）

```text
build-wine.sh
    → sign-wine.sh
    → bundle-wine-dylibs.sh（打包 / Cyder / CyderBits 前）

create-cyder-app.sh
    → bundle-wine-dylibs.sh, sign-wine.sh, strip-wine-install.sh
    → cyder_launcher.sh（執行時）
    → install-wine-mono.sh, install-libarchive-tar.sh, enable-mac-retina-hires.sh（bootstrap）

create-cyderbits-app.sh
    → bundle-wine-dylibs.sh, sign-wine.sh, strip-wine-install.sh
    → cyder_create_game_app.py（執行時）

cyder_launcher.sh
    → cyder-common.sh（ensure_shared_engine, bootstrap_shared_prefix, run_wine_exe）

cyder_create_game_app.py
    → cyder_common（ensure_shared_engine, init_bottle, apply_mac_hires）
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
| `tests/test-cyder-launcher.sh` | `cyder_launcher.sh --dry-run` |
| `tests/test-cyder-game-launch-settings.sh` | stable EXE ID → per-game settings → fast registry/apply launch bridge |
| `tests/test-cyderbits-app.sh` | CyderBits.app 是否內含 `cyder_common.py`、模組可載入 |
| `tests/test-cyder-exe-association.sh` | `cyder-exe-association.swift status` |
| `tests/test-install-libarchive-tar.sh` | `install-libarchive-tar.sh` |
| `tests/test-cyder-bootstrap.sh` | `cyder_launcher.sh --bootstrap-only`（需 Wine） |
| `tests/test-strip-wine-install.sh` | `strip-wine-install.sh`（零風險剝離） |

## strip-wine-install.sh

```bash
bash scripts/strip-wine-install.sh install/wine-cx26-x86_64   # 就地（開發用）
bash scripts/strip-wine-install.sh --dry-run "$ROOT"     # 預覽
CYDER_SKIP_ENGINE_STRIP=1 bash scripts/create-cyder-app.sh  # 打包時跳過 strip
```

## cyder_launcher.sh 旗標

```
exe [exe ...]          .exe 路徑（可省略 → 檔案選擇器）
--engine-src DIR       Wine 安裝來源（預設 install/wine-cx26-x86_64）
--dry-run              印出路徑，不裝引擎、不啟動
--bootstrap-only       只 bootstrap bottles/shared（mono、tar、hi-res）
```

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
--engine-src DIR       Wine 安裝來源（預設 install/wine-cx26-x86_64）
```

## 環境變數（Cyder / Wine）

| 變數 | 說明 |
|------|------|
| `WINEPREFIX` | Wine bottle 路徑（目前固定為 `~/Library/Application Support/Cyder/bottles/shared`） |
| `WINEMSYNC` | `1` 啟用 macOS MSync；Cyder 依進階設定（目前預設關閉），CyderBits 預設開啟但可用 `--no-msync` 關閉 |
| `WINEESYNC` | `1` 啟用 ESync；與 MSync 互斥，依啟動器／遊戲設定決定 |
| `WINEDLLOVERRIDES` | 正式 Cyder 啟動不設定；只保留給單次測試或其他工具使用 |
| `CYDER_ENGINE_SRC` | app 內引擎 payload 路徑 |
| `CYDER_SCRIPTS` | app 內 helper 腳本路徑 |
| `CYDER_LIBARCHIVE_SRC` | app 內 libarchive payload（Cyder.app） |
| `CYDER_WINE_LOCALE_FALLBACK` | locale fallback（預設 `zh_TW.UTF-8`） |
