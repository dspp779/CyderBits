# MapleStoryPort 25.0.1 與 CrossOver 26.2 移植研究

更新：2026-07-23

## 結論

MapleStoryPort 並不是「普通 CrossOver 25 加一個 bottle」。比對 CodeWeavers 提供的
`FOSSCodeForMapleStoryPort.tar.gz` 與 `crossover-sources-25.0.1.tar.gz` 後，Wine tree 有
145 個差異項目（139 個既有檔案不同、6 個 port-only 檔案）。其中有多組明確標示
MapleStory bug number 的原始碼修正。

目前已把最接近台版黑畫面路徑、且能安全對應 CX26.2 架構的第一層修正整理為
[`patches/maplestory-cx26-core.patch`](../../../patches/maplestory-cx26-core.patch)：

- `winemac.drv`：辨識 `MapleStoryClass`，只對遊戲主視窗關閉 resize 與 macOS
  live-resize/drag loop。OEM 原碼有一處全域停用，移植版將影響範圍縮到 MapleStory。
- `wined3d`：user-memory／format-conversion texture 固定在 system memory，Vulkan backend
  對需要 upload conversion 的 texture 建立 staging resource。這一組最可能直接影響
  「有視窗、遊戲鼠標正常、但內容全黑」。
- `winegstreamer`：加入 OEM 的 `rawaudioparse` element；只有
  `RAW_AUDIO_PARSE=1` 時才插入 pipeline，不改變其他遊戲的預設行為。

Patch 已對乾淨的 CrossOver 26.2 Wine source 執行 `patch --dry-run`，可乾淨套用；
`build-wine.sh --maplestory-port` 也會偵測已套用狀態，避免重複套 patch。

## 可重現資料來源

本研究只使用專案內的 source offer：

```text
tools/archives/FOSSCodeForMapleStoryPort.tar.gz
tools/archives/crossover-sources-25.0.1.tar.gz
tools/archives/crossover-sources-26.2.0.tar.gz
```

前兩份用來還原 OEM 25.0.1 相對 retail 25.0.1 的差異；最後一份是移植目標。這比從
runtime 字串反推可靠，因為可看到條件、作用範圍與 bug 註解。

### 整份 source offer 的拓撲

不只 Wine，OEM offer 的頂層內容也不同：

- OEM-only：`SDL2`、`libffi`、`pcre2`、`python`、`xml`；
- retail-only：`android`、`busybox`、`cabextract`、`dxvk`、`flatpak`、`ghostscript`、
  `htmltextview`、`pyxdg`、`samba3`；
- 共同：`freetype`、`glib`、`gnutls`、`gstreamer`、`makedep`、`moltenvk`、`po4a`、
  `vkd3d`、`wine`。

共同元件逐樹比對後，`freetype/glib/gnutls/gstreamer/makedep/po4a/vkd3d` 完全相同；真正的
OEM compatibility 修改集中在 Wine。MoltenVK 表面有 769 個差異項目，但 768 個來自
SPIRV-Cross snapshot 的測試／reference corpus；MoltenVK core 只有 `MVKDevice.mm` 一處
macOS 26 + AMD concurrent compilation crash guard。該 guard 已原封不動存在 CX26.2 source，
因此不需要另做 MapleStory MoltenVK patch，Apple GPU 也不會走這個 AMD 條件。

## OEM 修改分群

