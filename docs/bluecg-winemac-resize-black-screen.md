# BlueCG 視窗縮放黑屏與 winemac.drv 實驗紀錄

> **狀態：未解決（2026-07）**  
> 供後續追蹤 `winemac.drv` / `ddraw` / `wined3d` 修復與引擎對照。  
> 驗證遊戲：**水藍魔力（BlueCG）** — DirectDraw、PE32、視窗模式。

## 問題摘要

| 現象 | 說明 |
|------|------|
| **手動拖曳視窗邊框縮放** | 進入遊戲後變黑，程式常仍存活 |
| **進入遊戲前調窗** | 視窗出現後、進入遊戲世界前調整大小**來得及**，不黑屏 |
| **Alt+Enter 等比展開** | **僅進入遊戲前**可等比放到最大且不黑；**進入遊戲後** Alt+Enter 亦會黑屏 |
| **拖曳過程** | 可能卡頓、延遲（live resize） |
| **全螢幕切換** | 亦有黑屏報告（與 resize 可能同源） |

### 觸發時機（2026-07-11 確認）

```text
進入遊戲世界、ddraw frontbuffer onscreen 路徑跑起來之後
  → 任何改變視窗尺寸（拖邊框、Alt+Enter、WM_SIZE）皆可能黑屏

進入遊戲世界之前（載入／啟動畫面）
  → 調窗、Alt+Enter 等比放到最大皆可
```

這不是「拖邊框 vs Alt+Enter」的差異，而是 **onscreen 繪製建立前後** 的狀態差。

### 各引擎表現（實測矩陣，2026-07-11）

以下皆為**手動拖曳邊框、平滑放大**（非 GDI 路徑）：

| 引擎 | 預設 | +高 DPI | +RetinaMode | 備註 |
|------|------|---------|-------------|------|
| **Sikarugir Wine 10** | 平滑縮放、不黑 | 不黑，上／右有黑邊（DPI 越高越大） | **黑屏** | 基準線 |
| **Sikarugir CrossOver 24** | 平滑縮放、不黑 | 不黑，畫面滿版無黑邊 | **黑屏** | DPI 佈局優於 Wine 10 |
| **自建 CrossOver 26.2.0 Wine（ogom）** | 黑屏 | 黑屏 | 黑屏 | 目前主要修復對象 |
| **官方 CrossOver 26** | 黑屏 | 黑屏 | 黑屏 | 與自建 CX 類似 |
| **Cyder（bundled engine）** | 自建 engine 黑；換 Sikarugir engine 較佳 | — | — | 與底層 Wine 一致 |

> 先前記載「商業 CrossOver 24 縮放亦會黑」可能指非 Sikarugir 打包的 CX24；**Sikarugir 版 CX24 在無 RetinaMode 下可正常縮放**。

### 黑邊 vs 黑屏（兩個不同問題）

| 現象 | 觸發條件 | 性質 |
|------|----------|------|
| **黑邊**（上／右留白） | 僅調高 DPI、不開 RetinaMode（如 Sikarugir Wine 10） | 佈局／DPI 換算；見 [mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md) |
| **整片黑屏** | RetinaMode，或 CX26 GL 路徑預設 | GL backing／drawable 在 resize 後未恢復；**本文件主議題** |

**產品目標（使用者）：**

1. **必須**：GL 路徑下拖邊框平滑縮放、不黑（對照 Sikarugir Wine 10 / CX24）
2. **加分**：高 DPI 滿版無黑邊（Sikarugir CX24 已做到）
3. **長期**：RetinaMode + 平滑縮放同時成立（目前所有引擎在 Retina 下皆黑）

---

## 與其他設定的關係

| 項目 | 結論 |
|------|------|
| **RetinaMode** | 在**可正常縮放的引擎**（Sikarugir Wine 10 / CX24）上，開啟後拉窗**會黑屏**；在 CX26 上關閉 Retina 仍黑 → Retina 是**觸發因子**，非唯一根因 |
| **僅調 winecfg DPI** | 不解決 CX26 黑屏；在 Sikarugir 上可能引入黑邊（Wine 10）或滿版（CX24） |
| **Vulkan / DXVK** | BlueCG 走 ddraw → wined3d/GL；關 Vulkan 仍可玩 |
| **gdiplus** | 非此遊戲縮放路徑核心 |
| **官方 28KB `DDRAW.dll`** | 疑似 stub，log 仍見大量 `wined3d`/`ddraw` → **不能當成繞過修復** |
| **GDI renderer registry**（見下節） | 可繞過黑屏；**不受 DPI／RetinaMode 影響**；縮放變模糊 → **證實根因在 GL 路徑** |

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

### GDI 強制路徑（診斷用 workaround）

在自建 CX26／官方 CX26 上，於 `HKEY_CURRENT_USER\Software\Wine\Direct3D` 寫入：

| 鍵 | 值 | 作用 |
|----|-----|------|
| `renderer` | `gdi` | wined3d 改用 GDI 呈現 |
| `DirectDrawRenderer` | `gdi` | ddraw 走 GDI blit |
| `MaxVersionGL` | `1.0` | 限制 GL 版本 |
| `CSMT` | `0` | 關閉 command stream multithreading |

