# Cyder / Wine 環境下執行 Steam (CEF / WebView2) 之黑屏調查與實驗報告

## 1. 問題概述與現象彙整

在 Cyder（基於自編 CrossOver Wine 引擎的 macOS 運行環境）中，透過 Winetricks 安裝 Steam 後，Steam 會在首次啟動時執行強制線上自我更新（Auto-Update）。升級至現代 64 位元客戶端後，出現 **視窗能開啟但內容完全漆黑** 的相容性障礙。

### 實測現象紀錄表

| 實驗情境 / 參數標記 | 視窗狀態 | 滑鼠互動 (Hover/Click) | 視窗畫面呈現 |
| :--- | :--- | :--- | :--- |
| **預設啟動（更新後）** | 正常開啟，無閃退 | 局部區域可變更鼠標型態 | **完全全黑** |
| **加入 `-no-cef-sandbox -cef-disable-gpu`** | 正常開啟，無閃退 | 局部區域可變更鼠標型態 | **完全全黑** |
| **加入 `-cef-disable-gpu-compositing`** | 正常開啟，無閃退 | 局部區域可變更鼠標型態 | **完全全黑** |
| **加入 `-disable-vulkan`** | 正常開啟，無閃退 | 局部區域可變更鼠標型態 | **完全全黑** |
| **設定 `renderer=gdi` (註冊表覆寫)** | 正常開啟，無閃退 | 局部區域可變更鼠標型態 | **完全全黑** |

> [!IMPORTANT]
> **極關鍵實驗發現：**  
> 儘管畫面呈現整片漆黑，但當滑鼠移動到視窗內部某些區域時，**鼠標會自動轉變為手型（連結型態）**，點擊該區域**能成功觸發網頁跳轉並在預設瀏覽器中開啟**。

---

## 2. 深度技術根因診斷

根據「DOM/邏輯存活，但視窗全黑」以及 Vulkan Debug Log，可將根因收斂為以下三個層面：

### 2.1 CEF (Chromium Embedded Framework) 多進程邏輯與畫布隔離
現代 Steam 的核心介面（商店、程式庫、社群）完全由基於 Chromium 的 `steamwebhelper.exe` 進程負責渲染。
* **DOM 與 Win32 訊息循環正常：** `Steam.exe` 與 `steamwebhelper.exe` 之間的 IPC 通訊、Win32 `WM_MOUSEMOVE` 訊息處理、DOM 排版與 JavaScript 事件監聽均 **100% 正常運作**（因此滑鼠移上去會有反應，點擊能開網頁）。
* **繪圖與顯示層脫節：** CEF 在背景順利完成了網頁繪製，但產出的 Framebuffer 缺乏正確的管道 Present 至 macOS 的 Cocoa 視窗畫布。

```mermaid
flowchart LR
    A[Steam.exe / Win32 Message Loop] -->|Mouse / Key Events| B[steamwebhelper.exe / CEF DOM]
    B -->|JavaScript / Click Trigger| C[System Browser / Action OK]
    B -->|Render Framebuffer| D[winemac.drv / Layer Present]
    D -- 斷裂 / 不可見 --x E[macOS NSWindow / CALayer (Pitch Black)]
```

### 2.2 為甚麼連 `renderer=gdi` 都無法顯示？
在 Wine 中，`renderer=gdi` 常用於避開 3D/OpenGL 渲染問題。然而 Steam 依然全黑的原因在於：
1. **CEF 獨立離屏渲染（Offscreen Layered Window）：** `steamwebhelper.exe` 並非傳統使用 GDI API 繪製視窗的程式，而是自己管理 DIB section / DirectComposition 緩衝區。
2. **`winemac.drv` 子視窗繪製機制：** CEF 的主渲染視窗是嵌套在 Steam 主視窗下的子 HWND。自編 Wine 的 `winemac.drv` 若在子視窗 `update_client_surfaces` 或 Layered Window 的 BitBlt 處理上有缺失，即使切換到 GDI 模式，後台的像素陣列依然無法同步至前端 Cocoa View。

### 2.3 Vulkan / MoltenVK 初始化失敗日誌分析

在執行 `WINEDEBUG=+vulkan wine Steam.exe` 時，擷取到以下關鍵 Log：

