# BlueCG 自建 Wine 設計規格

> **目標**：從 CrossOver 26.2.0 原始碼自建 x86_64 Wine，在 macOS（Apple Silicon + Rosetta 2）上執行 BlueCrossgateNew（BlueCG），達到與商業版 CrossOver 相同的可玩狀態。
>
> **日期**：2026-07-03  
> **狀態**：已核准

---

## 1. 背景與問題定義

### 1.1 遊戲概況

| 項目 | 值 |
|------|-----|
| 遊戲目錄 | `ogom/BlueCrossgateNew/` |
| 啟動鏈 | `BlueLauncher.exe` → `bluecg.exe` |
| 執行檔架構 | PE32 i386（32-bit Windows） |
| 圖形 API | DirectDraw（非 DXVK / Vulkan） |
| 字型 | `mingliu.ttc`（Big5 繁體） |
| 語系 / Codepage | zh-TW / 950 |
| Wine prefix | 內嵌於遊戲目錄（`system.reg` 標記 `#arch=win64`）；此 prefix 來自商業版 CrossOver，換自建 Wine 時若 G3/G4 異常，應懷疑殘留 registry / DLL override，必要時另建乾淨 prefix 比對 |
| 建議 DDRAW | 官方 `BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll`（28KB shim） |

典型啟動參數（由啟動器組合）：

```
bluecg.exe updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:1 GAHD
```

（除錯時可用 `3Ddevice:0` 作軟體渲染 fallback。）

### 1.2 已驗證環境（基準線）

| 環境 | BlueCG | Sikarugir | 備註 |
|------|--------|-----------|------|
| CrossOver WS12WineSikarugir10.0_6（Wine 10） | ✅ 可玩 | ✅ 可跑 | **黃金基準** |
| CrossOver WS12CX24.0.7_7（Wine 9） | ✅ 可玩 | ✅ 可跑 | |
| CrossOver WS12CX23.7.1_74（Wine 8） | ✅ 可玩 | ✅ 可跑 | |
| Homebrew Wine 11 | ❌ WM_SHOWWINDOW 崩潰 | 未測 | 啟動器可開，主程式建視窗後 nested exception |
| 自 build + codesign | ❌ 連 winecfg 被 kill | 未測 | AMFI / 簽章問題 |

### 1.3 問題拆分

兩條獨立問題，必須分階段解決：

1. **簽章基礎建設**（自 build）：Mach-O 未正確簽署或缺少 JIT entitlements → AMFI SIGKILL，連 `winecfg` 都無法執行。
2. **Wine 相容性**（Homebrew 11）：`bluecg.exe` / `bluecg.dll` 需要可執行記憶體頁（`alloc_module disabling no-exec`），在 `WM_SHOWWINDOW` 觸發 signal stack 上的 nested exception。CrossOver 修補過的 Wine 8–10 無此問題。

**結論**：目標產物應為 **CrossOver 原始碼（`sources/wine`）建出的 x86_64 Wine**，而非 Homebrew 上游 Wine 11。

---

## 2. 目標與非目標

### 2.1 目標

- [ ] 自 build 的 Wine 可執行 `winecfg`（簽章驗證閘）
- [ ] 以 `WINEPREFIX=BlueCrossgateNew` 啟動 `BlueLauncher.exe` 並進入遊戲畫面
- [ ] x86_64 Homebrew 工具鏈隔離於專案目錄，不影響 `/opt/homebrew`
- [ ] ad-hoc 簽章（無 Apple Developer 帳號）

### 2.2 非目標（第一版不做）

- arm64 原生 Wine build
- Docker PE 編譯（無 dxvk 需求）
- DDrawCompat / cnc-ddraw 整合
- 完整 CrossOver.app 打包或 bottle 管理 GUI
- Apple notarization

---

## 3. 架構

### 3.1 目錄結構

```
ogom/
├── .brew-x86/                          # x86_64 Homebrew（.gitignore）
├── llvm-mingw-20260616-ucrt-macos-universal/  # PE 交叉編譯（已有）
├── install/
│   └── wine-x86_64/                    # 自建 Wine 安裝 prefix
├── scripts/
│   ├── env-x86_64.sh                   # 統一環境變數
│   ├── build-wine.sh                   # 編譯 CrossOver Wine
│   ├── sign-wine.sh                    # 遞迴 ad-hoc 簽章
│   └── run-bluecg.sh                   # 啟動遊戲
├── BlueCrossgateNew/                   # WINEPREFIX + 遊戲檔案（沿用）
├── sources/wine/                       # CrossOver 26.2.0 Wine 原始碼
└── docs/superpowers/specs/             # 本文件
```

