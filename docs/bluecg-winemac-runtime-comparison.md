# BlueCG winemac runtime 比較：原版、A2、A4

> 更新：2026-07-12
>
> 對象：CrossOver 26.2.0 source build、x86_64 Wine、BlueCG DirectDraw／wined3d／OpenGL 路徑。
>
> 本文件只比較目前已建立的三組 runtime；A5 的 transaction-scoped 實驗另見 [bluecg-winemac-experiments.md](bluecg-winemac-experiments.md)。

## 一覽結論

| 項目 | 原版 CX26 | A2 | A4 |
|------|-----------|----|----|
| 非 Retina 進入世界後拖曳 | **黑屏** | **正常** | **正常** |
| Retina 進入世界後拖曳 | **黑屏** | **黑屏** | **正常** |
| Retina + launcher 啟動 | 可啟動；resize 後黑屏 | 可啟動；resize 後黑屏 | **可啟動；resize 正常** |
| Alt+Enter（進入世界後） | 已知會黑屏 | Retina=`y` 會黑；Retina=`n` 尚未完整驗證 | **正常** |
| 最小化／還原 | 已有黑屏／同源風險 | 未完成完整矩陣 | **正常** |
| 高 DPI 初始視窗 | backing 路徑可建立，但 resize 風險高 | Retina off 可避開黑屏，但畫質／黑邊需另測 | 不黑，但 render target 不跟著外層視窗放大，內容固定左下且上／右有黑區 |
| BlueCG 目前可用性 | 不可接受 | 非 Retina 可用 | Retina 與非 Retina 均可用，但高 DPI 畫質有折衷 |
| 修改範圍 | 無 | Retina-only guard | 全域停用 explicit backing update/reset |

「正常」是指使用者實際操作後仍可看到遊戲畫面；不代表比例、DPI 畫質或其它遊戲已完全驗證。

## 目前最佳畫質 workaround

依最新實測，使用者觀察到：

- 一般非 Retina：拉大視窗主要是平滑放大，實際渲染畫素沒有同步增加，清晰度較低。
- 高 DPI：會增加遊戲實際渲染像素，但邏輯視窗佔用的螢幕面積也變大。
- RetinaMode：在相同 Mac 視窗大小下提高 backing detail；與高 DPI 搭配效果最好。

目前最理想的操作組合是：

```text
A2
RetinaMode = y
DPI = 196（或顯示器／字體測試中最合適的 96 倍數）
進入遊戲世界前按 Alt+Enter 放到最大
進入世界後不再拖曳或 Alt+Enter
```

這個 workaround 的限制是進入遊戲世界後仍不能改變視窗尺寸；它是畫質優先方案，不是 live resize 修復。

## 三組 runtime 的實作差異

### 原版 CX26

原版在 resize／make-current 時會正常執行：

```text
macdrv_set_view_frame
  → wine_setBackingSize({0,0})
  → wine_updateBackingSize(new client/DPI size)
  → resetSurfaceIfBackingSizeChanged
  → clearDrawable / setView
```

這是功能上最完整的路徑，但 BlueCG 的 frontbuffer onscreen 路徑會在 resize 後留下不可見或脫節的 GL drawable，因此實測拖曳後黑屏。

### A2

A2 在 `cocoa_opengl.m` 對 backing-size 路徑加入 Retina guard：

```c
if (!retina_enabled)
    return;
```

並在 `cocoa_window.m` 只於 RetinaMode 清 backing cache。

效果：

- RetinaMode=`n`：跳過 explicit backing update/reset，BlueCG 拖曳正常。
- RetinaMode=`y`：guard 放行，重新走原版 backing 路徑，拖曳黑屏。

A2 是較保守的 workaround，因為它只改變非 Retina 行為；但它沒有同時解決 Retina 黑屏。

### A4

A4 在所有模式都停用：

- `wine_updateBackingSize()`
- `resetSurfaceIfBackingSizeChanged()`
- resize 時的 `wine_setBackingSize({0,0})`

初始與 resize 都不再重建 explicit CGL backing。這避免了黑屏，但也表示 render target 不會跟隨 DPI-scaled 外層視窗更新。

