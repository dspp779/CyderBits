# BlueCG 建置與執行

本 repo 以 **BlueCrossgateNew（BlueCG）** 作為自建 Wine 的驗證標的。遊戲目錄同時是 Wine prefix（`#arch=win64`）。

## 遊戲概況

| 項目 | 值 |
|------|-----|
| 啟動鏈 | `BlueLauncher.exe` → `bluecg.exe` |
| 架構 | PE32 i386 |
| 圖形 | DirectDraw（非 DXVK） |
| 語系 | 繁體中文 / CP950 |
| Prefix | 遊戲目錄內（`system.reg` 等） |
| 建議 DDRAW | `BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll` |

## 建置 Wine

```bash
# 環境變數（其他腳本會 source）
source scripts/env-x86_64.sh

# 完整建置（首次數小時）
bash scripts/build-wine.sh

# 簽章（必須，否則 AMFI SIGKILL）
bash scripts/sign-wine.sh

# 可攜 dylib（打包 / Cyder 前建議執行）
bash scripts/link-wine-runtime-libs.sh
```

建置要點：

- **Host**：x86_64 macOS（`arch -x86_64`）
- **PE arch**：`i386` + `x86_64`（32-bit EXE 需要 i386）
- **工具鏈**：專案內 `.brew-x86`、llvm-mingw
- **Patch**：若 configure 缺 `SONAME_LIBVULKAN`，見 [patches/README.md](../patches/README.md)

## 執行

```bash
bash scripts/run-bluecg.sh
```

常用選項：

| 選項 | 說明 |
|------|------|
| `--direct` | 略過啟動器，直接 `bluecg.exe` |
| `--soft3d` | `3Ddevice:0` 軟體渲染 |
| `--no-gecko-prompt` | 本次 session 停用 mshtml |
| `--ddraw-source official\|builtin\|local` | DDRAW.dll 來源 |

`.NET` 啟動器需 wine-mono：

```bash
bash scripts/install-wine-mono.sh
```

## Mac 高解析度（Retina）

與 CrossOver 高解析度模式對齊：

```bash
bash scripts/enable-mac-retina-hires.sh
# 還原
bash scripts/enable-mac-retina-hires.sh --off
```

寫入 registry：

- `RetinaMode=y`
- `LogPixels=0xC0`（192 DPI）
- ClearType RGB 字型平滑

詳見 [superpowers/specs/2026-07-04-mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md)。

## 驗證

```bash
bash scripts/verify-bluecg.sh
```

## 打包成 .app

```bash
# 內含 Wine + 複製 prefix
bash scripts/create-bluecg-app.sh

# 開發：prefix 用 symlink
bash scripts/create-bluecg-app.sh --link-prefix
```

產物：`dist/BlueCG.app`。

或用 **Cyder** 建立（建議 `game_dir` + `no-gecko`），見 [cyder.md](cyder.md)。

## 已知雜訊（通常可忽略）

- `libMoltenVK.dylib` 找不到（ddraw 走 wined3d/GL，非 Vulkan）
- `dmsynth` underrun、`GL_INVALID_FRAMEBUFFER_OPERATION`
- 全螢幕 / 縮放黑畫面（CrossOver 亦有；Sikarugir 較佳）

## 相關文件

- [superpowers/specs/2026-07-03-bluecg-wine-build-design.md](superpowers/specs/2026-07-03-bluecg-wine-build-design.md)
- [superpowers/plans/2026-07-03-bluecg-wine-build.md](superpowers/plans/2026-07-03-bluecg-wine-build.md)
