# MapleStory OEM25 圖形後端實測記錄

日期：2026-07-27
範圍：Cyder OEM25 source engine、WineD3D、DXVK、CrossOver GPTK/D3DMetal，以及 Metal Performance HUD。

## 結論

- OEM25 source engine 可以正常啟動 MapleStory，並以原生 DXVK 的 `d3d11.dll`/`dxgi.dll` 執行。
- MapleStory 在 DXVK 下可進入遊戲；實測體感比 WineD3D 流暢。DXVK 日誌顯示使用 MoltenVK 作為 Vulkan implementation。
- CrossOver 25 內附的 Apple GPTK 也可以透過 D3DMetal 啟動 MapleStory。單純設定 `WINED3DMETAL=1` 並不足以讓這份 source engine 載入 GPTK，因為 source engine 會優先找到自己的 builtin DLL；本次 A/B 測試以暫時替換 DLL 的方式確認可行性。
- 完整 Metal HUD 曾造成遊戲凍結；凍結堆疊落在 `libMTLHud.dylib` 的 `Overlay::onPresent`/`segv_handler`。改用只顯示 FPS 的精簡 HUD 後可穩定執行。
- DXVK 與 D3DMetal 的比較應使用相同的精簡 Metal HUD 設定，避免 HUD 本身成為變因。

## 測試輸入與環境

遊戲執行檔：

`/Users/jjc/ogs/MapleStory/MapleStory.exe`

OEM25 source engine：

`/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64`

相關輸入與工具：

- `build/maplestory-oem25`
- `tools/archives/FOSSCodeForMapleStoryPort.tar.gz`
- `tools/archives/crossover-sources-25.0.1.tar.gz`
- `tools/archives/llvm-mingw-20260616-ucrt-macos-universal.tar.xz`

測試參數中的登入伺服器、連接埠及 BeanFun 參數沿用使用者提供的值；一次性 OTP 不寫入文件，也不應提交到版本庫。

OEM25 source Wine 必須明確指定 loader：

```sh
export WINELOADER=/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64/bin/wine
export WINESERVER=/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64/bin/wineserver
```

不指定 `WINELOADER` 時，這個 CrossOver source-derived engine 可能卡在 `init_paths`；指定後 `wine --version` 為 `wine-10.0`。

## DXVK 建置與安裝

`FOSSCodeForMapleStoryPort.tar.gz` 不含 DXVK；實際使用 `crossover-sources-25.0.1.tar.gz` 中的 CrossOver DXVK source snapshot。建置腳本為：

```sh
bash scripts/build-dxvk.sh \
  --engine install/wine-maplestory-oem25-source-x86_64
```

目前只建置 64-bit 與 32-bit 的 D3D11/DXGI：

```text
lib/dxvk/x86_64-windows/d3d11.dll
lib/dxvk/x86_64-windows/dxgi.dll
lib/dxvk/i386-windows/d3d11.dll
lib/dxvk/i386-windows/dxgi.dll
```

D3D9/D3D10 未納入這次 payload，原因是舊版 DXVK source 與目前 LLVM-MinGW headers 有相容性錯誤；MapleStory 測試只需要 D3D11/DXGI。

Prefix 安裝器：

```sh
bash scripts/install-dxvk-prefix.sh \
  --engine install/wine-maplestory-oem25-source-x86_64 \
  --prefix /path/to/prefix
```

安裝器會把 native DLL 原子化放入 prefix 的 `system32`/`syswow64`，並保存 `.cyder-runtime/dxvk-payload`。只設定 `WINEDLLPATH` 不足以覆蓋 source Wine 內建 DLL 搜尋順序；native PE 必須位於 prefix 或實際 exe 的可搜尋位置，並搭配 `WINEDLLOVERRIDES`。

## DXVK 端到端驗證

隔離 prefix 中使用：

```sh
export WINEDLLOVERRIDES='d3d11,dxgi=n,b'
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8
export DXVK_LOG_LEVEL=info
```

D3D11 probe 與 MapleStory 都觀察到：

- `d3d11.dll`、`dxgi.dll` 由 prefix native DLL 載入。
- DXVK 日誌：`Game: MapleStory.exe`、`DXVK: v0.7.0+`。
- Vulkan implementation 為 MoltenVK；probe 的 `D3D11CreateDevice` 回傳成功，feature level 為 `0xb000`。
- MapleStory 能啟動 BlackCipher/NGService，並建立 1366x768 swapchain。

MapleStory 的子程序仍可能載入 Wine builtin `wined3d.dll`；判斷主遊戲後端時應以主程序的 native `d3d11`/`dxgi`、DXVK log 及動態函式庫清單為準，不要只看整棵 process tree。

## D3DMetal/GPTK 驗證

CrossOver payload 位於：

`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk`

重要元件：

```text
external/libd3dshared.dylib
external/D3DMetal.framework/Versions/A/D3DMetal
wine/x86_64-windows/d3d11.dll
wine/x86_64-windows/d3d12.dll
wine/x86_64-windows/dxgi.dll
wine/x86_64-unix/d3d11.so -> ../../external/libd3dshared.dylib
wine/x86_64-unix/dxgi.so  -> ../../external/libd3dshared.dylib
```

