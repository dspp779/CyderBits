# OEM CrossOver 25 楓之谷修補總覽

更新：2026-07-23

## 摘要

Nexon／CodeWeavers 的 MapleStoryPort OEM 不是單純的 CrossOver 25.0.1 加上一個預設
bottle。把專案內的 OEM source offer 與零售 CrossOver 25.0.1 逐檔比較後，可以確認它在
Wine、WineD3D、macOS driver、音訊、檔案 I/O 與官方啟動流程加入了一整組相容修補。

最重要的修補可簡化為五類：

1. **DwarfAxe 畫面交換**：補上 D3D11／DXGI shared texture，讓 DwarfAxe 與遊戲交換
   `winekmt_<handle>` BGRA 畫面。
2. **D3D11 clear 與 texture 狀態**：實作 `ClearView`、矩形 clear、UAV clear、Vulkan
   push constants、state invalidation，以及 user-memory／format-conversion texture 上傳。
3. **視窗與焦點**：固定楓之谷主視窗大小處理、fullscreen restore、Dwarf overlay 不搶
   activation、BlackXchg 不搶 macOS 前景。
4. **啟動與防作弊相容**：保留被複製成 `.tmp` 的 DLL 原始名稱，並提供北美官方 helper
   handoff。
5. **啟動效能與媒體**：小檔 userspace cache、display-mode cache、停用昂貴的 dbghelp
   symbol initialization，以及 raw PCM parser。

本輪與乾淨官方 CX26.2 source 比較後的結論是：

- 官方 CX26 **仍未補齊核心 MapleStory D3D 路徑**：`ClearView`、D3D11
  `OpenSharedResource`、DXGI `GetSharedHandle` 仍是 stub／`E_NOTIMPL`；OEM user-memory texture
  的特定條件也沒有被完整吸收。
- 本專案已可重現移植 D3D11 consumer、完整 clear、texture conversion、同步、核心 macdrv、
  raw audio、fullscreen、BlackXchg、`.tmp` module 與 no-yield；但實際遊戲仍曾停在黑畫面，
  所以「已移植」不等於「已證明必要或充分」。
- CX26 實際停在 **OpenSharedResource 之前**：約 9 次初始 Draw 後只剩 Present／ClearView
  迴圈，尚未載入 `jypc.dll`。繼續補 DXGI producer 或 D3D9 shared mapping 命中率很低。
- **CX25 reverse bisect（無 OTP + OTP／進世界）已完成（2026-07-23）**。見 §11。
- **無 OTP 必要集合**：OEM binary MoltenVK、OEM dbghelp、OEM kernelbase `.tmp`／`.msf`。
- **進世界必要集合**：上述三項 **加上整包 G**（ClearView／shared texture／相關 wined3d
  state；勿再拆 ClearView vs shared）。S／Pfc／W／Lgs 仍非必要。
- **啟動路徑**：自行編譯 OEM／CX26 source 請用 bottle 內 `C:\MapleTest`（APFS `cp -cR`
  clone）。Documents 經 `Z:` 在 source 上易觸發「遊戲檔案損毀」；預編譯 OEM binary 仍可走
  `Z:`／Documents（見成功基線）。
- 官方已吸收 capability SID、FAudio bounds、Vulkan presentation scaling 與 tearing；本專案
  不應重複維護這些舊 OEM hunks。
- 尚未移植的 DXGI producer 與 D3D9 named mapping 仍屬條件式 protocol completeness；進世界
  主線以整包 G + MoltenVK／dbghelp／kernelbase 為準。

其中 D3D shared texture、完整 clear、texture location/state handling 是一組配套，不能只搬
`ClearView` 的入口函式。CX26 初期只補最小 `ClearView` 時會「閃一下後黑」，正好說明入口
已走到，但後續資源交換與狀態同步仍不完整。

### 目前 CX25 source 隔離進度（2026-07-23）