| 區域 | OEM 行為 | 與台版的關聯 | CX26 狀態 |
|---|---|---:|---|
| `winemac.drv/window.c` | MapleStory 主視窗不可 resize；避開 Cocoa sizing loop | 高 | 第一層已移植，並縮小為遊戲專用 |
| `wined3d/texture*.c` | user memory、converted format、Vulkan staging/location 修正 | 很高 | 第一層已移植 |
| `winegstreamer` | 新增 raw audio parser，受 `RAW_AUDIO_PARSE=1` 控制 | 高 | 第一層已移植 |
| `win32u` | restore 後短時間忽略特定 fullscreen→windowed style change；MapleStory edit shortcut | 中 | 待第二層；需連同新增 state 欄位移植 |
| `kernelbase` | 追蹤 CopyFile/LoadLibrary 原始名稱，處理 `.dll`→`.tmp` 模組 | 中至高 | 待第二層；可能和 BlackCipher 載入路徑有關，需獨立 A/B |
| `dbghelp` | OEM binary 含 `MAPLESTORY_ENABLE_DBGHELP`，疑似略過部分 symbol initialization | 中 | 已補通用且較窄的 DWARF 除零防護；不全域停用 `SymInitialize` |
| `ntdll/env.c` | MapleStory 啟動時過濾部分 `WINEDEBUG` | 除錯負面 | 不移植；Cyder 應保留可觀察性 |
| `ntdll/unix/file.c` | 8 KiB user-space file cache，改善大量小檔讀取 | 效能 | 暫緩；侵入性大，先量測再決定 |
| `ntdll/sync.c` | 避免 `sched_yield` | 效能 | 暫緩；需壓力測試其他遊戲 |
| `mountmgr`／`ntdll` | 使用 APFS available-important-capacity 回報磁碟空間 | 低 | 暫緩；不是黑畫面必要條件 |
| `shell32/shlexec.c` | 寫 `.ms-launch-args` 並呼叫北美 signed helper | NA 專用 | 不移植；台版由 Beanfun OTP 直接 argv 啟動 |
| `winemac.drv/cocoa_app.m` | menu／BlackXchg foreground 特例 | 中 | 待第二層獨立驗證 |

「沒有移植」不等於判定無用，而是先確保每一層都能單獨回答：究竟是哪一組改動讓
CX26 從黑畫面進展。一次搬完會得到可玩或不可玩的結果，卻無法找出必要條件，也較容易
把 OEM 25 的舊 workaround 帶進 Wine 11/CX26。

## 建置

```sh
bash scripts/build-media-stack.sh --cx 26 --install-deps

bash scripts/build-wine.sh \
  --cx 26 \
  --maplestory-port \
  --install-deps \
  --with-vulkan \
  --vulkan-source crossover
```

第一行只建 GLib 與 GStreamer core/base libraries（約 16 MiB install），明確停用 GTK、
FFmpeg/libav、good/bad/ugly plugins、WebRTC、Python binding、文件與測試。不要改成安裝
Homebrew `gstreamer` meta-package；那會拉進與 Wine raw audio 無關的大量 GUI／多媒體相依。

Runtime build 現在預設傳入 `--disable-tests`，不浪費時間建立 Wine regression-test EXE；
這不會移除 runtime DLL。若要做 Wine upstream tests，明確加入 `--with-tests`。

`--maplestory-port` 會強制檢查 x86_64 `gstreamer-1.0`、`gstreamer-base-1.0` 與
`gstreamer-audio-1.0`。若 configure 顯示「GStreamer won't be supported」，raw audio patch
實際上不會進入 `winegstreamer.so`，不能把這種 build 當成完整的第一層測試引擎。

`bundle-wine-dylibs.sh` 會從 `winegstreamer.so` 的實際 Mach-O dependencies 遞迴收集媒體
libraries，改成 `@loader_path`。GLib proxy-libintl 與 Homebrew gettext 都叫
`libintl.8.dylib`、但提供不同 namespace；bundle 會保留前者為 canonical 名稱，將後者改名
為 `libintl-gettext.8.dylib` 給 GnuTLS 使用。若只按 basename 去重，會分別造成
`_g_libintl_*` 或 `_libintl_*` missing symbol。

## 2026-07-21 CX26.2 實測結果

- 完整 build/install 成功，產物是 Wine 11.0 / CrossOver 26.2 Wine tree。
- `winegstreamer.so` 包含 `RAW_AUDIO_PARSE` 與 `rawaudioparse`，所有媒體 dylib 均為
  relocatable `@loader_path`。
- stripped engine 約 404 MiB；全新隔離 prefix 執行 `wineboot -u` 成功，log 中
  `winegstreamer.dll` 的 Unix side 可載入，無 missing symbol／build-tree rpath。
- 直接從 Documents（Wine `Z:`）啟動台版 `MapleStory.exe`，不需要把遊戲複製進
  `drive_c`。無 OTP 測試約 23 秒依預期離開；期間 log 確認主程式、
  `BlackCipher64.aes`／`BlackCall64.aes` 與 Vulkan renderer 都進入生命週期。