效果：

- **縮放不黑屏**；無論 DPI 或 RetinaMode 如何設定皆可拖邊框縮放
- 縮放時**較模糊、非平滑放大**（軟體 blit 不支援 `WINED3D_TEXF_LINEAR`）
- 此 workaround **僅供診斷／暫用**，不適合作產品方案；目標仍是修復 GL 路徑

```text
預設路徑：  ddraw → wined3d → OpenGL → winemac.drv   → 平滑但 CX26 黑屏
GDI 路徑：  ddraw → GDI blit → winemac（非 GL backing）→ 不黑但模糊
```

#### GDI 路徑下的畫質折衷（自建 CX26 實測）

若必須使用 GDI 路徑，可組合 **RetinaMode + 高 DPI**（例如 `LogPixels=240`）讓靜態畫面字體較平滑；但**一縮放就會變模糊**。實務上應在進遊戲前把視窗調到**接近目標螢幕大小**，進入後盡量不要再拖邊框。

#### GDI 路徑常見 log（可忽略）

啟動時：

```text
err:winediag:wined3d_dll_init Disabling 3D support.
err:winediag:wined3d_cs_create Enabling CS commands serialization.
err:d3d_sync:wined3d_cs_create Forcing serialization of all command streams.
err:dmloader:get_system_default_gm_path Unable to find system path, default collection will not be available
```

縮放視窗後會反覆出現（對應模糊縮放根因）：

```text
fixme:d3d:surface_cpu_blt Filter WINED3D_TEXF_LINEAR not supported in software blit.
```

#### GDI 與 `WINED3D_TEXF_LINEAR`（無 registry 解法）

`renderer=gdi` 對應 wined3d 的 `WINED3D_RENDERER_NO3D`，縮放走 CPU `surface_cpu_blt`。**Wine 軟體 blit 未實作線性過濾**——遊戲要求 `WINED3D_TEXF_LINEAR` 時只打 FIXME，實際用較差的 stretch（最近鄰或簡化縮放）。**沒有 registry 或環境變數可開啟**。

RetinaMode + 高 DPI 讓靜態畫面清楚，是因為遊戲在**高邏輯解析度**繪製、視窗大小事先調準後 blit 接近 1:1；一縮放仍須軟體 stretch 整張 buffer → 模糊。

若要在 GDI 路徑改善縮放品質，需 **patch `dlls/wined3d/surface.c`** 在 `surface_cpu_blt` 實作雙線性插值（見方案 F）。仍為 CPU 路徑，效能與畫質不如 GPU。

### Renderer 選項與取捨（macOS + DirectDraw）

Wine `HKCU\Software\Wine\Direct3D\renderer` 有效值：`gl`、`gdi`（同 `no3d`）、`vulkan`。

| 路徑 | 線性縮放 | resize 不黑（CX26） | 對 BlueCG |
|------|----------|---------------------|-----------|
| **`gl`（預設 OpenGL）** | ✅ GPU | ❌；Sikarugir ✅ | **正解方向**——修 winemac backing |
| **`gdi`** | ❌ 軟體 blit | ✅ | 診斷／暫用繞道 |
| **`vulkan`** | ✅（GPU） | ❓ 未驗證，預期不佳 | **不建議**——主要服務 D3D10/11；ddraw 仍走舊鏈；winemac Vulkan 亦用 Metal surface，可能有類似 backing 問題 |
| **DXVK / MoltenVK** | — | — | ddraw 遊戲不走此路 |
| **原生 DDRAW 替換** | 視包裝而定 | 視包裝而定 | cnc-ddraw 破圖、DDrawCompat 崩潰、官方 stub 仍見 wined3d（見下方矩陣） |

**結論：** 目前唯一同時滿足「平滑線性縮放 + resize 不黑」的已知組合是 **Sikarugir 的 GL 路徑（無 RetinaMode）**。不存在只改 registry 的第三條路；正確投資是修 winemac GL backing 恢復（方案 A），而非換 renderer。

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

### 階段 6：引擎 × 設定矩陣與 GDI 繞道（2026-07-11）

使用者對 Sikarugir Wine 10、Sikarugir CX24、自建 CX26、官方 CX26 做系統性實測，收斂如下：

1. **黑屏根因高度集中在 OpenGL 呈現路徑**：GDI registry 可繞過黑屏但犧牲縮放品質，與階段 3–4 的 backing 假設一致。
2. **RetinaMode 是觸發因子**：`contentsScale=2` 使 resize 時 `wine_setBackingSize` / `wine_updateBackingSize` 恢復鏈更脆弱；在本身能縮放的 Sikarugir 引擎上，開 RetinaMode 即黑。
3. **Sikarugir CX24 是更接近目標的對照**：無 Retina 時不僅可縮放，高 DPI 還能滿版無黑邊（優於 Wine 10）。
4. **CX26 預設 GL 路徑即壞**：與 Sikarugir 的差距在 engine 實作（winemac / wined3d），非遊戲或 DDRAW override 單獨能解。
5. **黑屏與 onscreen 繪製建立時機有關**：進入遊戲世界前調窗／Alt+Enter 安全；**進入遊戲世界後**任何改尺寸（含 Alt+Enter）皆黑 → 與 frontbuffer onscreen 路徑在首次 present 後 drawable 狀態改變的假設一致。