| 引擎 | 狀態 |
|---|---|
| 預編譯 OEM 25.0.1.38865 binary | 已驗證可進入遊戲畫面（見成功基線）。無 OTP 可建 **1366×768** swapchain；`lib64/libMoltenVK.dylib`（hash `e8ccd129…`）是 source 畫面修復對照基準 |
| 自行編譯 OEM CX25 source | 引擎在 `install/`／`dist/wine-maplestory-oem25-source-x86_64`。**必須設 `WINELOADER`**（CW HACK 22144）。掛 OEM binary MoltenVK 後無 OTP 可進畫面；CX26 FOSS MoltenVK → feature-level 失敗。`bundle-wine-dylibs` 後須重掛 OEM `libMoltenVK.dylib` |
| reverse bisect 引擎 | 詳見 [`patches/oem25-bisect/README.md`](../../../patches/oem25-bisect/README.md)。最遠仍通過無 OTP 畫面者：`install/wine-maplestory-oem25-rev-G-x86_64`（已 reverse S／Pfc／W／Lgs／G，**保留** OEM dbghelp＋kernelbase `.msf`＋OEM MoltenVK） |
| 自行編譯 retail CX25.0.1 source | 對照建置路徑已就緒；本機另有可跑的 `install/wine-cx25-source-x86_64`（`wine-10.0`，不需 `WINELOADER`）可作暫代對照 |
| CX26 port | 既有 `--maplestory-shared-texture-test` 已含 G 核心（ClearView＋shared）、dbghelp DWARF guard、kernelbase `.msf`。下一步：掛 OEM MoltenVK、用 `C:\MapleTest`＋OTP 驗進世界畫面完整（見 §11.2） |

建置與 A/B 啟動：

```text
scripts/build-maplestory-oem25-source.sh
scripts/build-maplestory-retail25-source.sh   # 必須用 crossover-sources-25.0.1.tar.gz
scripts/run-maplestory-cx25-source-ab.sh --variant oem|retail
# OEM source 會自動 export WINELOADER=<wine_bin>
```

兩邊必須共用同一組 `GRAPHICS_INSTALL`／`MEDIA_INSTALL`，否則歸因會混入 MoltenVK／GStreamer
差異。`build-wine.sh --cx 25` 使用的 `25.1.1` **不能**當本輪 retail 對照。

## 比對依據與判讀方式

來源為專案內兩份相同世代的 source archive：

```text
OEM：    tools/archives/FOSSCodeForMapleStoryPort.tar.gz
Retail： tools/archives/crossover-sources-25.0.1.tar.gz
```

比較目標分別是：

```text
maplestory-0.0.31-source/wine
sources/wine
```

Wine tree 有 145 個頂層差異項目：139 個共同檔案內容不同，另有 6 個 OEM-only
檔案／目錄項目。這個數字描述整個 OEM snapshot，不代表 145 項都專為楓之谷；例如 native
file dialog、列印、menu capture、一般 WMI 與其他遊戲 workaround 也混在同一棵 source
tree。

本文把差異分成：

- **明確**：原始碼直接寫出 MapleStory、DwarfAxe、BlackXchg 或 MapleStory bug number。
- **直接配套**：沒有遊戲名稱，但 API 與資料格式可直接對上 DwarfAxe／楓之谷實際路徑。
- **推定支援**：只存在 OEM tree，可能服務 NxOverlay、WebView 或 launcher，但原始碼沒有
  足夠證據證明只為楓之谷。

## 修補類型與必要性判準

本文使用下列修補類型：

| 類型 | 定義 | 例子 |
|---|---|---|
| 功能補齊 | Windows API 在 retail Wine 是 stub／`E_NOTIMPL`，OEM 加入實作 | `ClearView`、`OpenSharedResource` |
| 相容性 Bug 修正 | API 已存在，但資源、視窗、焦點或格式轉換結果不符合楓之谷需求 | user-memory texture、fullscreen restore |
| 同步／狀態修正 | 功能可執行，但跨 thread／process 或 GPU state 沒有正確交接 | shared-resource `finish`、compute-state invalidation |
| 效能 workaround | 不改 API 功能，減少 syscall、wineserver、symbol scan 或 scheduler 成本 | file cache、display-mode cache、dbghelp |
| 平台語意修正 | 把 macOS／APFS／Cocoa 行為轉成遊戲預期的 Windows 語意 | APFS free space、non-resizable window |
| 產品整合 | 服務 Nexon 官方 launcher、signed helper 或正式版政策 | `.ms-launch-args`、`WINEDEBUG` 過濾 |
| UX／輸入 | 改善快捷鍵、鍵盤 repeat、menu 行為，不決定 renderer 是否工作 | Cmd+C/V、auto-repeat |
| 防護／診斷 | 避免 crash reporter 或不合法 debug data 令遊戲本身崩潰 | CX26 DWARF 除零 guard |

必要性不是只看 OEM 是否包含該修補，而是分成：

- **A－核心路徑**：直接位於已觀察到的 DwarfAxe／D3D11 畫面路徑；應優先完整移植。A 不
  代表單一 patch 已證明足以顯示畫面。
- **B－條件必要**：只有相關 overlay、防作弊、音訊或狀態轉換發生時才需要。
- **C－非畫面必要**：改善效能、UX、安裝或正式版整合；不能解釋目前黑畫面。
- **D－台版不需要／刻意不移植**：北美 launcher 專用或會妨礙診斷。