```text
04cc:trace:vulkan:vulkan_init_once Host instance extensions:
04cc:trace:vulkan:vulkan_init_once   - VK_EXT_metal_surface
04cc:trace:vulkan:vulkan_init_once   - VK_MVK_macos_surface
04cc:warn:vulkan:vulkan_init_once Extension "VK_MVK_moltenvk" is not supported.
04cc:trace:vulkan:win32u_vkCreateInstance Instance proc vkCreateMacOSSurfaceMVK not found.
04cc:trace:vulkan:win32u_vkCreateInstance Instance proc vkCreateMetalSurfaceEXT not found.
```

#### 診斷結論：
1. **MoltenVK dylib 載入成功：** Wine 的 `win32u.dll` 已經正確 `dlopen("libMoltenVK.dylib")`，並識別出 macOS Metal Surface 擴充。
2. **符號 (Proc Address) 解析失敗：** 由於缺乏 **Vulkan Loader (`libvulkan.1.dylib`)** 以及 CrossOver 官方對 `winevulkan` 的完整表面建立 Patch，Wine 向 MoltenVK 查詢 `vkCreateMetalSurfaceEXT` 函數指標時回傳了 `NULL`，導致 Chromium 在初始化 3D / Vulkan 繪圖上下文時拋出異常。

---

## 3. CrossOver 官方讓 Steam 運作的修復架構

CrossOver (CodeWeavers) 能夠順暢執行 Steam，主要依賴以下四個維度的整合：

```
+-----------------------------------------------------------------------+
|                         CrossOver Steam 運行層                         |
+-----------------------------------------------------------------------+
|  1. Vulkan-Loader + DXVK (libvulkan.1.dylib + libMoltenVK.dylib)      |
|  2. winemac.drv Same-View Backing Sync (A6 Layer Synchronization)     |
|  3. Wine-CX 專屬 winevulkan / win32u Surface Creation Patches          |
|  4. 自動化 CrossTie (Win10 64-bit + Corefonts + VC++ Runtime)           |
+-----------------------------------------------------------------------+
```

1. **完整 Vulkan 驅動鏈：** 不直接 `dlopen` MoltenVK，而是經過 `libvulkan.1.dylib` + `MoltenVK_icd.json`，搭配 DXVK 將 D3D11/Vulkan 轉譯為 Apple Metal。
2. **`winemac.drv` 圖層同步 (Backing Sync)：** 修復 CGL / `CAMetalLayer` 在視窗尺寸變更與多視窗嵌套時的 `updateForGLSubviews` 邏輯，防止畫面與 `WineContentView` 脫節。
3. **CEF 沙盒與環境配置：** 透過內建腳本自動注入 `-no-cef-sandbox` 及 `vcrun2019/2022` 核心組件。

---

## 4. 後續實驗與修復建議行動計畫

> [!TIP]
> 針對目前自編 Wine 引擎的狀況，建議依照下列步驟進行修復與測試：

### 階段一：導入 Vulkan Loader 與 ICD 配置
1. 在系統中安裝 Vulkan Loader：
   ```bash
   brew install vulkan-loader
   ```
2. 建立 `MoltenVK_icd.json` 配置檔，並在執行時指定環境變數：
   ```bash
   export VK_ICD_FILENAMES="/path/to/MoltenVK_icd.json"
   ```
3. 重新驗證 `WINEDEBUG=+vulkan` 日誌，確認 `vkCreateMetalSurfaceEXT` 是否成功導出。

### 階段二：`winemac.drv` 子視窗與 CALayer 追蹤 (Trace)
1. 開啟 `WINEDEBUG=+macdrv,+win` 追蹤 `steamwebhelper.exe` HWND 的建立與 `client_surface_update` / `present` 事件。
2. 檢查 `cocoa_window.m` 中 `WineContentView` 是否成功掛載 `CAMetalLayer`，並比對 Cyder `a6-final-same-view-backing-sync.patch` 補丁。

### 階段三：嘗試替代性啟動標記
嘗試傳入精簡模式（Small Mode）或指定舊版 UI，繞過重度網頁渲染：
```bash
Steam.exe -smallmode -no-cef-sandbox -cef-disable-gpu -cef-disable-gpu-compositing
```