### 階段 7：Renderer 取捨與 GDI 線性過濾限制（2026-07-11）

1. **進入遊戲後 Alt+Enter 亦黑** → 排除「Alt+Enter 走不同 resize 路徑所以安全」的假設。
2. **GDI 無法啟用 `WINED3D_TEXF_LINEAR`** → `surface_cpu_blt` 實作缺口；高 DPI 策略是減少縮放需求，非真正線性過濾。
3. **macOS 上無第三 renderer 可兩全** → `gl` 修 winemac 是根本解法；`vulkan` 不適用 ddraw 時代遊戲。

#### 根因三層模型（收斂）

```text
Layer 1  winemac resize 清空 GL backing
         macdrv_set_view_frame → wine_setBackingSize({0,0})

Layer 2  恢復機制未觸發（BlueCG frontbuffer onscreen 特有）
         期望 GL_FLUSH_UPDATED → wine_updateBackingSize
         此路徑常不觸發 → backing 維持 0

Layer 3  RetinaMode 加劇（Sikarugir 亦中招）
         contentsScale=2 → 實體／邏輯像素換算使恢復更難
```

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
| `dlls/wined3d/surface.c` | `surface_cpu_blt` — GDI 路徑軟體 blit；`WINED3D_TEXF_LINEAR` 未實作 |
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

### 方案 D：對照 Sikarugir / 上游（優先）

- binary diff `winemac.so`、`ddraw.dll`、`wined3d` 相關 PE（**Sikarugir Wine 10 與 CX24 皆為基準**）
- cherry-pick 上游 Wine `winemac.drv` resize 相關 commit（>11.12）
- 確認 Sikarugir 是否在 resize 後有額外 `wine_updateBackingSize` / `client_surface_present` 呼叫
- 在 CX26 與 Sikarugir 上對照 `WINEDEBUG=+macdrv,+wined3d` resize 時間軸

### 方案 E：產品迴避（非修復）

| 做法 | 說明 |
|------|------|
| **啟動器解析度** | 預設目標視窗大小，不依賴拖邊框（見 [bluecg.md](bluecg.md)） |
| **進入遊戲前調窗** | 載入／啟動畫面階段可自由調整，不會黑屏 |
| **進入遊戲前 Alt+Enter** | 等比展開到最大，可得大畫面且不黑；**進入遊戲世界後勿再 Alt+Enter 或拖邊框** |
| **GDI registry** | 自建 CX26 進入遊戲後仍可拖邊框不黑，但縮放模糊；RetinaMode + 高 DPI 改善靜態字體 → 進遊戲前調到接近螢幕大小、進入後盡量別縮放 |

### 方案 F：patch `surface_cpu_blt` 線性過濾（GDI 妥協，低優先）

在 `dlls/wined3d/surface.c` 為 `WINED3D_TEXF_LINEAR` 實作雙線性插值。僅改善 GDI 路徑縮放品質，仍為 CPU、較慢，**不解決**「要 Sikarugir 級 GPU 平滑縮放」的需求。

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
2. 黑屏當下 `GL_FRONT` blit 成功但螢幕黑 → **Cocoa layer 可見性 / contentsScale / Metal layer** 是否未同步？（RetinaMode 觸發黑屏與此高度相關）
3. Sikarugir Wine 10 / CX24 與 CX26 的 `winemac.so` **二進位差異** 清單尚未完整歸檔
4. live resize **卡頓** 與黑屏是否同一根因，或需分開優化（減少 resize 期間 GL 重建次數）
5. 是否應在 `pack-engine-artifact.sh` 對照 Sikarugir 一併記錄 `winemac` build id
6. **RetinaMode 單獨開、DPI=96** 在 Sikarugir 上是否亦黑？（釐清 Retina 與 Retina+DPI 組合）
7. GDI registry 在 Sikarugir 上是否同樣變模糊但不黑？（自建 CX26 已確認；Sikarugir 待測）
8. **onscreen 繪製建立後** resize 才黑 → 能否在 ddraw attach／首次 frontbuffer 後補強 backing 恢復？（進入遊戲後 Alt+Enter 亦黑，已確認非 live-drag 特有）
9. patch `surface_cpu_blt` 線性過濾後，GDI 路徑縮放品質是否可接受為暫用方案？

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
| 2026-07-11 | 引擎×設定矩陣實測；GDI 繞道；RetinaMode 改為觸發因子；區分黑邊與黑屏 |
| 2026-07-11 | 畫面出現前可調窗、Alt+Enter 迴避；GDI 路徑 DPI/Retina 細節與 log |
| 2026-07-11 | 進入遊戲後 Alt+Enter 亦黑；GDI 無 TEXF_LINEAR；renderer 取捨表；根因三層模型 |