專案狀態欄的符號：**✅** 有可重現 patch／build 路徑，**△** 只存在目前 working source 或
已做實驗但尚未整理成正式 patch，**❌** 尚未移植，**繼承** 表示不需自帶 patch、直接使用
官方 CX26 實作。

## OEM、官方 CX26.2 與本專案狀態矩陣

官方欄以未修改的 `crossover-sources-26.2.0.tar.gz` 為準；不能用目前已套 patch 的
`build/cx26/sources/wine` 反推官方狀態。

| 修補群組 | 類型 | 必要性分析 | 官方 CX26.2 | 本專案目前狀態 |
|---|---|---|---|---|
| D3D11 `OpenSharedResource` | 功能補齊 | **B（無 OTP）／待 OTP 再判 A**：無 OTP reverse-G 仍有畫面；DwarfAxe handoff 需 OTP／`jypc` 才驗證 | **未修**：`ID3D11Device5::OpenSharedResource` 仍回 `E_NOTIMPL` | **✅ 實驗**：CX26 shared-texture patch；CX25 rev-G 證明無 OTP 不需要 |
| DXGI `GetSharedHandle` producer | 功能補齊 | **B**：只有 Wine 這側要建立 mapping 時需要；若 DwarfAxe 已是 producer，當前 consumer 路徑可能不需要 | **未修**：`IDXGIResource1::GetSharedHandle` 仍是 stub | **❌**：尚未移植；目前只有 D3D11 consumer |
| D3D9 shared texture mapping | 功能補齊 | **B**：D3D9／overlay 舊路徑才需要；主遊戲黑畫面目前是 D3D11 | **部分基礎**：SYSTEMMEM 可接 user pointer，但 DEFAULT pool shared handle 仍明示未實作，沒有 `winekmt_` mapping | **❌**：尚未移植 OEM named mapping |
| D3D11 `ClearView` entry | 功能補齊 | **B（無 OTP）／待 OTP 再判 A**：rev-G 下 log 可見 `ClearView … stub!` 仍有可見標題畫面 | **未修**：`ID3D11DeviceContext4::ClearView` 仍是 stub | **✅**：CX26 已移植；無 OTP 非必要 |
| rect/UAV clear backend | 功能補齊＋狀態修正 | **B（無 OTP）／待 OTP 再判 A**：與 ClearView 同組；rev-G 已 reverse | **部分基礎**：已有一般 UAV full-clear 與單 rect RTV API，但沒有 D3D11 `ClearView` rect chain | **✅**：CX26 已移植；無 OTP 非必要 |
| shared-resource flush/finish | 同步／狀態修正 | **B**：一旦 shared mapping 被使用就需要；無 OTP 未走到 | **未修**：一般 flush 沒有 OEM 的強制 finish 行為 | **✅**：包含在 shared-texture patch；待 OTP shared call 驗證 |
| user-memory／format conversion texture | 相容性 Bug 修正 | **B（無 OTP）／待 OTP 再判 A**：rev-G 已 reverse 相關 wined3d／d3d11 | **部分基礎**：CX26 有通用 `pin_sysmem` 與 conversion 架構，但缺 OEM 條件 | **✅**：CX26 core patch 有；無 OTP 非必要 |
| display-mode cache | 效能 workaround | **C**：rev-G 連同 mixed headers 一併 reverse 後仍有無 OTP 畫面 | **未吸收**：仍每次查 `EnumDisplaySettingsExW` | **△**：working source 可能仍有；無 OTP 非必要 |
| 主視窗 non-resizable | 平台語意／相容性 | **C（無 OTP）**：rev-W 後仍有畫面；resize 會留白（內容停在原矩形） | **未修**：沒有 `MapleStoryClass` 特例 | **✅**：CX26 core 有；無 OTP 非必要（UX 可另議） |
| 略過 size/move loop | 相容性 Bug 修正 | **C（無 OTP）**：屬 W 組；rev-W pass | **未修**：沒有 MapleStory 特例 | **✅**：CX26 已縮小為 MapleStory；無 OTP 非必要 |
| fullscreen restore guard | 相容性 Bug 修正 | **C（無 OTP）**：屬 W；既有 CX26 A/B 與 rev-W 皆非畫面 blocker | **未修**：無 restore tick／class guard | **✅，A/B 負面**：CX26 獨立 patch；無 OTP 非必要 |
| Dwarf overlay `SWP_NOACTIVATE` | 相容性／焦點 | **C（無 OTP）**：屬 W／S 混雜；rev-W 保留 `cocoa_app.m` 仍 pass | **未修**：無 `DwarfWebBrowserClass` 特例 | **△**：working source 可能有；無 OTP 非必要 |
| BlackXchg foreground guard | 相容性／產品整合 | **C（無 OTP）**：rev-W 未 reverse `cocoa_app.m`（mixed W+S）；整組 W 其他檔 reverse 後仍 pass | **未修**：無 process 特例 | **✅，負面**：CX26 有；無 OTP 非必要 |
| MapleStory 編輯快捷鍵 | UX／輸入 | **C**：只影響登入欄位 Cmd+C/V/X/A/Z | **未等效吸收**：CX26 有一般 macdrv edit/key-repeat 處理，但無 MapleStory message 特例 | **❌**：未移植；不阻擋畫面 |
| raw PCM parser | 功能補齊／媒體相容 | **C（無 OTP）**：rev-Lgs reverse gstreamer／`rawaudioparse` 後仍有畫面 | **未修**：沒有 `rawaudioparse` 或 `RAW_AUDIO_PARSE` | **✅**：CX26／runtime 有；**無 OTP 非必要** |
| `.dll`→`.tmp` 原始 module 名稱 | 防作弊相容 | **A（無 OTP）**：rev-L 失敗——`nstb*.tmp` 被當 builtin 載入後 AV；rev-Lgs 保留 kernelbase 則 pass | **未修**：無 `.msf` sidecar 邏輯 | **✅**：CX26 test mode 有；**無 OTP 必要，應 forward-port** |
| 8 KiB userspace file cache | 效能 workaround | **C**：rev-Pfc reverse 後仍有無 OTP 畫面 | **未吸收** | **△，負面**：working source 可能有；**無 OTP 非必要** |
| 停用 `sched_yield` | 效能 workaround | **C**：rev-Pfc 一併 reverse 後仍 pass | **未吸收**：`NtYieldExecution()` 仍呼叫 `sched_yield()` | **✅，負面**：CX26 有；**無 OTP 非必要** |
| OEM dbghelp 預設停用 symbols | 相容／診斷 | **A（無 OTP）**：rev-P（retail dbghelp）→ `cpu_x86_64.c` assert／CrashReport；rev-Pfc 保留 OEM dbghelp 則 pass | **未吸收**：CX26 正常執行 `SymInitializeW()` | **✅／必要**：OEM 行為或 CX26 DWARF guard 等價物；**無 OTP 必要** |
| CX26 DWARF divide/modulo guard | 防護／診斷 | **B**：這不是 OEM patch，但假 OTP crash reporter 確實會觸發除零 | **未修**：clean CX26 沒有 divisor guard | **✅**：獨立 patch已修掉 Windows 錯誤視窗；不負責渲染 |
| APFS important-usage capacity | 平台語意修正 | **C**：避免 patcher 誤判空間；遊戲已安裝且能開始 D3D 時不需要 | **未吸收**：仍使用 `statfs.f_bavail` | **❌**：未移植 |
| 北美 signed helper handoff | 產品整合 | **D**：台版由 Beanfun argv 直接啟動，實測不需要 helper | **未吸收**：零售 CX26 不含 OEM helper policy | **❌，刻意**：不移植 |
| MapleStory `WINEDEBUG` 過濾 | 產品整合／效能 | **D**：正式版可降 trace 成本，移植調查反而需要完整 log | **未吸收** | **❌，刻意**：不移植 |