- 修正 libintl 分流後重測，沒有 `Failed to load libgnutls`、
  `get_builtin_unix_funcs failed` 或 `Symbol not found`。

這證明 CX26 第一層 port 已越過「可編譯」並進入台版 EXE／防作弊／renderer 的實際啟動
路徑；因測試刻意不使用有效 OTP，不能據此宣稱遊戲內畫面已通過。完整可玩性仍需下一次
有效 OTP 人工確認。

## 2026-07-21 D3D11 啟動即退出：MoltenVK 來源覆寫

有效 OTP 測試曾出現更新檢查與 Nexon Overlay 後，主遊戲視窗尚未出現就安靜退出。完整
Wine trace 顯示 OTP argv、繁中 code page、`RAW_AUDIO_PARSE=1` 與 BlackCipher 啟動均成功；
真正的結束點是 `D3D11CreateDevice`：

```text
None of the requested D3D feature levels is supported on this GPU
with the current shader backend.
```

其後的 `CrashReportClient.exe` 是遊戲對圖形初始化例外的回報程序，不是 BlackCipher 主動
拒絕登入。獨立 D3D11 探針確認當時封裝的 engine 最高只能建立 feature level `9_3`，而
楓之谷要求的 `10_x/11_x` 全部失敗。

根因是 `bundle-wine-dylibs.sh` 在 `--vulkan-source crossover` build 完成後，仍優先尋找
Homebrew MoltenVK，因而把選定的 CrossOver renderer 靜默覆寫。兩個 library 在同一台
Apple M4 上透過 Wine Vulkan API 的差異如下：

| Vulkan capability | 被誤包入的通用／Homebrew build | CrossOver 26.2 retail build |
|---|---:|---:|
| `geometryShader` | 0 | 1 |
| `pipelineStatisticsQuery` | 0 | 1 |
| `shaderCullDistance` | 0 | 1 |
| Wine D3D feature level 上限 | 9_3 | 11_1 |

只替換 `libMoltenVK.dylib`，不更動 Wine、bottle 或遊戲檔案，探針立即從 `9_3` 恢復為
`11_1`；無 OTP 的完整 App 測試也讓 `MapleStory.exe`、`BlackCipher64.aes` 及 Nexon
Overlay GPU/network 子程序持續存活，且不再產生 `CrashReportClient.exe`。這是可重現的
單變數 A/B，足以排除登入與 bottle 為這次退出的原因。

打包流程現在依 `VULKAN_SOURCE` 固定候選順序：

- `crossover`：只優先取 `GRAPHICS_INSTALL` 的 CrossOver build，不容許 Homebrew 蓋掉；
- `homebrew`：明確要求時才優先使用 Homebrew；
- `existing`：重新封裝已測試 engine 時，優先保留 engine 內原有 renderer。

`build-graphics-stack.sh` 也要求 `source crossover-foss` manifest；只有 dylib、沒有來源
manifest 的舊目錄不再被當成完成。修正版 artifact 使用新 engine identity
`wine crossover 26.2.0-maplestory1 (wine 11.0)`，確保已安裝舊版的機器會重裝，而不是因
Wine 主版本相同沿用壞檔。這個特殊測試 artifact 目前以已安裝 CrossOver 26.2 的 retail
MoltenVK 作為已驗證基準；正式可重現發布仍應從 source offer 建出相同 capability，並以
D3D11 探針作為發布 gate。

## 2026-07-22 CX26 黑畫面：目前狀態與 D3D11 共享 texture 調查

### 已確認的 A/B 結果

