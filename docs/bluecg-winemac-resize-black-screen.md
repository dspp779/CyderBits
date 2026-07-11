# BlueCG 視窗縮放黑屏與 winemac.drv 實驗紀錄

> **狀態：未解決（2026-07）**  
> 供後續追蹤 `winemac.drv` / `ddraw` / `wined3d` 修復與引擎對照。  
> 驗證遊戲：**水藍魔力（BlueCG）** — DirectDraw、PE32、視窗模式。

## 問題摘要

| 現象 | 說明 |
|------|------|
| **手動拖曳視窗邊框縮放** | 遊戲畫面變黑，程式常仍存活 |
| **拖曳過程** | 可能卡頓、延遲（live resize） |
| **全螢幕切換** | 亦有黑屏報告（與 resize 可能同源） |

### 各引擎表現（實測／使用者回報）

| 引擎 | 手動縮放 | 備註 |
|------|----------|------|
| **Sikarugir `WS12WineSikarugir10.0_6`** | 可自由縮放、畫面平滑放大、不黑 | 目標基準線 |
| **商業 CrossOver 24** | 可玩，但縮放亦會黑 | 與自建 CX 類似 |
| **自建 CrossOver 26.2.0 Wine（ogom）** | 黑屏 | 目前主要修復對象 |
| **Cyder（bundled 自建或 Sikarugir engine）** | 自建 engine 黑；換 Sikarugir engine 較佳 | 與底層 Wine 一致 |

**產品目標（使用者）：** 達到 Sikarugir 上「拖邊框自由縮放、畫面平滑、不黑」的行為。

---

## 與其他設定的關係（已排除或無關）

| 項目 | 結論 |
|------|------|
| **RetinaMode** | 關閉後拉窗仍黑 → **非主因** |
| **僅調 winecfg DPI** | 字體筆畫不均、可能黑邊；**不解決黑屏** |
| **Vulkan / DXVK** | BlueCG 走 ddraw → wined3d/GL；關 Vulkan 仍可玩 |
| **gdiplus** | 非此遊戲縮放路徑核心 |
| **官方 28KB `DDRAW.dll`** | 疑似 stub，log 仍見大量 `wined3d`/`ddraw` → **不能當成繞過修復** |

高解析度（Retina + DPI）屬**畫質／視窗大小**議題，見 [mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md)。  
**本文件專注於 live resize 黑屏。**

---

## 圖形呈現路徑（BlueCG）

遊戲 API 是 **DirectDraw**，但 Wine 內建 `ddraw.dll` 在 macOS 上常透過 **wined3d + OpenGL** 呈現，而非純 GDI blit：

```text
bluecg.exe
  → ddraw.dll (Wine builtin 或 native 包裝)
       → 邏輯 surface / cooperative level / clipper
       → wined3d (內部 D3D device / swapchain)
            → OpenGL (GL_FRONT onscreen blit)
                 → winemac.drv (Cocoa WineContentView / client surface)
```

正常遊玩時常見路徑（非每幀 present）：

```text
ddraw_surface_update_frontbuffer
  → wined3d_context_gl_acquire "Rendering onscreen"
  → wined3d_texture_get_gl_buffer → GL_FRONT
  → glBlitFramebuffer ok
```

`macdrv_client_surface_present` 對遊戲主 HWND **多半只在建立時呼叫一次**；之後僅 `client_surface_update`。  
因此黑屏**不能**簡化為「每幀都要有 present」。

---

## 診斷歷程與假設演進

### 階段 1：wined3d swapchain / DC 失效（早期 log）

症狀鏈：

```text
Failed to set pixel format on device context 00000000
Failed to make GL context current on DC 00000000
Trying fallback to the backup window
ddraw_attach_d3d_device: No window → Hidden D3D Window
```

曾出現 **垃圾 client rect**（座標極大、`left > right`），懷疑 `GetClientRect` 在 rebuild 時讀壞。  
部分 log 後來證實來自 **關閉遊戲（SC_CLOSE）** 路徑，與 resize 混淆。

