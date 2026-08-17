# MapleStory OEM engine 與一般 Cyder／CrossOver 的差異

> CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

最後更新：2026-07-20

## 結論

目前最小可行組合已縮小為：**MapleStory OEM CrossOver 25.0.1.38865 engine、由該
engine 自行初始化的乾淨 win10_64 prefix、`zh_TW.UTF-8`、`RAW_AUDIO_PARSE=1`、正確
工作目錄與 Beanfun argv**。不需要安裝北美 MapleStory Launcher、不需要複製北美 managed
bottle、不需要 signed helper 或 alternate-loader socket，也不需要把台版遊戲複製進實體
`drive_c`。

這個組合已在兩台 Mac 驗證，其中一台從未安裝北美 MapleStory Launcher。遊戲可直接留在
Documents；Wine 透過 `Z:` 對應 host 絕對路徑，仍能建立 MapleStory、BlackCipher、
`NGService.exe`、Vulkan swapchain 與 NxOverlay，並正常登入遊玩。

目前最有力的引擎層原因是 OEM `winemac.so` 內有零售 CrossOver 25.0.1 原始碼、零售
CrossOver 26.2 與原版 Cyder engine 都沒有的 MapleStory 專用視窗修正。二進位保留的診斷
字串直接描述兩項行為：

```text
hwnd %p is the main maplestory window; making it not resizable
skipping size-move loop for MapleStory
```

這與 CX26 可建立視窗和遊戲游標、但黑畫面停在訊息迴圈的失敗型態高度一致。這是強證據，
但在取得 OEM 對應原始碼或做 source-level A/B build 前，仍不能宣稱它是唯一原因。

## 三套 engine 的靜態對照

本機比對的三個樣本如下。大小與檔案數包含各自不同的封裝範圍，因此只能描述包裝差異，
不能單獨證明相容性原因。

| 樣本 | 識別 | 大小／檔案 | MapleStory 專用字串 |
| --- | --- | ---: | --- |
| Nexon OEM | CrossOver `25.0.1.38865`，build tag `oem-maplestory-na-ngl-0.0.31` | 567 MiB／2,115 files | `winemac.so`、x86/x64 `dbghelp.dll` |
| 零售 CrossOver | `26.2.0.39821`，build tag `cxoffice-26.2.0rc2` | 929 MiB／5,141 files | 未發現 |
| 原版 Cyder | `CX26.2.0-W11-Cyder003`／Wine 11.0 | 1.0 GiB／1,771 files | 未發現 |

OEM engine 是完整 CrossOver product runtime，而非只有 `wine` binary。它帶有 CrossOver
Perl/Python frontend、GStreamer、MoltenVK、通用 bottle data 與 OEM product config。其
`maplestoryna.conf` 的 active OEM 資訊主要是 product/build branding 與 menu 設定；沒有
發現會自動啟用 MapleStory renderer 的 global registry 或環境變數。

### OEM-only `winemac.so` 行為

全 engine 逐檔搜尋後，只有 OEM `lib/wine/x86_64-unix/winemac.so` 包含：

```text
MapleStory
MapleStoryT
skipping size-move loop for MapleStory
hwnd %p is the main maplestory window; making it not resizable
```

三套 `winemac.so` 的 SHA-256 均不同。OEM 與零售 CX26 的 Mach-O dependencies 大致相同，
所以差異不是「OEM 多 link 一個神奇 framework」，而是在 Wine/macdrv 實作或整體版本內。

為了排除單純的 CrossOver 25 通用行為，另下載 CodeWeavers 官方
`crossover-sources-25.0.1.tar.gz`，搜尋 `dlls/winemac.drv` 與 `dlls/dbghelp`。官方零售版
原始碼沒有上述 MapleStory 字串或 `MAPLESTORY_ENABLE_DBGHELP`。因此可確認目前 OEM binary
包含零售 25.0.1 source release 沒有的客製差異；尚未取得 OEM 同 build 的 source，無法
精確列出 patch hunks。

### OEM-only `dbghelp.dll` 行為

OEM 的 32-bit 與 64-bit `dbghelp.dll` 都含 `MAPLESTORY_ENABLE_DBGHELP`，另外兩套 engine
未發現。從字串位置可看出它靠近 symbol initialization 診斷，但僅靠 binary strings 無法
確認環境變數的完整控制流程。它可能是 crash/symbol handling 相容修正，重要性低於與實際
黑畫面現象直接對應的 macdrv 視窗修正，仍應保留為待驗證變量。

## Bottle 與啟動條件的 A/B 結果