### 官方 CX26 已吸收的 OEM supporting changes

以下不再需要本專案自帶 MapleStory patch：

| OEM supporting change | 官方 CX26.2 結果 | 本專案 |
|---|---|---|
| `DeriveCapabilitySidsFromName`／`RtlDeriveCapabilitySidsFromName` | **已吸收且有 tests**；實作已進入 `kernelbase`／`ntdll` | **繼承官方** |
| FAudio `playBegin + playLength` bounds／overflow check | **已吸收**；CX26 FAudio 已有 `bufferLength` 與越界檢查 | **繼承官方** |
| Vulkan swapchain maintenance／presentation scaling | **已吸收並改進**；CX26 同時檢查 surface maintenance 與 swapchain maintenance extension | **繼承官方** |
| `DXGI_PRESENT_ALLOW_TEARING` | **已吸收**；Present 接受 flag，factory 也實作 feature query | **繼承官方** |

### 官方 CX26 仍未吸收、但目前也無必要性證據的 supporting changes

| OEM supporting change | 官方 CX26.2 | 本專案判定 |
|---|---|---|
| `HttpCancelHttpRequest` success stub＋HTTP service auto-start | cancel 仍是 stub；HTTP service 仍為 demand start | 未移植；只有觀察到 overlay HTTP failure 才考慮 |
| MP3 decoder failure consumed-size accounting | OEM 的 `orig_nsrc/orig_ndst` 行為未見於 CX26 | 未移植；沒有對應失敗 log |
| `msedgewebview2.exe` activation blacklist | 沒有該 process 特例 | 未移植；Dwarf class guard已足以做較窄 A/B |
| `iexplore` URL 交給 native browser | 沒有 OEM 的直接 `ShellExecuteW(..., "open", ...)` 路徑 | 台版啟動不依賴，未移植 |
| OEM `wbemprox` table lifecycle 改動 | CX26 的 WMI 程式碼已大幅演進，不能視為相同 hunk | CPU topology probe 已證實 OEM/CX26 輸出相同，不列為目前 blocker |

