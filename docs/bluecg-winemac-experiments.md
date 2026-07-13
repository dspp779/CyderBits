# BlueCG winemac resize 實驗 runtime

> 建立日期：2026-07-12
>
> 目的：在不覆蓋主要 CX26 runtime 或遊戲檔案的前提下，並存保存 baseline、A1、A2、A3，供之後透過遠端桌面或本機逐組測試。

## Runtime 對照

runtime 位置：`install/wine-experiments/`

| 名稱 | `winemac.drv` 變更 | 用途 |
|------|-------------------|------|
| `baseline` | 原始 CX26 binary | 確認目前黑屏基準 |
| `a1` | `macdrv_set_view_frame()` 只有 RetinaMode 才清 backing-size cache | 第一優先實驗：測試非 Retina 回歸 |
| `a2` | A1 + `resetSurfaceIfBackingSizeChanged()` 與 `wine_updateBackingSize()` 只在 RetinaMode 執行 | guard-only backing-size 實驗 |
| `a3` | resize 完全略過 `wine_setBackingSize({0,0})` | 測試 cache invalidation / drawable rebuild 是否為觸發點 |
| `a4` | 無條件停用 backing-size update/reset，且不清 resize cache | RetinaMode 路徑的診斷實驗；可能犧牲高解析度 |
| `a5` | 只在 `QUERY_RESIZE_START` 到 `WINDOW_RESIZE_ENDED` 期間停用 backing update/reset | 目標修復：保留平時 DPI backing，同時避免 live resize 黑屏 |
| `a6-r1` | per-view 延後 live-resize backing sync；resize end main-thread barrier 後由下一次 flush 以最終 DPI rect 同步 | 第一版 resize-end commit；允許拖曳中顯示舊畫面，要求放開後正確恢復且無 DPI 黑邊 |
| `a6-r2` | R1 + final pending sync 只做 in-place CGL backing/context update，不執行 `clearDrawable` / `setView` | 驗證 resize-end drawable teardown/reattach 是否為直接黑屏點 |
| `a6-r3` | R2 + context 維持同一 view 時一律使用 in-place backing update；切換 view 仍保留原版 attach | 將成功路徑擴展至 Alt+Enter 等 programmatic resize |
| `a6-r4` | R3 + 最小化前保存 Cocoa frame；還原時 frame 未改變便略過重複 `windowDidResize()` | 修正反覆 deminiaturize 導致視窗逐次變大的 geometry round-trip |
| `a6-r5` | R4 + `WINDOW_DID_UNMINIMIZE` 不再以 Retina-converted Cocoa frame 覆蓋 user32 saved restore rect | 讓 `window_min_maximize()` / `rcNormalPosition` 成為還原尺寸權威來源 |
| `a6-final-no-r4` | R1 + R2 + R3 + R5；移除未能改善結果的 R4 guard | 正式 BlueCG 高 DPI engine |

A2 是依目前 CX26 source tree 建立的 guard-only 版本。上游 !7979 的 window-DPI rect 改動未在 A2 回退，因為目前 source tree 的 `macdrv_context` 結構已與上游 patch diff 不同；不要把 A2 解讀為完整 MR !7979 revert。

## 已完成結果

| 實驗 | RetinaMode | 拖曳結果 |
|------|------------|----------|
| A1 | `n` | 黑屏 |
| A2 | `n` | **成功，仍有遊戲畫面** |
| A3 | `n` | 黑屏 |
| A2 | `y` | 黑屏 |
| A4 | `y` | **功能成功；拖曳、Alt+Enter、最小化／還原正常，但高 DPI 有黑邊** |
| A5 | `y` | **live resize 不黑且無高 DPI 黑邊；Alt+Enter／最小化還原失敗** |
| A6-R1 | `y` | **拖曳中舊畫面縮放比例錯誤並有殘影；放開滑鼠後黑屏** |
| A6-R2 | `y` | **連續放大／縮小皆正常且放開後滿版；Alt+Enter 黑屏** |
| A6-R3 | `y` | **拖曳、連續縮放、雙向 Alt+Enter、最小化還原畫面皆正常滿版；每次還原視窗會變大** |
| A6-R4 | `y` | **R3 功能正常；最小化／還原仍固定放大約 2 倍** |
| A6-R5 | `y` | **完整通過：拖曳、連續縮放、雙向 Alt+Enter、重複最小化／還原皆正常滿版且尺寸固定** |