### 3.2 元件職責

| 元件 | 職責 | 執行環境 |
|------|------|---------|
| `.brew-x86` | 提供 bison、flex、freetype 等 build 依賴 | macOS x86_64（Rosetta） |
| `llvm-mingw` | 交叉編譯 Windows PE（i386 / x86_64） | macOS x86_64 |
| `build-wine.sh` | 編譯並安裝 Wine 至 `install/wine-x86_64` | macOS x86_64 |
| `sign-wine.sh` | 遞迴簽署所有 Mach-O + entitlements | macOS 本機 |
| `run-bluecg.sh` | 設定 `WINEPREFIX`、語系、啟動 BlueLauncher | macOS x86_64 |

### 3.3 為何不用 Docker

- BlueCG 使用 DirectDraw，不需 dxvk。
- macOS Mach-O binary 無法在 Linux container 內編譯。
- OrbStack / Apple container 均只跑 Linux image，對本專案無額外收益。

---

## 4. Build 管線

### 4.1 x86_64 Homebrew 隔離

一次性安裝至專案目錄：

```bash
arch -x86_64 /bin/bash -c \
  'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
   --prefix=/Users/jjc/ogom/.brew-x86'
```

安裝依賴：

```bash
arch -x86_64 /Users/jjc/ogom/.brew-x86/bin/brew install \
  autoconf bison flex pkg-config freetype gettext gnutls
```

`env-x86_64.sh` 設定：

```bash
export OGOM="/Users/jjc/ogom"
export HOMEBREW_PREFIX="$OGOM/.brew-x86"
export LLVM_MINGW="$OGOM/llvm-mingw-20260616-ucrt-macos-universal"
export WINE_INSTALL="$OGOM/install/wine-x86_64"
export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
export ARCH_CMD="arch -x86_64"
```

### 4.2 Wine 編譯

參考 `sources/wine/tools/gitlab/build-mac`：

```bash
source scripts/env-x86_64.sh
cd sources/wine

./tools/make_requests
./tools/make_specfiles
./tools/make_makefiles
autoreconf -f

mkdir -p build64 && cd build64
$ARCH_CMD ../configure -C \
  --enable-win64 \
  --with-mingw=llvm-mingw \
  --prefix="$WINE_INSTALL"

$ARCH_CMD make -j$(sysctl -n hw.ncpu)
$ARCH_CMD make install
```

重點：
- `--enable-win64`：64-bit prefix 支援 32-bit PE（wow64）。
- `--with-mingw=llvm-mingw`：使用專案內 llvm-mingw，不依賴系統 mingw-w64。
- 全程在 `arch -x86_64` 下執行，產出 x86_64 macOS binary（Rosetta 執行）。

### 4.3 驗證閘（Build）

| 閘 | 指令 | 通過條件 |
|----|------|---------|
| G1 | `wine --version` | 有版本輸出，不被 kill |
| G2 | `wine winecfg` | GUI 正常開啟 |
| G3 | `wine BlueLauncher.exe` | 啟動器介面出現 |
| G4 | 從啟動器進遊戲 | 遊戲主視窗可互動 |

G1–G2 驗證簽章；G3–G4 驗證遊戲相容。

---

## 5. 簽章管線

### 5.1 Entitlements

使用 `sources/wine/entitlements.plist`（CrossOver 附帶）：

- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-executable-page-protection`
- `com.apple.security.cs.disable-library-validation`

`bluecg.exe` 需要可執行記憶體頁；缺少上述 entitlements 會導致 AMFI kill 或執行期異常。

### 5.2 簽署流程

```bash
ENTITLEMENTS="sources/wine/entitlements.plist"
PREFIX="$WINE_INSTALL"

# 清除 quarantine
xattr -cr "$PREFIX"

# 遞迴簽署所有 Mach-O
find "$PREFIX" -type f -print0 | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$f"
done

# 驗證
codesign --verify --deep --strict --verbose=2 "$PREFIX/bin/wine"
```

### 5.3 必簽對象（常見遺漏）

- `bin/wine`（安裝後為 wineloader）
- `bin/wineserver`
- `lib/wine/i386-unix/*.so`
- `lib/wine/x86_64-unix/*.so`
- `lib/wine/**/winemac.drv.dylib`
- `lib/wine/**/wine-preloader`（若存在）

### 5.4 失敗診斷

```bash
log show --predicate 'eventMessage CONTAINS "AMFI"' --last 2m
```

若 Gatekeeper 阻擋 x86 程式，由使用者手動允許（已確認可協助）。

---

## 6. 遊戲整合

### 6.1 啟動腳本

```bash
source scripts/env-x86_64.sh
export WINEPREFIX="$OGOM/BlueCrossgateNew"
export LANG=zh_TW.UTF-8
export PATH="$WINE_INSTALL/bin:$PATH"