### CX26 架構差異對移植的影響

CX26 並非只有行號改變：D3D11 已由 `ID3D11DeviceContext1`／`ID3D11Device2` 升級為
`ID3D11DeviceContext4`／`ID3D11Device5`，WineD3D 的 clear、shader backend、Vulkan extension
與 pipeline-layout API 也不同。因此狀態矩陣中的「未修」是指沒有**等效功能**，不是要求把
OEM CX25 patch 原封不動套上去。本專案 full-clear patch 已針對這些 ABI 變化重寫，並額外把
OEM pipeline-layout cache key 沒有完整比較 push-constant range 的風險一併修掉。

## 1. DwarfAxe shared texture

### 1.1 DXGI producer：`IDXGIResource::GetSharedHandle`

OEM 在 `dlls/dxgi/resource.c` 實作零售 CX25 原本缺少的 shared handle：

- 為 2D texture 分配從 `0x40000000` 起跳的 KMT-like handle；
- 建立名為 `winekmt_<handle>` 的 file mapping；
- mapping 前 8 bytes 保存 `width`、`height`，後方緊接像素資料；
- texture backing 改指向 mapping 內的 system memory；
- 同一 resource 重複呼叫會回傳同一 handle。

用途是讓建立 texture 的程序把一塊可跨程序存取的記憶體交給 DwarfAxe／遊戲另一側。這不是
完整 Windows KMT handle 模型，而是 OEM 專用、假設資料競爭有限的簡化協定。

### 1.2 D3D11 consumer：`ID3D11Device::OpenSharedResource`

OEM 在 `dlls/d3d11/device.c`：

- 只接受 `IID_ID3D11Texture2D`；
- 依收到的 handle 開啟 `winekmt_<handle>`；
- 從 metadata 讀取寬高；
- 建立單 mip、單 array layer、`DXGI_FORMAT_B8G8R8A8_UNORM` 的 shared texture；
- 使用 `wined3d_texture_update_desc()` 將 texture 指到 mapping 的像素區。

原始碼對格式、sample count、bind flags 等欄位直接註明「hardcoded in DwarfAxe」，因此這是
最明確的 DwarfAxe 專用修補。

### 1.3 D3D9 相容路徑

`dlls/d3d9/device.c` 也會把傳入的 shared handle 轉成 `winekmt_<handle>`，開啟 mapping 後將
mapped pointer 作為 texture memory。OEM 同時 cache D3D9 multihead adapter 資訊，減少反覆
查詢顯示輸出。

### 1.4 同步與生命週期限制

OEM 在 shared texture 更新後呼叫 command-stream `finish`，確保另一側開始使用 backing
memory 前，先前命令已完成。原碼仍留有 handle close／unmap 的 TODO，因此移植時要特別處理
resource release，不能把 OEM 的 memory leak 當成設計要求。

## 2. D3D11 `ClearView`、rect clear、UAV clear 與 state handling

零售 CX25 的 `ID3D11DeviceContext1::ClearView` 是 stub。OEM 實作後會依 view 類型分派：

- Render Target View：清 color；
- Depth Stencil View：以 `color[0]` 清 depth；
- Unordered Access View：依 format 把 float clear value 轉成正確的 uint／float 表示。

配套修改一路穿過 WineD3D：

- command stream packet 保存 `rect_count` 與完整 rect array；
- RTV／DSV 不再只有單一 rect；
- UAV clear 同樣支援指定矩形，而不是退化成清整張 resource；
- OpenGL backend 以 `glClearTexSubImage`／`glClearBufferSubData` 逐 rect 清除；
- Vulkan backend 以 compute shader clear，透過 push constants 傳入 offset／extent；
- pipeline layout 帶入 push-constant range；
- 每次 dispatch 後重新處理相關 compute state，避免下一個 draw／dispatch 沿用 clear shader
  的 descriptor、pipeline 或 constants；
- buffer 與 texture 都會 clamp rect，忽略空矩形或超出 resource 的區域。

因此「只把 `d3d11_device_context_ClearView()` 從 stub 改成呼叫既有 clear」不是完整移植。
OEM 的 ABI、command packet、GL/Vulkan backend 與狀態失效規則必須一起搬。