A2 已證實 guard-only backing-size 變更足以避開目前的非 Retina resize 黑屏；A3 黑屏則表示只略過 `wine_setBackingSize({0,0})` 不足以修復，關鍵較可能在 `wine_updateBackingSize()` / `resetSurfaceIfBackingSizeChanged()` 路徑。A2 + RetinaMode=`y` 再次黑屏，表示目前修復只適用非 Retina 路徑。A5 顯示 transaction-scoped suppression 能保留高 DPI backing 並避免 live resize 黑屏，但狀態未在 Alt+Enter／最小化／還原路徑清理。

A4 的早期 launcher 啟動曾出現 `GL_INVALID_FRAMEBUFFER_OPERATION` 訊息；重新啟動後 launcher 路徑可正常執行。A4 已同時通過 direct 與 launcher resize、Alt+Enter、最小化／還原；但高 DPI 會使外層視窗放大、遊戲 render target 維持原尺寸，導致畫面固定在左下角且右上有黑邊。因此 A4 是有效的黑屏 workaround，但不是最終高 DPI 畫質方案。

A6-R1 證明 per-view deferral 能把失敗延後到 resize end：拖曳期間仍可看到舊 drawable 被 Cocoa 縮放，但比例與 client area 不一致，縮小時新露出區域保留殘影；放開滑鼠觸發 final backing commit 後才黑屏。這表示 main-thread barrier 雖改善了中間狀態，最終 `clearDrawable` / `setView` teardown/reattach 仍是直接故障點。A6-R2 應保留最終 DPI backing-size 更新，但在 deferred final commit 跳過 teardown/reattach，改用 in-place context update 驗證。

A6-R2 已驗證成功：拖曳放大、縮小與連續多次 resize 在放開後都會正確填滿視窗，沒有 A4 的 DPI 黑邊，也沒有 R1 的 resize-end 黑屏。這證明 `kCGLCPSurfaceBackingSize` 更新本身可用，直接故障點是 backing 尺寸改變後的 `clearDrawable` / `setView`。Alt+Enter 仍黑，因為它不會進入 Cocoa live-resize deferral，仍走原版 teardown/reattach；R3 應將已掛載 view 的 programmatic size transition 也標記為 in-place commit。

A6-R3 已把 in-place commit 擴展到 context 維持同一 view 的所有 backing resize。實測拖曳、連續縮放、Alt+Enter 進出與最小化／還原後的遊戲畫面都正確滿版，表示 BlueCG 的 GL backing 問題已得到一致修復。剩餘問題是每次 deminiaturize 後外層視窗都會變大；這屬於 restore geometry round-trip，而非 drawable/backing 黑屏。優先檢查 `windowDidDeminiaturize()` 無條件呼叫 `windowDidResize()`，是否與 `WINDOW_DID_UNMINIMIZE` → `SC_RESTORE` 同時回寫尺寸而重複套用 DPI／non-client 換算。

A6-R4 在 Cocoa delegate 端略過未變 frame 的 `windowDidResize()` 後，還原仍固定放大約 2 倍，R3 顯示功能則維持正常。因此重複回寫不是主因；尺寸改寫發生在 `macdrv_ShowWindow()` 處理 `WINDOW_DID_UNMINIMIZE` 時。user32 的 `window_min_maximize()` 已提供正常 `newPos`，但 mac driver 又以 `macdrv_get_cocoa_window_frame()` 覆蓋；Retina 下該函式透過 `cgrect_win_from_mac()` 將 Cocoa point 乘 2，正好符合實測倍率。R5 應只允許真正 `WINDOW_FRAME_CHANGED` 覆蓋 rect，unminimize 則保留 user32 saved normal rect。

A6-R5 完整通過目前 BlueCG Retina+DPI 驗收：拖曳放大／縮小、連續 resize、Alt+Enter 進出、最小化／還原後的畫面皆正常滿版；重複最小化／還原時外層視窗尺寸也保持固定。結論是 same-view backing resize 應採 in-place CGL backing/context update，只有真正 view switch 才保留原版 attach/reset；restore geometry 則應以 user32 saved normal rect 為權威，不可在 `WINDOW_DID_UNMINIMIZE` 再以 Retina-converted Cocoa frame 覆蓋。

## A6 最終整併（無 R4 guard）

R4 的 `windowDidDeminiaturize()` frame guard 在 R4 實驗中沒有改善還原後尺寸逐次放大的問題；R5 改為保留 user32 的 saved restore rect 後，已獨立解決該問題。為避免保留未證實必要的 Cocoa callback 狀態，正式版本採用 R1、R2、R3、R5，移除 R4 guard。

正式 runtime 位於 `install/wine-experiments/a6-final-no-r4`，其 `winemac.so` SHA-256 為：

```text
814358c0b459b3e4b2735b604ba038dd166f72561e9425676b57f323d7aafbab
```