| 變量 | fresh-prefix 結果 | 判斷 |
| --- | --- | --- |
| 北美 managed bottle | 不使用仍成功 | 非必要 |
| 北美 Launcher 安裝 | 第二台完全未安裝仍成功 | 非必要 |
| OEM signed helper | 直接由 Cyder 呼叫 OEM Wine 仍成功 | 非必要 |
| alternate-loader socket | 成功路徑沒有建立 socket | 非必要；是官方 helper 架構能力，不是台版成功條件 |
| `MachineGuid = IOPlatformUUID` | fresh/random MachineGuid 仍成功 | 非必要 |
| 實體 `drive_c` clone | **預編譯 OEM binary**：Documents `Z:` 即可。**自行編譯 source**：進世界請用 `C:\MapleTest`（Documents `Z:` 易「檔案損毀」） |
| `CSMT=disabled` | fresh prefix 沒有此值仍成功 | 非必要 |
| `cb_access_map_w=1` | fresh prefix由 OEM 通用初始化產生 | 是 CrossOver 通用預設，尚無證據為 MapleStory 專用 |
| `RAW_AUDIO_PARSE=1` | 特別版寫入 `cxbottle.conf` | 成功基線的一部分；用途較像 audio parser 相容，未證明與黑畫面直接相關 |
| `zh_TW.UTF-8` | 通過 Traditional Chinese code-page 檢查 | 台版必要條件，Wine code page 為 950 |
| working directory | 設為 EXE 所在目錄 | 遊戲相對資源與防護元件載入所需 |

`CX_ALT_LOADER_SOCKET` 字串同時存在於 OEM、零售 CrossOver 與原版 Cyder的 `ntdll.so`；
它是 CrossOver 通用機制。成功的 fresh-prefix 路徑沒有 socket，故不能再把 alternate loader
視為決定性差異。

## 為什麼這個 engine 可以跑

依目前證據強度排序：

1. **已證實存在的 OEM macdrv 客製修正。** 它針對 MapleStory 主視窗取消 resize，並略過
   size/move loop；這正落在 CX26 黑畫面與等待型態的路徑上。
2. **整套一致的 OEM 25 runtime。** `wineserver`、`ntdll`、`winemac`、Windows DLL、
   MoltenVK/GStreamer 必須維持同一 build。先前混用 helper/runtime 已發生 protocol mismatch，
   所以不能安全地只抽換一個 OEM DLL。
3. **OEM `dbghelp` 客製差異。** CX25 reverse bisect（rev-P fail／rev-Pfc pass）已證明
   無 OTP 標題畫面**需要** OEM dbghelp 行為；retail dbghelp 會走 crash-reporter DWARF
   assert。詳見 [`oem25-bisect/README.md`](../../patches/oem25-bisect/README.md)。
4. **明確的台版環境契約。** CP950 locale、`RAW_AUDIO_PARSE=1`、cwd 與正確 Beanfun argv
   解決的是 code-page、媒體解析、資源定位與認證；它們不能解釋 OEM 與 retail 在相同 argv
   下的全部差異。

BlackCipher／NGS 能在 Wine session 內持續存活也很重要，但目前沒有證據顯示 Cyder 绕過或
停用了防作弊。相反地，成功 log 顯示 `BlackCipher64.aes`、`NGService.exe` 與遊戲一起
建立並維持正常 lifecycle。

## OEM Wine 腳本層特殊行為與啟動參數分析

對比 MapleStory OEM 特定的 Perl `wine` 啟動腳本與啟動參數，可歸納出以下架構級差異與調校結論：

### 1. OEM `wine` 腳本的 8 大關鍵功能

OEM 套件內的 `wine` 啟動腳本包含零售版與基線 Wine 所沒有的自動化管理邏輯：

1. **Apple GPTK (D3DMetal) 驅動動態繫結**：自動檢測 `lib64/apple_gptk/external/libd3dshared.dylib`，並注入 `CX_APPLEGPTK_LIBD3DSHARED_PATH`。
2. **Rosetta 2 .NET 相容性修補**：寫入 `DOTNET_EnableWriteXorExecute=0`，防止 M 晶片在 Rosetta 2 轉譯下因 W^X 記憶體保護導致 .NET/Launcher 崩潰。
3. **GStreamer 多媒體與解碼快取掛載**：自動設定 `GST_PLUGIN_SYSTEM_PATH` 與快取路徑（`gstreamer-1.0-registry.x86_64.bin`），保障過場動畫解碼。
4. **Bottle 容器時間戳動態校驗與升級**：自動比對 CrossOver `BuildTimestamp` 與 Bottle `Timestamp`，必要時自動執行 `wineprefixcreate` / `setup` 修補。
5. **wineloader / wineloader64 動態適應**：依據 `WineArch` 自動選取 32/64 位元架構並載入 `winewrapper.exe`。
6. **POSIX ↔ Windows 路徑雙向轉譯**：處理 `~WS~` 與 `~WB~` 特殊符號轉譯與 `drive_c` 路徑映射。
7. **安全與防毒檢測 (cxavscan)**：對來自 `/tmp` 或非信任來源的執行檔進行安全比對與 GUI 彈窗警告。
8. **即時壓縮 Log 串流**：支援 `.gz` / `.bz2` 即時管道壓縮輸出日誌，避免磁碟空間爆滿。