## 3. Texture memory、format conversion 與 location 修補

MapleStory bug 23278 修正 CPU／shared-memory-backed texture：

- `user_memory` texture 設定 `pin_sysmem`；
- format 有 upload conversion 且允許 map read/write 時，也固定保留 system memory；
- user-memory texture 在 load 後調整 location flags，避免錯把 GPU copy 當唯一有效來源；
- Vulkan 對需要 format conversion 的 texture 強制建立 staging buffer；
- upload／download 時按 conversion byte ratio 計算大小、row pitch 與 slice pitch。

簡單說，這組修補保證「DwarfAxe 寫在 CPU mapping 裡的像素」不會因 WineD3D 的 location
最佳化或格式轉換而消失、讀錯 stride，或只存在於舊的 GPU image。

OEM 另外把 display mode 查詢結果 cache 在 `wined3d_output`。註解標示 bug 23285，目的是
避免楓之谷高頻查詢目前顯示模式時一直往返 wineserver；這主要是效能修補。

## 4. macOS 視窗、fullscreen、overlay 與焦點

### 4.1 `MapleStoryClass` 主視窗

`winemac.drv/window.c` 辨識 `MapleStoryClass` 後把 Cocoa window 的 `resizable` 設為 false
（bug 23284），避免 macOS 改變遊戲預期的 surface 尺寸。

OEM 對 size/move loop 的 bug 23364 實作較激進：原始碼以 `#if 0` 全域關閉 start/end
size-move loop，而不是只對楓之谷關閉。移植到通用 CX26 時應縮小到
`MapleStoryClass`，否則會影響其他應用程式的拖曳與 resize。

### 4.2 fullscreen restore guard

`win32u` 在收到 `SC_RESTORE` 時記錄 tick；若同一個 `MapleStoryClass` 視窗在 3 秒內把
style 從 `0x94080000` 改為 `0x00ce0000`，OEM 忽略這次 fullscreen→windowed 變更
（CW bug 25287）。用途是避免 restore 過程把 renderer 預期的 fullscreen state 立即沖掉。

### 4.3 Dwarf 與 BlackXchg 不搶焦點

- `DwarfWebBrowserClass` 呼叫 `NtUserSetWindowPos()` 時強制加上 `SWP_NOACTIVATE`，避免 overlay
  web window 取代遊戲視窗。
- `BlackXchg.aes` 執行 `transformProcessToForeground` 時直接返回（bug 23908），避免短命的
  anti-cheat helper 變成 macOS 前景 application。

這兩項處理的是程式啟動時的視窗所有權與使用者輸入，不是 D3D 畫面內容本身。

### 4.4 快捷鍵與 auto-repeat

OEM 不替 MapleStory process 的 macOS Edit menu 綁定 Cmd+Z/X/C/V/A；在
`MapleStoryClass` 的 Windows message 路徑中，則把相同組合轉成 `WM_COPY`、`WM_CUT`、
`WM_PASTE`、`EM_SETSEL` 與 `EM_UNDO`。如此可讓遊戲登入欄位收到編輯命令，又不讓 Cocoa
menu 先攔截按鍵。

同一 snapshot 還把 macOS `KeyRepeat`／`InitialKeyRepeat` 偏好換算成 Windows keyboard
speed/delay，並用 system timers 產生最多三組 repeat message。這是輸入體驗配套，但程式碼
沒有把整套 auto-repeat 限定為楓之谷專用。

## 5. 防作弊暫存 DLL 與 module identity

BlackCipher 會把 DLL payload 複製成 `.tmp` 再載入。OEM 的處理方式是：

1. `CopyFileExW` 發現來源副檔名為 `.dll`、目的為 `.tmp` 時，額外建立
   `<目的檔>.msf` sidecar；
2. sidecar 以 UTF-16 保存原始 DLL 路徑；
3. `LoadLibraryExW` 收到 `.tmp` 時讀取 sidecar，改用原始 DLL 名稱進入 loader。

用途是讓 loader、module enumeration 或防作弊檢查看到原本的 module identity，而不是只有
隨機暫存檔名。OEM 實作是全域副檔名規則，移植時宜增加長度、讀取完整性與配置失敗檢查。

## 6. 音訊修補

OEM 新增 `winegstreamer/rawaudioparse.c`。當 `RAW_AUDIO_PARSE=1` 時，它插在
`audio/x-raw` pipeline 的 `audioconvert` 後方：

- 依 sample rate 與 bytes-per-frame 設定約 300 ms 的 frame size；
- 為 raw PCM buffer 補上 duration；
- 沒有可用 caps 時退回 passthrough。