R1–R5 歷史 patch 仍保留以便 bisect 與回歸測試；後續乾淨 source build 請直接套用
`patches/a6-final-same-view-backing-sync.patch`，不要把 R4 patch 另行疊加。正式
engine artifact、版本標籤與封裝驗證見 [`bluecg-winemac-a6-engine.md`](bluecg-winemac-a6-engine.md)。

每個 runtime 都是獨立的 Wine install，大小約 1.1 GB。建議遊戲目錄與 Wine prefix 分離；本次使用 `BlueCrossgateNew/` 作遊戲目錄、`.wine/` 作 prefix。請勿同時啟動兩個實驗。

## 啟動前共通步驟

在專案根目錄執行：

```bash
cd /Users/jjc/ogom
source scripts/env-x86_64.sh

export PREFIX="$OGOM/.wine"
export GAME_DIR="$OGOM/BlueCrossgateNew"
export EXPERIMENT_LOG="$OGOM/logs/winemac-experiments"
mkdir -p "$EXPERIMENT_LOG"
```

若 `.wine` 尚未建立，先初始化一次：

```bash
RUNTIME="$OGOM/install/wine-experiments/a1"
WINEPREFIX="$PREFIX" \
  arch -x86_64 "$RUNTIME/bin/wine" wineboot.exe -u
```

每次切換 runtime 前先停止 wineserver：

```bash
WINEPREFIX="$PREFIX" \
  arch -x86_64 "$OGOM/install/wine-experiments/a1/bin/wineserver" -k || true
```

注意：上面使用的 `$WINE_INSTALL` 是主要 CX26 install，只為找到 wineserver。若該路徑不存在，改用待測 runtime 的 `bin/wineserver`。

固定 RetinaMode 為關閉，先只測非 Retina 單一變因：

```bash
WINEPREFIX="$PREFIX" \
  arch -x86_64 "$OGOM/install/wine-experiments/a1/bin/wine" \
  reg add 'HKCU\\Software\\Wine\\Mac Driver' \
  /v RetinaMode /t REG_SZ /d n /f
```

查詢設定：

```bash
WINEPREFIX="$PREFIX" \
  arch -x86_64 "$OGOM/install/wine-experiments/a1/bin/wine" \
  reg query 'HKCU\\Software\\Wine\\Mac Driver' /v RetinaMode
```

## 各組啟動指令

### Baseline

```bash
RUNTIME="$OGOM/install/wine-experiments/baseline"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-b luecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/baseline.log" 2>&1
```

### A1

```bash
RUNTIME="$OGOM/install/wine-experiments/a1"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a1.log" 2>&1
```

### A2

```bash
RUNTIME="$OGOM/install/wine-experiments/a2"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a2.log" 2>&1
```

### A3

```bash
RUNTIME="$OGOM/install/wine-experiments/a3"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a3.log" 2>&1
```

### A4

```bash
RUNTIME="$OGOM/install/wine-experiments/a4"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a4.log" 2>&1
```

### A5

```bash
RUNTIME="$OGOM/install/wine-experiments/a5"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a5.log" 2>&1
```

### A6-R1

```bash
RUNTIME="$OGOM/install/wine-experiments/a6-r1"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a6-r1.log" 2>&1
```

A6-R1 patch 保存在 `patches/a6-r1-resize-end-backing-sync.patch`。它以原始 CX26
explicit backing path 為基礎；live resize 開始後對每個 `WineContentView` 延後
`wine_updateBackingSize()` / drawable reset，`WINDOW_RESIZE_ENDED` 在
`WM_EXITSIZEMOVE` 返回後以同步 `OnMainThread()` 等待最終 view frame，清除 backing
cache 並標記 context pending。下一次 frontbuffer flush 或 swap 會強制
`make_context_current()`，重新讀取最終 window-DPI client rect，只做一次 backing sync。

### A6-R2

```bash
RUNTIME="$OGOM/install/wine-experiments/a6-r2"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a6-r2.log" 2>&1
```

A6-R2 需先套用 R1 patch，再套用
`patches/a6-r2-in-place-final-backing.patch`。R2 只改 final pending commit：保留
`kCGLCPSurfaceBackingSize` 的最終 DPI 尺寸，直接提交 view backing cache 並呼叫
`NSOpenGLContext update`，不拆除或重新掛載 drawable。

### A6-R3

```bash
RUNTIME="$OGOM/install/wine-experiments/a6-r3"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a6-r3.log" 2>&1
```

A6-R3 依序套用 R1、R2、`patches/a6-r3-same-view-in-place-backing.patch`。
`macdrv_make_context_current()` 若確認目標 view 就是 context 現有 view，會允許 in-place
backing commit；若是 latent view、dummy view 或真正切換 view，仍走原版 attach/reset，
避免破壞 context 初次掛載與 view ownership。

