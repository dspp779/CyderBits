# Mac 高解析度模式（對齊 CrossOver）

> **日期**：2026-07-04  
> **狀態**：已驗證（BlueCG 啟動器 + 遊戲）  
> **Prefix**：`BlueCrossgateNew`  
> **Wine**：自建 `install/wine-x86_64`（CrossOver 26.2.0 sources）

## 目標效果

與 CrossOver「高解析度模式」相同：

- 啟動器／遊戲**畫質清楚**（字體無破碎毛邊）
- **視窗在螢幕上的大小**與未開高解析度時接近（不會只剩一半大）
- 遊戲畫面**鋪滿視窗**，不會因 DPI 留下大塊黑邊

## 原理（勿與 winecfg DPI 搞混）

| 機制 | Registry | 行為 |
|------|----------|------|
| **Mac Driver RetinaMode** | `HKCU\Software\Wine\Mac Driver\RetinaMode` | macOS `contentsScale=2`，以實體像素密度繪製；Wine 座標與 macOS 點數有 2:1 換算，**單獨開啟會讓視窗變小** |
| **Windows LogPixels** | `HKCU\Control Panel\Desktop\LogPixels` | Windows 邏輯 DPI。`0x60`=96（100%），`0xC0`=192（200%） |

- **只開 RetinaMode、DPI=96**：清楚，但視窗約一半大。  
- **只調 winecfg DPI、不開 RetinaMode**：啟動器變大變清楚，老遊戲常**視窗變大但畫面不鋪滿（黑邊）**。  
- **RetinaMode=y + LogPixels=192**：Retina 負責清楚；200% DPI 讓會跟著 DPI 的 UI（啟動器）放大一倍，抵銷 Retina 的「除以 2」，整體接近 CrossOver。

對應原始碼：`sources/wine/dlls/winemac.drv/macdrv_main.c`（讀取 `RetinaMode`）、`macdrv_cocoa.h`（`cgrect_mac_from_win` 等在 `retina_on` 時除以 2）。

## 已驗證設定值

```reg
[HKEY_CURRENT_USER\Software\Wine\Mac Driver]
"RetinaMode"="y"

[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:000000c0
```

（`0xC0` = 192 DPI = 200%。）

## 套用方式

### 方式 A：輔助腳本（建議）

```bash
cd /Users/jjc/ogom
bash scripts/enable-mac-retina-hires.sh
```

關閉：

```bash
bash scripts/enable-mac-retina-hires.sh --off
```

### 方式 B：手動 reg

```bash
cd /Users/jjc/ogom
source scripts/env-x86_64.sh
export WINEPREFIX="$BLUECG_PREFIX"

arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k

arch -x86_64 "$WINE_INSTALL/bin/wine" reg add \
  "HKCU\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d y /f

arch -x86_64 "$WINE_INSTALL/bin/wine" reg add \
  "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 0xc0 /f

arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k
```

還原為「非高解析度」（視窗較大但較糊）：

```bash
# Retina off, DPI 96
arch -x86_64 "$WINE_INSTALL/bin/wine" reg add \
  "HKCU\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d n /f
arch -x86_64 "$WINE_INSTALL/bin/wine" reg add \
  "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 0x60 /f
```

套用後需**重開**啟動器／遊戲（先 `wineserver -k`）。

## 啟動遊戲

```bash
bash scripts/run-bluecg.sh
```

## 相關但不屬於本設定

| 項目 | 說明 |
|------|------|
| W1 `SONAME_LIBVULKAN` | 編譯用；與 Retina 無關 |
| wine-mono | BlueLauncher .NET |
| `link-wine-runtime-libs.sh` | FreeType／gnutls 執行期 |
| FontSmoothing / fakechinese | 字型策略；Retina 開啟後字體通常已足夠清楚 |
| 手動拉視窗／全螢幕黑屏 | ddraw/wined3d 限制（CrossOver 亦然）；請用啟動器解析度模式 |

## 驗證紀錄

- 2026-07-04：`RetinaMode=y` + `LogPixels=192` 下，啟動器與遊戲畫質、視窗大小與 CrossOver 高解析度模式一致；使用者確認「非常好，達到跟 CrossOver 一樣的效果」。