用途是把沒有 container framing 的遊戲音訊整理成 GStreamer／Wine media pipeline 能穩定
消費的 frame。這是成功 OEM baseline 的環境契約之一，但它主要影響聲音與媒體時序，沒有
證據顯示它單獨決定黑畫面。

OEM tree 同時包含 FAudio buffer bounds 檢查與 MP3 decode error accounting 修正。它們可
避免越界長度與 decode failure 後回報錯誤 consumed size，但原始碼沒有標記為 MapleStory
專用，因此應視為同 snapshot 的通用媒體修正。

## 7. 檔案 I/O、排程與啟動效能

### 7.1 8 KiB userspace file cache

`ntdll/unix/file.c` 對唯讀、同步、且不允許其他 writer 的一般檔案啟用 8 KiB cache。小讀取
會以 `pread()` 預取，並在 userspace 維護 logical file position；seek、非 cached read 與
write 前會同步或失效 cache。

用途是降低楓之谷啟動時大量小檔讀取造成的 syscall 與 wineserver 往返。原始註解標示 bugs
23285、23291。這是侵入性較高的全域最佳化，不能在 CX26 未做回歸測試前直接當成必要修補。

### 7.2 `NtYieldExecution`

OEM 以 `#if 0` 關閉 macOS 上 `NtYieldExecution()` 內的 `sched_yield()` 路徑。用途是避免遊戲
tight polling 時頻繁把 CPU 交還 host scheduler，造成啟動或 frame handoff 延遲。代價是
busy loop 可能提高 CPU 使用率。

### 7.3 dbghelp

OEM 的 `SymInitializeW()` 預設回傳 `ERROR_CALL_NOT_IMPLEMENTED`；只有
`MAPLESTORY_ENABLE_DBGHELP=1` 才走正常 symbol initialization（bug 23291）。用途明確是縮短
啟動，而不是修復 D3D。

CX26 已做過相同行為的單變數測試，結果仍為「閃一下後黑」，因此它不是目前 CX26 黑畫面的
充分修正。它還會降低 crash report 的 symbol 品質，不宜作為通用預設。

### 7.4 APFS 可用空間

Hack 26350 透過 `kCFURLVolumeAvailableCapacityForImportantUsageKey` 查詢 APFS 可用空間，並
用結果覆寫 `statfs` 的 `f_bavail/f_bfree`；失敗、read-only 或非 APFS 時退回原邏輯。用途是
避免 launcher／patcher 因 APFS purgeable space 算法不同而誤判磁碟不足。

## 8. 北美官方啟動與正式版除錯策略

### 8.1 signed helper handoff

`shell32/shlexec.c` 偵測 `MapleStory.exe` 後：

- 把 EXE、arguments、working directory 寫到 `C:\.ms-launch-args`；
- 依 `CX_MANAGED_BOTTLE_PATH`、`MS_HELPER_NAME`／`MS_HELPER_NAME_CLASSIC` 找到 macOS `.app`；
- 改由 signed helper 啟動，並以 `MS_IN_HELPER` 防止遞迴。

這是北美 OEM launcher 的產品整合（bug 25811）。台版 Beanfun 可直接把 host、port、
ServiceAccountID 與 OTP 傳給 Wine，因此不是台版 renderer 的必要修補。

### 8.2 `WINEDEBUG` 過濾

建立 `MapleStory.exe`／`MapleStoryT.exe` process parameters 時，OEM 會在特定 trace/filter
情況把 `WINEDEBUG` 改成 `-all`。用途是降低正式發行版的 trace 開銷。移植與診斷期間不應
照搬，否則會失去判斷遊戲停在哪個階段的資訊。

## 9. OEM supporting changes：可能服務 Overlay／WebView，但不是已證實必要條件

這一群不能整包視為黑畫面修補。與官方 CX26 比較後，capability SID、Vulkan presentation
scaling、tearing flag 與 FAudio bounds check 已經被官方吸收，本專案應直接繼承；HTTP cancel、
HTTP auto-start、native browser、WebView activation blacklist、MP3 error accounting 與 OEM
WMI 差異則仍缺少必要性證據。逐項結果見前面的兩份 supporting-change 表。

判斷原則是先找實際 failure：只有出現缺少 API、HTTP service 未啟動、WebView 搶 activation、
音訊 decoder error 或 WMI 查詢不一致時，才把對應項目升為 B 級條件必要修補。

## 10. 不應誤算成 OEM 楓之谷修補的項目

### CX26 移植過程後來新增的實驗修補

下列項目不是 OEM CX25 原碼中的 MapleStory patch：