| 引擎／renderer／bottle | 結果 | 可下的結論 |
|---|---|---|
| 完整 MapleStoryPort OEM25 engine + OEM bottle | 可見登入與遊戲畫面，可實玩 | OEM 組合確實可滿足台版的 renderer 與 BlackCipher 啟動需求 |
| CX26 移植 engine + OEM bottle + 通用/Homebrew MoltenVK | 更新／Overlay 後退出，曾出現 `CrashReportClient.exe` | renderer capability 不足，不能用於台版 |
| CX26 移植 engine + OEM bottle + CrossOver retail MoltenVK | 視窗存在、遊戲游標生效，但持續黑畫面 | MoltenVK 修正了 D3D device 建立，尚未修正畫面交接 |
| CX26 移植 engine + OEM bottle + 初版 `ClearView` 實作 | 畫面曾短暫閃現，之後仍黑 | 與 OEM25 啟動時先閃一下的現象一致，證明方向正確；初版不是完整 clear port |

目前不能把 `maplestory1` artifact 當成可發布引擎；它只證明 CX26 已能越過先前的
feature-level 崩潰並運行到顯示階段。已安裝 runtime 目前保留可用的 OEM25 baseline，避免
測試 DLL 影響正常遊玩。

### 關鍵線索：DwarfAxe 的共享畫面路徑

OEM25 的工作過程會啟動 DwarfAxe，且帶有 in-process GPU 選項；CX26 直接啟動則可看到
獨立 GPU process。CX26 的 `d3d11.dll` trace 重複出現：

```text
fixme:d3d11:d3d11_device_context_ClearView ... stub!
```

OEM source 對 `ID3D11DeviceContext::ClearView` 有實作，而 CX26 upstream source 為 stub。
移植最小版本後產生一次畫面閃動，佐證此呼叫是實際渲染路徑的一部分。

更明確的差異是 OEM `ID3D11Device::OpenSharedResource`：它只處理
`IID_ID3D11Texture2D`，以 `winekmt_<handle>` 開啟 file mapping，讀取 DwarfAxe 寫入的
`width`／`height`，建立 `DXGI_FORMAT_B8G8R8A8_UNORM` shared texture，然後以
`wined3d_texture_update_desc()` 將 texture 指到 mapping 的像素資料。CX26 原始碼在同一 API
直接回傳 `E_NOTIMPL`。

這是目前最強的黑畫面候選根因：視窗與 D3D device 正常，但 DwarfAxe 交付的 frame texture
沒有被 CX26 取入。2026-07-22 已將此 OEM 行為依 CX26 的 `ID3D11Device5`／新
`wined3d_texture_update_desc()` 介面移植成測試 DLL，連同最小 `ClearView` 放入隔離的測試
engine；尚未完成登入後人工畫面驗證。它已保存為獨立的
[`maplestory-cx26-d3d11-shared-texture-test.patch`](../../../patches/maplestory-cx26-d3d11-shared-texture-test.patch)，
可用 `build-wine.sh --maplestory-shared-texture-test` 重現；它不是正式 core patch，未重打
artifact，也未宣稱成功。

### 2026-07-22 實驗 patch 可重現性

- 實驗 patch 已對乾淨的 CrossOver 26.2 source，在 core patch 後執行 dry-run 成功。
- 本機 `dlls/d3d11` x86_64 DLL 含 `Imported shared texture` 與 `ClearView` 路徑字串，表示
  該 source 版本已編譯；目前刻意沒有 `make install` 或覆寫 Cyder 使用中的 engine。
- 2026-07-22 已加入 OEM shared-resource flush 後的 command-stream `finish` 同步，並重新編譯
  x86_64／i386 `wined3d.dll` 成功。這只補同步，不代表完整 rect/UAV clear 已完成。
- 已在 `dist/cx26-maplestoryport-test/wine-x86_64` 建立隔離測試 engine，含 x86_64／i386
  測試版 `d3d11.dll` 與 `wined3d.dll`；沒有覆寫 `install/wine-cx26-x86_64`。其 MoltenVK
  SHA-256 與已驗證的 CrossOver 26.2 retail renderer 相同。以全新暫存 prefix 執行 D3D11
  探針，feature level `11_1`、`11_0`、`10_1`、`10_0` 皆建立成功。
- 自動驗證只涵蓋 patch 套用順序與 build-script 選項。這不能取代實際登入後的人工畫面
  確認，亦不能證明 mapping 的 framebuffer 已正確 present。