### 階段 2：確認為真實 resize（macdrv trace）

可信的 resize 特徵：

```text
macdrv_query_resize_start hwnd 0x20058
macdrv_window_frame_changed ... resizing from (969x755) to (973x766)
macdrv_window_resize_ended hwnd 0x20058
```

此時 **macdrv 回報的 client rect 合理** → 黑屏較不像「Win32 幾何算錯」。

### 階段 3：present 次數與 wined3d 仍在繪製

對遊戲窗 `0x20058` 的時間軸（精簡）：

```text
~4612     client_surface_present(0x20058)   ← 整場通常僅此一次
~172826   移動窗：client_surface_update，無 present → 仍可顯示
~2822304  query_resize_start
~2838k    拖曳中：多次 client_surface_update，無 present
~2972995  resize_ended
之後      update_frontbuffer + GL_FRONT blit 仍出現（log 顯示成功）
          但使用者畫面已黑
```

**收斂假設：** resize 時 `client_surface_update` 會改 Cocoa view / backing，但 **OpenGL drawable 與可見層脫節**；wined3d 仍 blit 到「已不可見或 backing 為 0」的 drawable。

### 階段 4：原始碼對應（winemac.drv）

縮放觸發鏈（CrossOver 11.0 / CX26 樹）：

```text
NtUserSetRawWindowPos
  → win32u: update_client_surfaces()     # 只 →update，不 →present
    → macdrv_client_surface_update()
      → macdrv_set_view_frame()          # cocoa_window.m
           → [view setFrameSize:...]
           → [view wine_setBackingSize:{0,0}]   ← 清空 GL backing
           → [window updateForGLSubviews]
```

設計上期望之後由 `GL_FLUSH_UPDATED` → `macdrv_surface_flush` → `make_context_current` → `wine_updateBackingSize` 恢復 backing。  
BlueCG 的 **frontbuffer onscreen** 路徑常 **不觸發** 該 flush → backing 維持 0 或 drawable 失效 → 黑屏。

**僅在 `resize_ended` 再呼叫 `present` 可能不夠：** view 已是 `client_view` 時 present 可能是 no-op。

### 階段 5：與上游 Wine / Sikarugir 差異

- 上游 Wine（>11.12）在 view reparent / window 變更時更常呼叫 **`updateForGLSubviews`**，整體策略是「任何影響 GL drawable 的 UI 變動都主動修復」。
- 與本機 `cocoa_window.m` 逐行 diff 時，**`macdrv_set_view_frame` 區塊可能與 GitLab 新版相同**（含 `wine_setBackingSize({0,0})`），表示問題可能在 **其它檔案**（`opengl.c`、`window.c`、`event.c`）或 **Sikarugir 整包 engine 行為**，而非單一函式 diff。

**其它遊戲對照：** 部分 DirectDraw 遊戲（如皮卡球排球）在同版 Wine 上可縮放 → 不同遊戲觸發的 present / swap / flush 路徑不同。

---

## 關鍵 log 片段（篩選用）

### 抓取建議

```bash
cd /path/to/ogom
source scripts/env-x86_64.sh
export WINEPREFIX="$BLUECG_PREFIX"
export WINEDEBUG=+loaddll,+ddraw,+d3d,+wined3d,+macdrv

LOG="$HOME/Desktop/bluecg-resize-$(date +%Y%m%d-%H%M%S).log"
arch -x86_64 env WINEDEBUG="$WINEDEBUG" \
  bash scripts/run-bluecg.sh --direct --ddraw-source official \
  >"$LOG" 2>&1
```

操作：進遊戲 → **只拖邊框**（勿關窗）→ 黑屏後 `Ctrl+C`。

### 要 grep 的關鍵字