## 功能支援比較

### BlueCG

A4 是目前最完整的 BlueCG workaround：

- RetinaMode=`y` 拖曳：正常
- launcher 路徑拖曳：正常
- direct 路徑拖曳：正常
- Alt+Enter：正常
- 最小化／還原：正常

A2 只在 RetinaMode=`n` 達成拖曳正常；A2 + RetinaMode=`y` 已確認黑屏。

### 其它 Windows／OpenGL 遊戲

這部分尚未有完整實測，以下是風險推論：

| 類型 | 原版 | A2 | A4 |
|------|------|----|----|
| 不依賴 explicit backing-size 的 2D／GDI | 風險最低 | 風險低 | 風險低至中 |
| 使用一般 OpenGL context 的遊戲 | 功能完整但可能遇到同類 resize 回歸 | Retina off 可能受影響 | 可能依賴 stale backing size，風險最高 |
| 依賴 DPI-aware backing pixels 的遊戲 | 預期最好 | Retina off 可能尺寸不符 | 可能模糊、裁切或黑邊 |
| 需要 fullscreen／display mode transition | 原始設計 | Retina path 仍有問題 | BlueCG 已通過，但其它遊戲未知 |

因此 A4 不宜直接成為所有遊戲共用的預設 Wine engine；它比較適合 BlueCG 專用 runtime 或 per-game override。

## 畫質、尺寸與比例

### 原版

原版的目標是讓 GL backing 與 logical／DPI client size 一致，但 BlueCG 在 resize 後黑屏，故實際畫質無法評估。

### A2

非 Retina 下跳過 explicit backing-size 更新，可能保留原始 render target。A2 的高 DPI 黑邊與清晰度尚未完成獨立測試，不能直接宣稱優於 A4。

### A4

A4 高 DPI 時的實測是：

```text
外層 Cocoa 視窗變大
遊戲 render target 維持原始大小
畫面固定在左下角
上方／右方留下黑區
```

這不是 resize 黑屏，而是「畫面內容沒有被放大到新的 backing pixels」。因此 A4 解決的是可用性，不是高 DPI 畫質。

遊戲畫面是否維持固定比例，還涉及 BlueCG／DirectDraw 的 stretch policy，不能全部歸因於 winemac。

## 效能與資源影響

目前沒有 FPS、CPU、GPU 或 frame-time benchmark，以下分為已知與推論：

| 面向 | 原版 | A2 | A4 |
|------|------|----|----|
| resize 期間 GL surface rebuild | 反覆發生，可能卡頓／延遲 | 非 Retina 跳過 | 全部跳過 |
| resize CPU／GPU 額外工作 | 最高 | 非 Retina 較低 | 最低 |
| surface 重建造成的瞬時資源 | 可能增加 | 非 Retina 較低 | 最低 |
| 正常遊玩每幀成本 | 理論上正常 | 理論上接近原版 | 理論上接近原版 |
| stale／錯尺寸 drawable 風險 | 黑屏風險 | Retina off 較低 | 由黑屏轉為尺寸／畫質風險 |

A4 不應被描述成「一定更快」；它只是少做 backing 重建。若遊戲本身需要 render target 尺寸更新，A4 可能降低畫質而非提升有效效能。

## 適用情境建議

### 目前給 BlueCG 使用者

優先使用 A4：

- 需要 RetinaMode 或高 DPI
- 需要拖曳、Alt+Enter、最小化／還原
- 可以接受高 DPI 時畫面內容不填滿外層視窗

若更重視一般非 Retina 與較小改動，可使用 A2，但 RetinaMode 必須關閉。

### 開發／除錯

保留三組 runtime：

```text
baseline：確認原始回歸
A2：確認非 Retina guard 效果
A4：確認完整停用 backing path 的上限效果
```

### 不建議

不要把 A4 的 `winemac.so` 直接覆蓋所有 Cyder／CyderBits 共用 engine；應維持 BlueCG 專用 runtime，或加入 per-app 選項。

## A6-R1：resize-end commit