- 已完成第二份 [`maplestory-cx26-d3d11-full-clear.patch`](../../../patches/maplestory-cx26-d3d11-full-clear.patch)：
  rect array 會一次通過 command stream；UAV packet、GL/Vulkan backend、Vulkan offset/extent
  push constants 與 clear 後 compute-state invalidation 均已移植。CX26 的 shader backend ABI
  保持不變；pipeline-layout cache key 會先清零，且比較 push-constant range，修正 OEM25
  只比較 descriptor bindings 的碰撞風險。
- full-clear patch 已在 shared-texture patch 後正向與反向 dry-run，x86_64／i386 的
  `wined3d.dll`、`d3d11.dll` 均編譯成功；更新後隔離引擎的 D3D11 探針由 feature level
  `11_1` 到 `9_1` 全數建立成功。
- 另以 8×8 `R32G32B32A32_FLOAT` UAV 做像素讀回測試：先清整張為零，再由
  `ID3D11DeviceContext1::ClearView` 只清 `(2,3)-(6,7)`；矩形內四個 channel 與指定值一致，
  外部像素維持為零。這實際通過 D3D11 entry、rect command packet、Vulkan clear shader、
  push constants、dispatch 與 readback，不只是符號或編譯檢查。
- 使用假帳號／OTP 的 Cyder prefix 測試在進入 DwarfAxe shared-texture 路徑前發生遊戲端
  division-by-zero；進一步以載入位址與 debug symbol 定位到 CX26 `DBGHELP.DLL` 的
  `dwarf.c:compute_location()`，不是遊戲或 D3D11。`DW_OP_div` 的 divisor 為零，未修補時在
  `dbghelp.dll+0xf177` 引發 `EXCEPTION_INT_DIVIDE_BY_ZERO`。
- 已加入 [`maplestory-cx26-dbghelp-dwarf-guard.patch`](../../../patches/maplestory-cx26-dbghelp-dwarf-guard.patch)，
  遇到非法 DWARF division／modulo by zero 時回報該 debug location 不可用，而不是令整個
  遊戲崩潰。x86_64／i386 `dbghelp.dll` 編譯成功；使用相同假 OTP 重跑後不再出現除零或
  Windows debugger 錯誤視窗。此修正比 OEM 疑似全域略過 `SymInitialize` 更小且不影響正常
  symbol initialization。

### 完整 ClearView 配套

初版實驗 DLL 的 render-target／depth-stencil rect 曾逐一呼叫 CX26 single-rect API，UAV 遇到
rect 時也曾退化為整個 view clear。因此先前「閃一下」只能證明 `ClearView` 進入正確路徑，
不能視為完整修補。下列 OEM25 配套現在已移植到獨立 full-clear patch：

1. 將 render-target rect array 一次傳入 WineD3D command stream；
2. 在 UAV clear command packet 保存 `rect_count` 與 rect array；
3. GL／Vulkan adapter 與 view backend 只 clear 指定區域；
4. Vulkan clear pipeline 以 offset／extent 更新 dispatch constants，並在完成後使 compute state
   失效；
5. shared-resource flush 強制等待 command stream 完成。

逐檔比較 OEM25 與 retail 25 後，這組變更集中在 `d3d11/device.c` 與 WineD3D 的
`adapter_{gl,vk}.c`、`context_vk.c`、`cs.c`、`device.c`、`directx.c`、`view.c`、公開／內部
headers 及 export spec。將 OEM patch 試套乾淨 CX26.2 時，相關變更絕大多數可直接對位；
手動處理了 CX26 已升級為 `ID3D11DeviceContext4` 的 `ClearView`、Vulkan header 宣告位置與
shader compiler 介面差異；pipeline-layout cache key 也已補上 push-constant range 初始化與
比較，避免取得錯誤的 cached layout。尚未完成的是有效 OTP 後的人工畫面驗證，不是來源移植。

### 已排除與尚待驗證

- **不是遊戲一定要在 `drive_c`：** 相同台版檔案可從 Documents 的 Wine `Z:` 進入
  MapleStory／BlackCipher／renderer lifecycle；OEM bottle 與 CX26 bottle 的交換亦未改變黑畫面
  結論。