- `a6-final-same-view-backing-sync.patch`：CX26 port 為 macOS view／OpenGL backing resize
  設計的後續實驗；OEM CX25 沒有相同 deferred/finalize 實作。
- `maplestory-cx26-dbghelp-dwarf-guard.patch`：CX26 的 DWARF expression 除零保護；OEM 採用的
  是預設整體停用 `SymInitializeW()`。
- 強制 foreground、window reshow、focus kick 等診斷 patch：是 CX26 黑畫面調查實驗，不是
  OEM source patch。

### 一般 CrossOver／OEM product 差異

`comdlg32` native dialogs、printing/menu capture、一般 WMI、其他遊戲註解（例如 Wizard101）、
source-offer 內多出的 SDL2／Python／XML 等元件，不能只因存在 OEM archive 就判定是楓之谷
相容修補。

## 11. 對 CX26 移植的建議分層

**CX25 reverse bisect（無 OTP + OTP／進世界）已完成（2026-07-23）**。

### 11.1 CX25 source bisect 結果

順序實際為 **S → P → W → L → G**；細節見
[`patches/oem25-bisect/README.md`](../../../patches/oem25-bisect/README.md)。

| Gate | 必要 | 非必要 |
|---|---|---|
| 無 OTP 標題／登入（1366） | OEM MoltenVK；OEM dbghelp；OEM kernelbase `.msf` | S；P file-cache／no-yield；W；Lgs；**整包 G** |
| OTP／進世界畫面 | 上述三項 **＋整包 G**；啟動路徑 **`C:\MapleTest`** | S；Pfc；W；Lgs；Documents `Z:`（source 上易「檔案損毀」） |

OTP 證據摘要：

| 引擎／路徑 | 結果 |
|---|---|
| 完整 OEM source + Documents `Z:`（磁碟充足） | 選角後「遊戲檔案損毀」；未載入 `jypc` |
| 完整 OEM source + `C:\MapleTest` | 登入、載入 `jypc`、**進世界成功** |
| rev-G（無 G）+ `C:\MapleTest` | 可進世界，但滑鼠不見、地圖黑、UI／角色缺件（大量 `ClearView` stub） |
| 預編譯 OEM binary + MapleTest | 進世界成功（對照） |

失敗輪次（無 OTP）：rev-P（retail dbghelp）；rev-L（retail kernelbase）。  
最遠無 OTP pass：`install/wine-maplestory-oem25-rev-G-x86_64`。

實務注意：

- OEM CX25 source **必須設 `WINELOADER`**（CW HACK 22144）。
- 每次 `bundle-wine-dylibs`／`make install` 後重掛 OEM `libMoltenVK.dylib`。
- Verbose `+d3d11` 會產生數百 MB log，曾與 NOW LOADING 卡住同時出現；A/B 預設收斂
  `WINEDEBUG`。
- G 內 ClearView／shared／texture state 為配套，**整包 forward-port**；僅可略過 tests／
  純 GL／ddraw 等非 runtime 檔。

### 11.2 CX26 forward-port 契約

必要 runtime／patch（對應 `scripts/build-wine.sh --cx 26 --maplestory-shared-texture-test`）：

1. **OEM binary MoltenVK**（勿用 CX26 FOSS 默默覆蓋）
2. **dbghelp**：`maplestory-cx26-dbghelp-dwarf-guard.patch`（窄於 OEM 全域 bypass，已夠過
   crash-reporter DWARF 除零）
3. **kernelbase `.msf`**：`maplestory-cx26-tmp-module-name.patch`
4. **整包 G 核心**：`maplestory-cx26-d3d11-shared-texture-test.patch` ＋
   `maplestory-cx26-d3d11-full-clear.patch` ＋
   `maplestory-cx26-dxgi-shared-handle.patch`（DXGI producer）＋
   `maplestory-cx26-texture-user-memory-reload.patch`（hack 23278 reload）

建置／啟動：

```text
scripts/build-wine.sh --cx 26 --maplestory-shared-texture-test --with-vulkan --vulkan-source crossover
scripts/copy-oem-moltenvk.sh install/wine-cx26-x86_64
scripts/run-maplestory-cx26-source.sh -- … BeanFun … OTP
```

驗收：`C:\MapleTest` + 真實 OTP → 載入 `jypc.dll` → 進世界 → 滑鼠／地圖／UI 完整。

暫緩：D3D9 named mapping（無進世界證據前不當 blocker）；W／S／Pfc／Lgs；台版不需要的
helper／`WINEDEBUG` 過濾。已在 shared-texture-test 模式一併帶入的 BlackXchg／fullscreen／
no-yield 屬 UX／啟動相容，非本輪 bisect 必要集，可保留但勿與 G 混為「無 OTP 必要」。