| 目的 | 模式 |
|------|------|
| 確認是 resize | `query_resize_start`, `window_frame_changed`, `resize_ended` |
| 排除關遊戲 | `SC_CLOSE`, `f060`, `SysCommand`, `DestroyWindow 0x20058` |
| client surface | `client_surface_present`, `client_surface_update` |
| wined3d 繪製 | `update_frontbuffer`, `Rendering onscreen`, `GL_FRONT` |
| GL 失敗 | `device context 00000000`, `GL_INVALID_FRAMEBUFFER_OPERATION` |
| ddraw 重建 | `SetCooperativeLevel`, `Hidden D3D Window` |

### 決定性行（範例 HWND `0x20058`）

```text
client_surface_present 0x20058        # 啟動後常僅一次
client_surface_update 0x20058         # resize 期間多次，無第二次 present
update_frontbuffer ... Rendering onscreen ... GL_FRONT
```

---

## winemac.drv 相關原始碼地圖

路徑：`build/cx26/sources/wine/dlls/winemac.drv/`（或 `sources/wine` 若為 symlink）

| 檔案 | 與本議題相關的符號／行為 |
|------|---------------------------|
| `cocoa_window.m` | `macdrv_set_view_frame`, `wine_setBackingSize`, `updateForGLSubviews`, `WineContentView` |
| `cocoa_opengl.m` | `wine_updateBackingSize`, `make_context_current`, Cocoa GL context |
| `opengl.c` | `macdrv_surface_flush`, `GL_FLUSH_UPDATED`, drawable 綁定 |
| `window.c` | `macdrv_client_surface_update` / `present`, `macdrv_window_resize_ended` |
| `event.c` | resize 事件、`macdrv_client_surface_presented`（見 W3） |
| `surface.c` | client surface 生命週期 |
| `macdrv_main.c` | `RetinaMode` registry |
| `dlls/win32u/window.c` | `update_client_surfaces` — resize 只 update 不 present |
| `dlls/wined3d/context_gl.c` | onscreen blit、`wined3d_context_gl_set_gl_context` |
| `dlls/ddraw/` | `ddraw_surface_update_frontbuffer`, cooperative level, hidden window |

---

## 文件化 workaround（W2 / W3）

定義於 [bluecg-wine-build plan](superpowers/plans/2026-07-03-bluecg-wine-build.md) § macOS build workarounds。**未納入建置腳本**；僅在 clean build 失敗或實驗時手動套用。

| ID | 檔案 | 變更 | 與 resize 黑屏關係 |
|----|------|------|-------------------|
| **W2** | `cocoa_window.m` | `WineMetalLayer` → `CAMetalLayer` | 編譯／D3DMetal 路徑；**未證實修復 BlueCG resize** |
| **W3** | `event.c` | 刪除 `macdrv_client_surface_presented` 處理 | 可能避開 present 同步卡死；**可能加劇 drawable 脫節，需謹慎** |

還原單檔：

```bash
TAR=tools/archives/crossover-sources-26.2.0.tar.gz
tar -xOf "$TAR" sources/wine/dlls/winemac.drv/cocoa_window.m \
  > build/cx26/sources/wine/dlls/winemac.drv/cocoa_window.m
```

套用紀錄請寫入 `logs/workarounds.md`（若尚未建立可自建）。

---

## 建議修復方向（實驗優先順序）

以下為診斷後的**待驗證**方案，非已合併 patch。

### 方案 A：resize 後強制恢復 backing（最小侵入）

在 `macdrv_set_view_frame` 或 `macdrv_window_resize_ended` 末尾：

- 除 `wine_setBackingSize({0,0})` + `updateForGLSubviews` 外，
- 依新 client 尺寸呼叫 **`wine_updateBackingSize`**（或等同路徑），
- 必要時對該 HWND **強制 `client_surface_present`**（需確認非 no-op）。

### 方案 B：避免清空 backing

實驗性 **註解或條件化** `wine_setBackingSize({0,0})`，僅在 `setFrameSize` 後依新尺寸直接 `wine_updateBackingSize`。  
風險：其它遊戲／全螢幕路徑回歸。

