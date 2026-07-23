# Cyder Runtime 與 Bottle 體積研究

更新：2026-07-21

## 結論

主要差異不是 CrossOver 有一組神祕的 `configure` 瘦身參數，而是 Cyder 的 release staging
沒有剝除 PE DLL/EXE 內的 DWARF debug sections。Wine 建立 prefix 時又會把這些 PE modules
複製到 `drive_c/windows/system32` 與 `syswow64`，所以同一份 debug data 同時膨脹 engine
與 bottle。

本機實測（`du -sk`，MiB 為約值）：

| 項目 | 原始 | Release strip 後 | 節省 |
|---|---:|---:|---:|
| Cyder engine（早期量測） | 1,031,820 KiB（約 1,008 MiB） | 406,020 KiB（約 396 MiB） | 約 61% |
| CX26.2 MapleStory build | 約 1.1 GiB | 約 404 MiB | 約 701 MiB |
| `wined3d.dll` x64 | 23,728,128 B | 3,297,280 B | 約 86% |
| zstd `-10` engine archive | 252 MiB | 81 MiB | 約 68% |

`llvm-strip --strip-debug` 後，`wined3d.dll` 仍保留 `.text`、`.pdata`、`.rsrc`、`.reloc`；
移除的是 `.debug_info`、`.debug_loc`、`.debug_str` 等 DWARF。這不是刪 DLL 或猜測未使用
模組，風險遠低於 PE pruning。

以該 stripped engine 建立完全隔離的新 prefix，`wineboot -u` 成功，停止 wineserver 後
prefix 為 466,960 KiB（約 456 MiB）；`system32`／`syswow64` 分別為
216,288／209,536 KiB。
因此 release strip 不只通過靜態格式檢查，也完成實際 Wine 初始化，而且新 bottle 已不再是
1.7 GiB 等級。

## Bottle 差異拆解

本機現況：

| Prefix | 總計 | `system32` | `syswow64` | Mono | Installer cache |
|---|---:|---:|---:|---:|---:|
| Cyder shared | 1,780,332 KiB | 629,284 KiB | 564,836 KiB | 236,740 KiB | 190,416 KiB |
| CrossOver `test` | 316,972 KiB | 140,888 KiB | 135,400 KiB | 無 | 很小 |

同一例子的 bottle copy：Cyder `system32/wined3d.dll` 是 23,728,128 B，CrossOver 版只有
1,425,472 B。這直接證明 Wine PE debug data 被複製進 prefix。

剩餘約 427 MiB 差異來自 Cyder Golden template 預裝 Wine Mono/Gecko 及 Windows Installer
cache。這是功能取捨：BlueLauncher 等 .NET 程式需要 Mono，但 MapleStory.exe 直接啟動
並不需要。Cyder profile backend 已支援 `pristine`（wineboot only）與 `golden`
（Mono/Gecko/tar）template；後續應在 MapleStory recipe／UI 預設選 pristine，而不是把共同
元件塞進每一種遊戲的 prefix。

同一個 stripped CX26.2 engine 的新 prefix，若不設
`WINEDLLOVERRIDES=mscoree,mshtml=`，wineboot 會從 Cyder downloads cache 自動安裝 Mono，
實測立即增至約 775 MiB（Mono 236,740 KiB，Installer 約 83,524 KiB）。設 override 的
pristine 對照組就是上述 466,960 KiB。這個 A/B 排除了 engine 差異，直接證明第二層膨脹
來自 bootstrap policy。

## 已實作的 release 改善

`scripts/strip-wine-install.sh` 現在會：

- 移除 headers、man pages、開發工具及 import libraries；
- 使用專案 llvm-mingw 的 `llvm-objdump` 只找出含 `.debug_*` 的 PE；
- 使用 `llvm-strip --strip-debug` 剝除這些檔案；
- 對已經 stripped 的 OEM engine 不重寫，避免無謂更動既有 signature；
- 可用 `CYDER_KEEP_DEBUG_SYMBOLS=1` 保留開發符號。

`pack-engine-artifact.sh` 的順序是 strip → bundle dylibs → sign → compress，所以 strip 不會
破壞最終簽章。不要對已發布且已簽章的 runtime 原地執行 strip。

## Configure 與 build 優化

- `--disable-tests`：能大幅減少 compile 時間與 build tree；runtime build 已預設啟用。
  它不是上述 600 MiB 安裝差距的主因，因為 regression tests 原本不會全數安裝。
- `--with-tests`：需要 upstream regression tests 時才明確開啟。
- `-g`：保留在編譯階段較好，讓 compile/link failure 與未封裝產物可診斷；release staging
  再 strip，兼顧開發與發行。
- `--without-*`：停用 GStreamer、Vulkan、printing 等子系統只能省較小空間，而且可能直接
  破壞遊戲。MapleStory 目前需要測試 Vulkan/wined3d 與 raw audio，不應為縮小而關閉。
- MapleStory 需要的最小 GLib/GStreamer install 只有約 16 MiB；`build-media-stack.sh` 會
  停用 FFmpeg、GTK、WebRTC 與 plugin collections。這是依功能做 configure 削減的合適
  範例，但它的量級遠小於剝除 PE DWARF 所省的約 700 MiB。

## 下一階段

1. 將既有 profile template flavor 接到 MapleStory recipe／UI；MapleStory 預設使用
   pristine，.NET launcher 才使用 golden。
2. 對 Mono/Gecko MSI cache 研究安裝後移除是否能安全 repair/uninstall；未驗證前不自動刪除。
3. 若仍需縮小，再以 module-load corpus 驗證 PE pruning；不能只憑檔名刪 DLL，因為
   BlackCipher/NGS 可能延遲載入平常測試沒看到的 Windows API modules。
