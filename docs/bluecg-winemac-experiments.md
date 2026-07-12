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

A2 是依目前 CX26 source tree 建立的 guard-only 版本。上游 !7979 的 window-DPI rect 改動未在 A2 回退，因為目前 source tree 的 `macdrv_context` 結構已與上游 patch diff 不同；不要把 A2 解讀為完整 MR !7979 revert。

## 已完成結果

| 實驗 | RetinaMode | 拖曳結果 |
|------|------------|----------|
| A1 | `n` | 黑屏 |
| A2 | `n` | **成功，仍有遊戲畫面** |
| A3 | `n` | 黑屏 |
| A2 | `y` | 黑屏 |

A2 已證實 guard-only backing-size 變更足以避開目前的非 Retina resize 黑屏；A3 黑屏則表示只略過 `wine_setBackingSize({0,0})` 不足以修復，關鍵較可能在 `wine_updateBackingSize()` / `resetSurfaceIfBackingSizeChanged()` 路徑。A2 + RetinaMode=`y` 再次黑屏，表示目前修復只適用非 Retina 路徑。

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