A5 已證明「只在 live resize transaction 暫停 backing」可以保留高 DPI backing，但全域狀態沒有涵蓋 Alt+Enter／最小化／還原。A6-R1 已改成 per-view deferral，先收斂 live resize：

1. `windowWillStartLiveResize` 對該 window 的 `WineContentView` 設定 defer。
2. 拖曳期間保留舊 backing/drawable，不反覆 teardown。
3. `WINDOW_RESIZE_ENDED` 先完成 `WM_EXITSIZEMOVE`，再用同步 main-thread barrier 等最後 view frame 落地。
4. 清除 view backing cache、標記 context pending。
5. 下一次 flush/swap 強制 make-current，以最終 DPI client rect 更新並重掛一次。

R1 暫不處理 Alt+Enter、最小化／還原；先確認拖曳放開後能同時得到可見畫面、正確 DPI backing 與無黑邊，再將相同 terminal-commit 模型擴展到其它生命週期。

實測結果：R1 拖曳期間仍顯示舊 drawable，但放大時內容超出視窗、縮小時內容小於視窗且露出區域有殘影；放開滑鼠執行 final commit 後黑屏。因此問題已從「resize 中反覆重建」進一步收斂到 resize-end 的 `clearDrawable` / `setView` 本身。下一版 R2 應在 pending final sync 時只更新 `kCGLCPSurfaceBackingSize`、view backing cache 與 context geometry，不拆除 drawable。

R2 實測：拖曳放大、縮小及連續多次操作皆能在放開後正確滿版顯示，證明 in-place final commit 可同時保留 DPI backing sync 與可見 drawable。Alt+Enter 仍黑，表示 programmatic resize 尚未被標記為 pending，仍落回原版 teardown。R3 應只擴大 in-place commit 的觸發範圍，不改動已成功的 live-resize transaction。

R3 實測：same-view backing resize 全部改用 in-place commit 後，live resize、連續縮放、Alt+Enter 進出及最小化／還原的畫面均正常滿版。這是目前第一個同時保留 Retina+DPI 畫質與主要視窗生命週期可見性的版本。唯一新收斂項目是每次最小化還原後視窗尺寸都會增加；它應獨立列為 Cocoa/Win32 restore geometry 問題，不應再修改已成功的 GL backing 策略。

R4 的 deminiaturize callback guard 未修正尺寸成長；每次還原約放大 2 倍，進一步指向 `macdrv_ShowWindow()` 在 `WINDOW_DID_UNMINIMIZE` 中以 Retina-converted Cocoa frame 覆蓋 user32 saved restore rect。R5 應讓 `WINDOW_DID_UNMINIMIZE` 保留 `window_min_maximize()` 產生的 `newPos`，只有 `WINDOW_FRAME_CHANGED` 才從 Cocoa 取回外部 geometry。

R5 實測完整通過：live resize、連續縮放、Alt+Enter 進出、最小化／還原均正常滿版，重複還原不再改變視窗尺寸。因此 R5 的行為已成為正式 A6 runtime 的基礎；正式包採用 R1、R2、R3、R5 並移除 R4 guard。A/B runtime 驗證移除 R4 後結果不變，故正式版本同時保留原版 DPI backing sync、R2/R3 的 same-view drawable 可見性，以及穩定的 user32 restore geometry。

正式版本與封裝資訊請見 [`bluecg-winemac-a6-engine.md`](bluecg-winemac-a6-engine.md)。

A6 的驗收條件應增加畫質矩陣：

| 設定 | 初始清晰度 | 進世界後拖曳 | Alt+Enter | 最小化／還原 | 黑邊 |
|------|------------|--------------|-----------|---------------|------|
| Retina off、DPI 96 | 基準 | 不黑 | 不黑 | 不黑 | 可接受 |
| Retina on、DPI 196 | 高畫質 | 不黑 | 不黑 | 不黑 | 無 |
| Retina on、DPI 196 + 多次 resize | 高畫質 | 不黑且 render target 跟隨 | 不黑 | 不黑 | 無 |

若 A6 無法穩定覆蓋所有生命週期，A4 仍可作為 BlueCG 專用 fallback；A2 則作為非 Retina 較小修改版本。