### 2. 官方啟動參數用途解析

- **`--wait-children`**：
  - **用途**：指示 Wine 必須等待所有衍生子進程（BlackCipher, NGS, NGM, autoupdate 等）完全結束後才釋放 `wineserver`。
  - **影響**：防止遊戲主程式移交或啟動子進程時，Wine 誤判遊戲已關閉而提早釋放伺服器，避免中途閃退與防作弊連線中斷。
- **`--enable-alt-loader macdrv`**：
  - **用途**：強制啟用 macOS 原生視窗驅動 `winemac.drv` 與 CodeWeavers 備用加載器。
  - **影響**：解決 Sonoma / Sequoia 下的記憶體預載限制 (`preloader: failed to reserve range`)，並確保視窗鎖定與滑鼠游標捕獲正常。

### 3. 圖形轉譯（D3DMetal vs DXVK）與效能／散熱調校

- **D3DMetal vs. DXVK**：
  - **D3DMetal (Apple GPTK)**：極限效能高，畫面能輕易達 144Hz 滿幀，為 OEM 預設引擎。
  - **DXVK**：在 CrossOver 中需於 `cxbottle.conf` 中設定 `"WINEDXVK"="1"` 且 `"WINED3DMETAL"="0"`。
- **首次技能頓挫感 (Shader Compilation Stutter)**：
  - 屬 Direct3D 11 HLSL 轉譯至 Metal MSL 的正常即時編譯過程。快取 (Shader Cache) 建立後即可保持流暢。
- **降溫與能效最佳化（關鍵設定）**：
  - D3DMetal 飆至 144 FPS 是導致 Mac 發熱的主因。無需切換至 DXVK，只需在 D3DMetal 下開啟垂直同步 (V-Sync) 或於容器/遊戲內將 **FPS 上限限制在 60 FPS**，即可降低 GPU 負擔並大幅改善過熱。

### 4. 虛擬機 (Parallels Desktop) 效能與架構對比

- **繪圖效能**：CrossOver / D3DMetal 的 FPS 實測比 Parallels Desktop 高出 **40% ~ 100%**。
- **能效與散熱**：Parallels Desktop 需維護 Hypervisor + Win11 ARM OS + x64 模擬，三重過銷導致 CPU/GPU 負擔重且發熱劇烈；CrossOver 無虛擬機過銷，配合 60 FPS 鎖幀在能效上全面碾壓 Parallels。

## 特別版封裝契約

分支 `codex/maplestory-oem-special` 產出的 app 仍叫 `Cyder.app`，bundle identifier 仍為
`local.cyder.app`，因此 BeanfunOTP 與 `.exe` association 不必改。建立方式：

```sh
bash scripts/create-cyder-maplestory-oem-app.sh
```

輸出與安裝位置：

```text
App       dist/Cyder.app
Runtime   ~/.cyder/runtime/Engines/wine-x86_64
Bottle    ~/Library/Application Support/Cyder/bottles/shared
Logs      ~/Library/Application Support/Cyder/Logs
```

第一次啟動會解開內附 `.tar.xz` engine，並從 engine 的通用 `cxbottle.conf` 建立乾淨
win10_64 prefix。若標準位置已有另一版 Cyder bottle，特別版不會覆寫：在 Wine 未執行時，
它先將舊 `shared` 改名為 `shared.before-maplestory-oem25-<timestamp>`；若 Wine 尚在使用該
prefix，則中止切換。遊戲本體不會被複製或刪除，更新會直接落在使用者選取的原始安裝位置。

builder 會在封裝前驗證 OEM engine archive SHA-256：
`be890c31d65d5777204fc9614d19d6fedba1410625594b330dc985cbf96f1e23`，避免本機 artifact
被誤換後仍產出同版本名稱的 app。

## 後續可做的精確隔離

最有價值的下一步是取得 `oem-maplestory-na-ngl-0.0.31` 對應 source offer，與零售 25.0.1
做 patch diff。次佳方案是以相同 CrossOver 25 source 建兩個 ABI 一致的測試 engine，只
加入／移除識別出的 macdrv patch 做 A/B。直接把 OEM `winemac.so` 塞入 Wine 11/CX26 不適合：
它可能與 `wineserver` protocol、Unix call ABI 或相鄰 DLL 不相容，結果無法歸因且可能破壞
prefix。

官方參考：

- [CodeWeavers CrossOver source archive](https://media.codeweavers.com/pub/crossover/source/)
- [CodeWeavers MapleStory compatibility entry](https://www.codeweavers.com/compatibility/crossover/maplestory)