cd "$WINEPREFIX"
$ARCH_CMD wine BlueLauncher.exe
```

### 6.2 DDRAW 策略

| 來源 | 大小 | 策略 |
|------|------|------|
| 官方 `BlueLauncher_temp/.../DDRAW.dll` | 28KB | **優先使用**（CrossOver 上已驗證） |
| 遊戲目錄 `ddraw.dll`（DDrawCompat） | 3.6MB | 第一版不使用（Wine 11 上 SEH 不相容） |
| Wine built-in ddraw | — | fallback |

`BlueLauncher.ini` 中 `no_local_ddraw=0` 表示使用遊戲目錄內的 ddraw；若需強制官方版本，可將官方 DLL 複製至遊戲根目錄或調整 ini。

### 6.3 語系與字型

- Registry 維持 codepage 950（prefix 已配置）。
- `mingliu.ttc` 已存在於遊戲目錄。
- 啟動器 `game_lang=HK`、`custom_font_face=mingliu` 已配置。

---

## 7. 風險與緩解

| 風險 | 可能性 | 緩解 |
|------|--------|------|
| 自 build 簽章後仍被 kill | 中 | 遞迴簽所有 Mach-O；查 AMFI log；使用者協助 Gatekeeper |
| CrossOver source build 後 BlueCG 仍崩潰 | 低 | 與商業版比對 `wine --version`、WINEDEBUG；必要時對照 engine binary |
| Homebrew 11 相容性問題誤導 | 已排除 | 不以 Homebrew Wine 為目標 |
| `.brew-x86` 磁碟空間 | 低 | gitignore；約 5–15 GB |
| 32-bit PE 在 arm64 Wine 上 | 不適用 | 第一版只做 x86_64 host |

---

## 8. 測試計劃

### 8.1 簽章煙霧測試

```bash
wine --version
wine winecfg
wine notepad   # 可選
```

### 8.2 BlueCG 功能測試

1. 啟動 `BlueLauncher.exe`，確認介面與公告載入。
2. 選擇 HD1 模式啟動，確認 `bluecg.exe` 視窗顯示。
3. 進入遊戲畫面，確認字型（mingliu）與 DirectDraw 渲染正常。
4. 簡單操作（移動、開啟選單）確認穩定。

### 8.3 失敗時的除錯資訊收集

```bash
WINEDEBUG=+module,+virtual,+seh wine bluecg.exe [args] 2>&1 | tee bluecg-debug.log
```

---

## 9. 實作順序

1. **建立 `env-x86_64.sh`** — 環境變數與路徑
2. **安裝 `.brew-x86`** — 隔離的 x86_64 Homebrew
3. **建立 `build-wine.sh`** — 編譯 CrossOver Wine
4. **建立 `sign-wine.sh`** — 遞迴 ad-hoc 簽章
5. **通過 G1–G2** — winecfg 驗證
6. **建立 `run-bluecg.sh`** — 遊戲啟動
7. **通過 G3–G4** — BlueCG 可玩驗證
8. **（可選）** 撰寫 README 說明使用方式

---

## 10. 決策紀錄

| 決策 | 理由 | 日期 |
|------|------|------|
| 以 CrossOver 原始碼為 build 來源 | 商業版 Wine 8–10 已驗證 BlueCG 可玩 | 2026-07-03 |
| x86_64 + Rosetta 為主線 | 遊戲為 i386 PE；CrossOver 使用 x86 engine | 2026-07-03 |
| 專案內 `.brew-x86` | 不影響 `/opt/homebrew` 原生 Homebrew | 2026-07-03 |
| 不使用 Docker | 無 dxvk 需求；macOS binary 必須本機編譯 | 2026-07-03 |
| ad-hoc 簽章 | 無 Developer 帳號；本機自用 | 2026-07-03 |
| 不使用 DDrawCompat | Wine 11 上 SEH 不相容；官方 28KB DDRAW 在 CrossOver 可用 | 2026-07-03 |
| 延後 arm64 build | BlueCG 優先；arm64 wow64 路徑較複雜 | 2026-07-03 |