測試時加入：

```sh
export WINEDLLOVERRIDES='d3d11,dxgi=b'
export WINED3DMETAL=1
export WINEDXVK=0
export CX_APPLEGPTK_LIBD3DSHARED_PATH=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib
```

source Wine 日誌出現 `Loaded libd3dshared.dylib`；`lsof` 可看到 `D3DMetal.framework`、`libd3dshared.dylib`、GPTK 的 `d3d11.dll`/`dxgi.dll`。D3D11 probe 與 MapleStory 均可建立 device，證實 GPTK 路徑可運作。

這次是暫時性的 A/B 測試：原本的 engine DLL 備份在：

`/private/tmp/cyder-oem25-d3dmetal-backup-20260727/x86_64-windows/`

正式整合前必須恢復原始 engine DLL，或改成受控的 runtime DLL search-path/CompatDB 動作；不應把 CrossOver 私有 GPTK payload 直接併入可發布的 Cyder Engine。

## Metal HUD 與凍結診斷

Apple 文件列出的 HUD 設定包括 `MTL_HUD_ENABLED`、`MTL_HUD_ELEMENTS`、`MTL_HUD_ALIGNMENT`、`MTL_HUD_SCALE`、`MTL_HUD_OPACITY` 等：

- [Customizing Metal Performance HUD](https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud)
- [Monitoring Metal app graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance?changes=_8)
- [Understanding Metal HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics?language=objc)

完整 HUD（只設 `MTL_HUD_ENABLED=1`）的 freeze sample 顯示主執行緒在 D3DMetal `Present1` 等待，而 Metal completion queue 進入 `libMTLHud.dylib` 的 `Overlay::onPresent`，之後經 `_CADeveloperHUDProperties`/`segv_handler` 反覆出錯。因此目前將 HUD 限縮為 FPS：

```sh
export MTL_HUD_ENABLED=1
export MTL_HUD_ELEMENTS=fps
export MTL_HUD_ALIGNMENT=topleft
export MTL_HUD_SCALE=0.12
export MTL_HUD_OPACITY=0.85
export MTL_HUD_DISABLE_MENU_BAR=1
export MTL_HUD_INSIGHTS_ENABLED=0
export MTL_HUD_ENCODER_TIMING_ENABLED=0
```

這組設定在 D3DMetal 測試中可穩定顯示 FPS；同一組設定也已套用於目前的 DXVK 比較。若要看 DXVK 自身 HUD，可另用 `DXVK_HUD=fps,frametimes`，但與 Metal HUD 的 1% low 顯示方式不同，不宜直接混比。

## 可重現的後端切換範例

### DXVK

先以 `scripts/install-dxvk-prefix.sh` 安裝 prefix，再啟動：

```sh
WINEDLLOVERRIDES='d3d11,dxgi=n,b' \
WINED3DMETAL=0 WINEDXVK=1 \
LANG=zh_TW.UTF-8 LC_ALL=zh_TW.UTF-8 LC_CTYPE=zh_TW.UTF-8 \
MTL_HUD_ENABLED=1 MTL_HUD_ELEMENTS=fps MTL_HUD_ALIGNMENT=topleft \
MTL_HUD_SCALE=0.12 MTL_HUD_OPACITY=0.85 MTL_HUD_DISABLE_MENU_BAR=1 \
WINELOADER=/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64/bin/wine \
WINESERVER=/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64/bin/wineserver \
/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64/bin/wine \
  /Users/jjc/ogs/MapleStory/MapleStory.exe <server> <port> <provider> <otp> <timestamp>
```

### D3DMetal

除了上述 loader、locale 與精簡 HUD 設定，需使用 GPTK DLL overlay 並加入：

```sh
WINEDLLOVERRIDES='d3d11,dxgi=b' \
WINED3DMETAL=1 WINEDXVK=0 \
CX_APPLEGPTK_LIBD3DSHARED_PATH=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib
```

## 驗證與限制

已通過的相關測試包括：

```text
bash tests/test-cyder-dxvk.sh
bash tests/test-cyder-app-payload.sh
bash tests/test-cyder-compatdb-data.sh
bash tests/test-build-wine.sh
```

目前限制：

1. source install 沒有 CrossOver 的 `cxcompatdb.so`，所以不能直接期待 OEM 的 graphics-backend 設定自動注入 D3DMetal。
2. DXVK snapshot 較舊，這次只驗證 D3D11/DXGI；其他 Direct3D 版本尚未處理。
3. D3DMetal 使用的是本機 CrossOver payload，尚未完成可再散布的授權與版本配對方案。
4. Metal HUD 的完整元素集合在此組合下可能凍結；正式功能應以精簡、可關閉的 HUD 選項為預設。
5. 登入需要新的 OTP；重現測試時請自行提供當次有效值，不要把 OTP 寫入 log、文件或 commit。

後續正式產品化方向是把 `graphics_backend` 規則接到 runtime 層：DXVK 由 prefix installer 管理，D3DMetal 僅在使用者已有相容 GPTK payload 且明確啟用時設定 DLL search path，並保留可匯出/恢復的規則設定。