### 方案 C：從 win32u 補 present

在 `update_client_surfaces()` 對「尺寸變更」的 surface 在 `update` 後呼叫 `present`（改動面大，需全平台評估）。

### 方案 D：對照 Sikarugir / 上游

- binary diff `winemac.so`、`ddraw.dll`、`wined3d` 相關 PE
- cherry-pick 上游 Wine `winemac.drv` resize 相關 commit（>11.12）
- 確認 Sikarugir 是否另有 **registry / 環境變數** 改變 present 行為

### 方案 E：產品迴避（非修復）

- 用啟動器解析度預設視窗大小，**不依賴拖邊框**
- 文件化為已知限制（見 [bluecg.md](bluecg.md)）

---

## 僅重編 winemac.drv

前提：`build64` 已完整 configure 過。

```bash
source scripts/env-x86_64.sh
BUILD_PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$WINE_SRC/build64"

# 勿只用 make dlls/winemac.drv（目錄 target 會 no-op）
arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
  make -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so

# 手動安裝（Wine 無 per-module install target）
install -m 755 \
  "$WINE_SRC/build64/dlls/winemac.drv/winemac.so" \
  "$WINE_INSTALL/lib/wine/x86_64-unix/winemac.so"

bash scripts/sign-wine.sh
```

強制重編單檔：`rm dlls/winemac.drv/cocoa_window.o` 後再 make `winemac.so`。

驗證載入：

```bash
otool -L "$WINE_INSTALL/lib/wine/x86_64-unix/winemac.so" | head
ls -la "$WINE_INSTALL/lib/wine/x86_64-unix/winemac.so"
```

---

## ddraw override 實驗矩陣（Sikarugir 上曾測）

| Override | 行為摘要 |
|----------|----------|
| 未設定 / 內建優先 | 可縮放，不維持比例 |
| 原生優先（BlueGC `DDRAW.dll`） | 可縮放，**維持比例** |
| 原生（cnc-ddraw） | 全螢幕、破圖色偏 |
| 原生（DDrawCompat） | 崩潰 |

在 **自建 CX26** 上即使設 native `DDRAW.dll`，log 仍顯示 wined3d 活動 → **仍需修 Wine 本體**。

---

## 開放問題

1. `wine_setBackingSize({0,0})` 在 resize 當下是否**一定**被呼叫？（建議 lldb breakpoint 或暫加 TRACE）
2. 黑屏當下 `GL_FRONT` blit 成功但螢幕黑 → **Cocoa layer 可見性 / contentsScale / Metal layer** 是否未同步？
3. Sikarugir 與 CX26 的 `winemac.so` **二進位差異** 清單尚未完整歸檔
4. live resize **卡頓** 與黑屏是否同一根因，或需分開優化（減少 resize 期間 GL 重建次數）
5. 是否應在 `pack-engine-artifact.sh` 對照 Sikarugir 一併記錄 `winemac` build id

---

## 相關文件

| 文件 | 內容 |
|------|------|
| [bluecg.md](bluecg.md) | 建置、執行、已知雜訊 |
| [superpowers/specs/2026-07-04-mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md) | Retina／DPI（與黑屏分開） |
| [superpowers/plans/2026-07-03-bluecg-wine-build.md](superpowers/plans/2026-07-03-bluecg-wine-build.md) | W1–W3 workaround 定義 |
| [patches/README.md](../patches/README.md) | W1 Vulkan 編譯 patch |
| [wine-configure-options.md](wine-configure-options.md) | 引擎 configure 參考 |

---

## 變更紀錄

| 日期 | 備註 |
|------|------|
| 2026-07-08 | WINEDEBUG 診斷：鎖定 ddraw→wined3d→GL；排除 Retina |
| 2026-07-08 | 確認 resize trace；收斂至 client_surface / backing 假設 |
| 2026-07-09 | winemac 增量編譯流程；對照上游 `cocoa_window.m` |
| 2026-07-11 | 彙整為本追蹤文件 |