### A6-R4

```bash
RUNTIME="$OGOM/install/wine-experiments/a6-r4"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a6-r4.log" 2>&1
```

A6-R4 再套用 `patches/a6-r4-deminimize-frame-guard.patch`。它不修改 R3 的 GL
backing 行為，只在 `windowWillMiniaturize` 保存 `wine_fractionalFrame`；
`windowDidDeminiaturize` 若 Cocoa frame 未實際變動，便只保留既有
`WINDOW_DID_UNMINIMIZE` / `SC_RESTORE`，不再額外把同一 frame 當 resize 回寫 Win32。

### A6-R5

```bash
RUNTIME="$OGOM/install/wine-experiments/a6-r5"
WINEPREFIX="$PREFIX" arch -x86_64 "$RUNTIME/bin/wineserver" -k || true
bash scripts/run-bluecg.sh \
  --prefix "$PREFIX" \
  --game-dir "$GAME_DIR" \
  --wine-install "$RUNTIME" \
  --ddraw-source official \
  --no-gecko-prompt \
  > "$EXPERIMENT_LOG/a6-r5.log" 2>&1
```

A6-R5 再套用 `patches/a6-r5-preserve-user32-restore-rect.patch`。
`macdrv_ShowWindow()` 只有在 `WINDOW_FRAME_CHANGED` 時才由 Cocoa 取回 geometry；
`WINDOW_DID_UNMINIMIZE` 保留 user32 已由 saved normal position 算出的 `newPos`，
避免 Retina `cgrect_win_from_mac()` 的 2× rect 被反覆提交為新的正常視窗尺寸。

`run-bluecg.sh` 預設啟動 `BlueLauncher.exe`，所以每組都應在 launcher 畫面點選第一個模式；不要使用 `--direct`，否則會跳過要測的 launcher 路徑。

## 每組人工測試流程

每組啟動後都使用完全相同的操作：

1. 點 BlueLauncher 的第一個模式。
2. 等待進入遊戲世界，確認 onscreen 畫面已出現。
3. 拖曳右下角放大。
4. 拖曳右下角縮小。
5. 重新啟動後進入遊戲，再測一次 Alt+Enter。
6. 最小化／還原。
7. 記錄是否黑屏、程式是否仍存活、縮放是否平滑。

建議每組建立一個結果檔：

```text
$EXPERIMENT_LOG/baseline-result.md
$EXPERIMENT_LOG/a1-result.md
$EXPERIMENT_LOG/a2-result.md
$EXPERIMENT_LOG/a3-result.md
```

最少記錄：

```markdown
- RetinaMode: n
- Drag after entering world: normal / black
- Alt+Enter after entering world: normal / black
- Minimize/restore: normal / black
- Process alive after black screen: yes / no
- Smooth scaling: yes / no
- Notes:
```

## 之後測 RetinaMode

只有非 Retina 四組結果完成後，才將同一 prefix 設為 `y`：

```bash
RUNTIME="$OGOM/install/wine-experiments/a1"
WINEPREFIX="$PREFIX" \
  arch -x86_64 "$RUNTIME/bin/wine" \
  reg add 'HKCU\\Software\\Wine\\Mac Driver' \
  /v RetinaMode /t REG_SZ /d y /f
```

依序重跑 A1、A2、A3。每次切換前停止 wineserver，避免舊 process 載入上一組 module。

## 結果判讀

| 結果 | 下一步 |
|------|--------|
| A1 非 Retina 正常，baseline 黑 | 強力支持 unconditional cache invalidation 是 CX26 回歸點 |
| A1 黑，A2 正常 | backing-size enable / reset 路徑是主要觸發點 |
| A1、A2 黑，A3 正常 | resize 時 `wine_setBackingSize({0,0})` 觸發 drawable rebuild 是主要嫌疑 |
| 四組都黑 | 轉做 async race、window-DPI rect 或 layer hierarchy trace |
| 只有 Retina 黑 | 保留非 Retina 修復，Retina 另列為第二個問題 |

## 驗證 runtime 是否正確

```bash
for name in baseline a1 a2 a3; do
  so="/Users/jjc/ogom/install/wine-experiments/$name/lib/wine/x86_64-unix/winemac.so"
  codesign --verify --strict "$so" && shasum -a 256 "$so"
done
```

目前 source tree 已恢復為 A1 狀態；主要 `install/wine-cx26-x86_64` 也仍是 A1。要回到原始 baseline，請使用本文件的 `baseline` runtime，不要覆蓋主要 install。若 prefix 被清除，先以 A1 runtime 執行 `wine wineboot.exe -u`，再設定 `RetinaMode=n`。