- **不是 OTP／帳號參數造成 renderer 黑畫面：** 有效登入流程可以令遊戲繼續執行；圖形問題
  出現在登入後的 renderer path。OTP 僅用於最終完整驗收，不應記錄在 source、patch 或 log。
- **不是單純 CSMT／MSync 開關：** 工作與黑畫面 A/B 都使用相同 OEM bottle 與啟動環境，差異
  落在 engine／renderer 實作。
- **尚待驗證：** DwarfAxe 專用 `OpenSharedResource` 尚未做登入後人工畫面測試；即使它成功
  import texture，完整 rect/UAV/state clear 仍是本輪既定移植範圍，不再以「仍黑才做」為
  前提。完成前不擴大到 `win32u`、`kernelbase` 或 anti-cheat workaround。

### 後續工作規則

1. 每次僅換一組 DLL／patch，使用相同 OEM bottle、相同遊戲目錄與相同 CrossOver MoltenVK。
2. 每輪保留 `WINEDEBUG=+d3d11` 的 session log，至少比對 `ClearView`、
   `OpenSharedResource`、DwarfAxe 與 `CrashReportClient.exe`。
3. 必須人工確認登入畫面或地圖實際有畫面，才將實驗 patch 提升為正式可重現 patch 並重打 artifact。
4. 最終驗收沿用既定標準：有效 OTP 後進入角色／地圖並連續遊玩至少 20 分鐘，同時確認
   `BlackCipher` 持續存活且不影響畫面。

## 驗證層級

1. **來源驗證**：patch 對乾淨 CX26.2 source dry-run 成功。
2. **編譯驗證**：已確認 `winemac`、`wined3d`、`winegstreamer` 產物包含移植符號／字串。
3. **prefix smoke test**：以獨立 prefix 跑 `wineboot` 與簡單 Windows process，不覆寫使用者
   正在使用的 Cyder/OEM bottle。
4. **MapleStory lifecycle test**：以台版 EXE 啟動，從 log 確認
   `MapleStory.exe`、BlackCipher/NGS、D3D device、音訊 parser 與視窗生命週期。沒有新 OTP
   時只能驗證登入畫面前的路徑，不能把「未登錄帳號」當 renderer 失敗。
5. **實玩驗收**：最終仍需有效 ServiceAccountID/OTP，至少進入角色／地圖並運行 20 分鐘。

### 判讀限制

Wine 是 Rosetta 下的非原生程序，現有自動截圖工具無法可靠看見它的 surface。因此自動
測試以 debug log、process lifetime、module load 與正常/異常結束為證據；「有建立視窗」
不能單獨證明畫面不是黑的。最後一級必須人工看畫面。

## 後續 A/B 順序

**CX25 reverse bisect（無 OTP + OTP／進世界）已完成**（詳見
[OEM CX25 修補總覽 §11](oem-cx25-maplestory-patches.md#11-對-cx26-移植的建議分層) 與
[`patches/oem25-bisect/README.md`](../../../patches/oem25-bisect/README.md)）。

### 進世界必要集合（forward-port 契約）

1. OEM binary MoltenVK（勿默默換成 CX26 FOSS）
2. dbghelp DWARF guard（`maplestory-cx26-dbghelp-dwarf-guard.patch`）
3. kernelbase `.tmp`／`.msf`（`maplestory-cx26-tmp-module-name.patch`）
4. **整包 G 核心**：shared-texture + full-clear patches（ClearView／OpenShared／state；勿拆）
5. 啟動路徑：`C:\MapleTest`（自行編譯引擎）

建置：

```bash
bash scripts/build-wine.sh --cx 26 --maplestory-shared-texture-test \
  --with-vulkan --vulkan-source crossover
# 每次 bundle／install 後重掛 OEM libMoltenVK.dylib
```

無 OTP **非必要**：S、P file-cache／no-yield、W、rawaudioparse。  
OTP 證明 **G 對完整進世界畫面必要**（rev-G 可進但地圖／UI／滑鼠壞掉）。

**暫停**猜測性 DXGI producer／D3D9 mapping，除非進世界 trace 證明需要。

驗收：MapleTest + OTP → `jypc.dll` → 進世界 → 滑鼠／地圖／UI 完整。
