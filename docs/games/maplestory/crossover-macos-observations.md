# 楓之谷在 macOS / CrossOver 25、26 的執行觀察

最後更新：2026-07-20

程序級啟動順序、BlackCipher／NGS 常駐行為與 launcher 狀態機另見
[啟動 lifecycle 與防作弊機制](launch-lifecycle-and-anticheat.md)。

## 摘要

台灣版楓之谷已在 Nexon 北美官方 CrossOver OEM 25.0.1 runtime 上成功顯示、登入並由
使用者實玩 20 分鐘。完整成功條件與開發規格見
[台灣楓之谷 macOS 成功執行基線](oem25-tw-success-baseline.md)。Retail CrossOver 25/26
的失敗觀察仍保留作為對照，不代表最終可行路徑。

| 環境 | 實際現象 | 可確認進度 | 初步判斷 |
| --- | --- | --- | --- |
| CrossOver 25 | 無 OTP 顯示錯誤 5；有 OTP 時更新檢查後主程式無視窗、安靜結束 | 正確啟動 `MapleStory.exe`，載入遊戲、防護、輸入及 `dxgi.dll`，最後 native access violation | 啟動早期崩潰，尚未穩定進入視窗／繪圖迴圈 |
| CrossOver 26 | 有 OTP 時程序持續存活但無有效畫面；先前曾見黑窗與遊戲游標 | 防護模組與 DXGI 載入，D3DMetal thread 建立；Windows thread 最後停在訊息迴圈 | 沒有 swap-chain / present 證據；更像 renderer 建立前的 soft failure，而非單純 present 黑屏 |
| 北美官方 macOS 包 | 是 Nexon 發行、CodeWeavers 客製的 CrossOver 25.0.1 OEM 包 | 帶有完整 Wine runtime、預製 bottle、Nexon Launcher、啟動腳本與特定 recipe 設定 | 不能只複製 `CSMT=disabled`；官方包依賴整套執行與啟動契約 |
| OEM 25.0.1＋fresh prefix | 兩台 Mac 登入成功、畫面正常；其中一台未裝北美 Launcher | OEM engine、CP950、`RAW_AUDIO_PARSE`、防護與 Vulkan renderer 成立 | helper、managed bottle、alternate loader 與 `drive_c` clone 均非必要 |

文中的「觀察」分成四種證據：實際畫面、Wine log、北美包靜態檔案，以及依上述證據
做出的推論。推論不會寫成已確認事實。

## 測試序列與結論演進

以下依實際排障順序整理，避免最終成功條件掩蓋中間實驗已排除的假設。所有含 OTP 的
原始命令列與 log 均只留在本機 `debug/`，表格使用去識別化描述。

| # | 環境／單一變量 | 結果 | 從該輪能得出的結論 |
| ---: | --- | --- | --- |
| 1 | Retail CX25，無 OTP | 更新檢查後顯示錯誤 5 | EXE 與 Beanfun argv parser 有執行；缺少有效啟動憑證 |
| 2 | Retail CX25，有效 OTP | 無主視窗，最後 native access violation | OTP 排除錯誤 5，但不能解決 CX25 早期 runtime crash |
| 3 | Retail CX26，自動／D3DMetal，有效 OTP | 黑窗或無有效內容，遊戲游標出現，程序卡在訊息等待 | 視窗與游標初始化比 CX25 更遠；沒有主遊戲 swapchain 證據 |
| 4 | CX26 改 WineD3D，其餘不變 | 同一例外時序與等待型態，未建立 device／swapchain | graphics backend 不是第一個失敗點 |
| 5 | CX26 同步 `MachineGuid` | 行為不變，測後恢復 | MachineGuid 不是該黑畫面的充分修正 |
| 6 | Retail CLI 加 `--enable-alt-loader macdrv` | log 仍為 `CX_ALT_LOADER_SOCKET is not set` | 旗標不會自行建立 alternate-loader socket |
| 7 | OEM signed helper 交接給 CX26 runtime | helper protocol 1797、CX26 wineserver 1809 不相容 | helper、`ntdll`、wineserver 必須是同一 runtime 世代 |
| 8 | 合成 helper bundle 全部指向 CX26 | protocol mismatch 消失，但 wrapper 停在 AppKit／server call | 問題縮小至 OEM helper 與 retail wrapper/macdrv 啟動契約 |
| 9 | 原版 OEM25，台版 EXE 位於 host Documents／Y: | `find_exe_file` 停住，沒有建立 MapleStory | 直接沿用 host-mapped 安裝路徑不可行 |
| 10 | 同 bottle 以 `cmd.exe /c dir` 讀同一 EXE | 能列出檔案與正確大小 | drive mapping 可讀；問題是 executable loading，不是檔案不存在 |
| 11 | APFS clone 單一 EXE 到實體 `C:\MapleTest` | 立即越過 `find_exe_file` 進入 `NtCreateUserProcess` | 預設安裝路徑／registry 不是必要；實體 drive_c 才是關鍵 |
| 12 | 完整遊戲 clone 到 drive_c，locale 仍為 C.UTF-8 | 顯示 Traditional Chinese code-page 錯誤 | 完整依賴已足夠，下一個硬條件是 CP950 |
| 13 | 只調 bottle locale／registry，helper 起點未注入 zh_TW | 仍可能先以 CP437 初始化 | helper 在讀 one-shot 檔前已呼叫 Wine；稍後設定太晚 |
| 14 | LaunchServices 從 helper 出生時注入 `zh_TW.UTF-8` | 通過 code-page，建立 BlackCipher、renderer、swapchain 與完整畫面 | locale 必須是 host process-level 啟動條件 |
| 15 | argv 使用 display name | 遊戲畫面正常，但伺服器顯示「未登錄的帳號」 | renderer／防作弊已成功；登入欄位仍錯誤 |
| 16 | argv 改成 OTP 對應的 `ServiceAccountID` | 登入成功並實玩 20 分鐘，BlackCipher 持續運行 | 完整成功基線成立 |
| 17 | 只包 OEM engine，以通用 `cxbottle.conf` 建 fresh prefix | 能建立完整 win10_64 prefix | 北美 managed bottle 非必要 |
| 18 | fresh prefix 直接執行 Documents 中的台版 EXE | 建立 MapleStory、BlackCipher、NGS、Vulkan swapchain 與 NxOverlay | 實體 `drive_c` clone 非必要；`Z:` 可正常使用 |
| 19 | fresh prefix 不使用 signed helper／alternate-loader socket | 正常登入遊玩 | alternate loader 不是台版成功條件 |
| 20 | 第二台未安裝北美 MapleStory Launcher 的 Mac | 正常登入遊玩 | 成功條件在封裝的 OEM engine 與 fresh prefix，不依賴外部 Launcher 安裝 |

這個序列特別顯示三類 failure 必須分開：認證錯誤、Wine／helper 啟動錯誤、遊戲內
NGS／renderer 錯誤。畫面已出現仍可能是認證錯誤；BlackCipher 已載入也不代表 renderer
已建立；反之，遊玩時 BlackCipher 持續存在是正常生命週期。

## 台灣版啟動前提

已確認可用的主程式參數格式為：

```text
MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

沒有 OTP 時的「錯誤 5」很重要：它證明至少在 CrossOver 25 中，台版程式有執行到
Beanfun 啟動參數驗證。有有效 OTP 時不再出現錯誤 5，也證明「安靜消失」不是同一個
登入參數錯誤。

`ServiceAccountID` 是帳號清單中的 `T9...` 值，不是顯示名稱，也不是數字 SN。曾傳入
display name 而得到「未登錄的帳號」；改用與 OTP 綁定的 `ServiceAccountID` 後登入
成功。OTP 與 Cookie 都屬短期憑證，本文件不重複實際值。

## CrossOver 25

### 實際畫面

1. 前置更新檢查畫面可正常顯示。
2. 更新器嘗試開啟主程式。
3. 無 OTP 時顯示錯誤 5。
4. 有 OTP 時不顯示錯誤 5，但主程式沒有建立可見視窗，隨後結束。

### `maplestory-cx25-clean.log` 證據

本次可用的原始 log 位於
`/Users/jjc/Downloads/maplestory-cx25-clean.log`，共約 6,760 行。重要事件如下：

- Wine 收到完整的 `MapleStory.exe`、伺服器、port、`BeanFun`、帳號名稱與 OTP
  command line；不是 shell quoting 導致參數遺失。
- `MapleStory.exe` 以 64-bit native PE 載入，接著載入 `WzMss.dll`、
  `CrashReporter.dll`、`nps64.dll`、`NGClient64.aes`、`NXOVERLAY_X64.dll`、
  `MachineIdLib.dll`、`nmcogame64.dll` 等遊戲與防護模組。
- Wine builtin `dxgi.dll`、`dinput8.dll` 與 `winemac.drv` 已載入；但 log 中沒有看到
  MapleStory 成功建立 swap chain 或開始穩定 present 的證據。
- 先出現 `EXCEPTION_FLT_DIVIDE_BY_ZERO (0xc000008e)`。這次例外有進入遊戲自己的
  vectored handler，所以它本身不一定是致命原因。
- 後段出現 C++ exception，最後是讀取位址 `0x658` 的
  `EXCEPTION_ACCESS_VIOLATION (0xc0000005)`；Wine 同時回報 exception frame 不在
  stack limits，之後程序結束。這是目前最接近真正終止點的證據。
- log 大量重複載入／卸載 `rsaenh.dll`，顯示終止前曾密集走過加密 provider 或偵測
  路徑；它是現象，不足以單獨認定根因。
- `kerberos_LsaApInitializePackage no Kerberos support`、HID 裝置忽略與
  `winebth` 啟動失敗多半是 Wine 的常見雜訊，沒有證據顯示它們造成這次終止。

### Alternate loader 沒有實際啟用

雖然命令列使用了：

```sh
--enable-alt-loader macdrv
```

但在建立 `MapleStory.exe` 的關鍵位置，log 明確顯示：

```text
send_to_cx_loader loader (null) ... wineloader (null)
CX_ALT_LOADER_SOCKET is not set; nothing to do
```

因此這次 CX25 測試不能視為「已成功套用北美包的 alternate loader」。命令列接受選項
不等於 loader socket 已建立。這是後續重現官方包時應優先驗證的項目。

### MoltenVK 訊息的解讀

log 前段可看到 MoltenVK 1.2.10 建立 Vulkan instance，但時間點位於 Wine 桌面／顯示
初始化階段，早於 `MapleStory.exe` 啟動。它只能證明該 CrossOver runtime 能載入
MoltenVK，不能證明 MapleStory 的實際繪圖路徑正在使用 Vulkan，也不能證明黑畫面已由
MoltenVK 接管。

## CrossOver 26

### 實際畫面

- 帶或不帶 OTP 都會建立主程式視窗。
- 視窗維持黑畫面，不會自行退出，需要手動關閉。
- 部分執行中，macOS 游標會換成楓之谷遊戲內的小手圖示。

這些現象表示 CX26 至少比 CX25 多完成了視窗建立、游標資源載入及部分訊息迴圈。
因此 CX25 的「主程式早期崩潰」與 CX26 的「黑畫面卡住」應視為不同 failure mode，
不應以同一個 registry 開關概括。

2026-07-19 已完成有效 OTP 的乾淨重跑。原始 log 與 macOS `sample` 留在本機、由
`debug/` ignore rule 排除；文件保留其可重現結論。這次可確認：

- `自動`實際選到 `d3dmetal`；D3DMetal 3.0、Metal driver 與 `D3DMetalWineThread` 都已載入。
- 遊戲載入 `nps64.dll`、`NGClient64.aes`、`NXOVERLAY_X64.dll`、`MachineIdLib.dll`、
  `nmcogame64.dll` 與 builtin `dxgi.dll`。
- 啟動早期穩定重現由遊戲 vectored handler 接住的 `0xc000008e`，約 5–6 秒後再出現同一
  ThrowInfo 位址的 C++ exception。它們在 D3DMetal 與 WineD3D 都相同。
- WineD3D 對照只走到 `wined3d_dll_init`，沒有 adapter、device、swap chain 或 present。
- 卡住約 67 秒時，Windows thread 停在 `NtUserGetMessage` / `NtWaitForMultipleObjects`；
  D3DMetal thread 也在等待。沒有活躍 render loop 的證據。
- 因此目前較強的判斷是遊戲在真正 renderer / swap-chain 建立前已進入 soft-failure 的
  訊息迴圈；「D3DMetal 已成功 present 但畫面黑」反而缺少證據。

另做了兩個單變量對照：

1. 切到 `Wine`（WineD3D）後，例外地址、時序與停止型態相同；顯示後端不是第一原因。
2. 依北美 `run_maplestory` 暫時同步 `MachineGuid` 到 Mac `IOPlatformUUID`，結果仍相同；
   測試後已恢復原值。

後續 fresh-prefix 實驗已證明 alternate loader 不是必要條件。這段 CX26 訊息仍能說明
當時的 flag 沒有建立 socket，但不能再用來解釋 OEM engine 為何成功。

本機目前安裝的是 CrossOver 26.2.0 build 39821。CodeWeavers 的官方變更紀錄指出，
CrossOver 26 基礎更新為 Wine 11.0、vkd3d 1.18、D3DMetal 3.0 與 DXMT 0.72；這些變更
足以解釋為何同一支程式在 25 與 26 呈現不同 failure mode，但官方紀錄沒有宣稱支援
台灣楓之谷。[CodeWeavers CrossOver changelog](https://www.codeweavers.com/crossover/changelog#26.0.0)

## 北美官方 macOS 包的靜態觀察

分析來源是工作區的 [`dist/maplestoryna`](../../../dist/maplestoryna)；其內容大小約
991 MB。

### 它不是原生 macOS 遊戲

北美包是一套 Nexon 品牌的 CodeWeavers OEM runtime：

- Product Name：`MapleStory Launcher`
- Public Version：`0.0.31`
- CrossOver Product Version：`25.0.1.38865`
- Build Tag：`oem-maplestory-na-ngl-0.0.31`
- Build Timestamp：`20260708T152309Z`
- `MapleStory.app` bundle ID：`com.nexon.maplestoryna_exe`
- Code-signing Team ID：`T7S9D7UD43`
- app 與 `wineloader` 都是 thin `x86_64` Mach-O；不是 arm64 原生執行檔。
- `Info.plist` 宣告最低 macOS 10.15。Apple Silicon 上因為 host helper 與 loader 是
  x86_64，合理推論仍需要 Rosetta 2；這一點是架構推論，不是包內明文需求。

包內同時存在 `MapleStory.app` 與 `MapleStory Classic World.app`，兩者都是 OEM helper，
最終仍啟動 Wine bottle 裡的 Windows 程式。Nexon 官網是 bundle 內明列的 Home URL：
[MapleStory 官方網站](https://www.nexon.com/maplestory/)。

### 精確 runtime

OEM 包鎖定 CrossOver 25.0.1，而不是泛指「任何 CrossOver 25」。CodeWeavers 官方資料
顯示 CrossOver 25 基於 Wine 10.0、vkd3d 1.14、MoltenVK 1.2.10，並加入 DXMT 與
D3DMetal 2.1。[CodeWeavers CrossOver changelog](https://www.codeweavers.com/crossover/changelog#25.0.0)

北美包本身也帶有：

- 32-bit 與 64-bit Wine Windows/Unix runtime；
- `libMoltenVK.dylib`、`winevulkan` 與 vkd3d；
- GStreamer runtime 與 plugins；
- Wine Gecko / CrossOver HTML engine；
- 預裝的 Nexon Launcher；
- Microsoft Visual C++ 2015–2022 x86 與 x64 runtime 14.42.34438；
- `win10_64` 預製 bottle。

「檔案存在」不等於「MapleStory 當次啟動有使用」。尤其包內沒有找到 active bottle 的
`CX_GRAPHICS_BACKEND=d3dmetal`、`WINED3DMETAL=1` 或 DXMT 專用設定；D3DMetal / DXMT
字串主要出現在通用 bottle template。因此不能由 `libMoltenVK.dylib` 的存在直接判定
官方楓之谷走 Vulkan，也不能假設它走 D3DMetal。

### 官方啟動鏈做的額外工作

北美包不是直接對遊戲 EXE 執行一行 `wine`。[`run_ngl`](../../../dist/maplestoryna/MapleStory%20Launcher/run_ngl)
與 [`run_maplestory`](../../../dist/maplestoryna/MapleStory%20Launcher/run_maplestory) 會：

1. 取得 default bottle 的 Windows `C:\` 路徑並設定 `WINE_APPNAME_INI`；
2. 修正 bottle 目錄權限；
3. 讀取 macOS `IOPlatformUUID`，將 Wine registry 的 `MachineGuid` 更新成同一個值；
4. 使用 `--enable-alt-loader macdrv` 啟動 Nexon Launcher 與遊戲；
5. 由 Nexon Launcher 產生 `C:\.ms-launch-args`；
6. `run_maplestory` 讀入 `MS_LAUNCH_DIR`、`MS_LAUNCH_APP`、`MS_LAUNCH_ARGS`，刪除一次性
   參數檔，再以正確 working directory 啟動遊戲。

這個 launcher-to-helper 交接很可能包含北美遊戲需要的短期 token 或啟動狀態。因此，
「直接執行北美 MapleStory.exe」也不等同官方 macOS 啟動方式。

### Bottle 中確認到的特定設定

[`cxbottle.conf`](../../../dist/maplestoryna/support/maplestory/cxbottle.conf) 與
[`user.reg`](../../../dist/maplestoryna/support/maplestory/user.reg) 顯示：

```text
[EnvironmentVariables]
RAW_AUDIO_PARSE=1

[Software\Wine\Direct3D]
cb_access_map_w=1
CSMT=disabled
```

解讀如下：

- `RAW_AUDIO_PARSE=1` 是明確寫進 bottle 的環境變數，應納入台版對照測試。
- `CSMT=disabled` 的確存在，但它是 WineD3D command-stream 行為設定，不是「選擇
  MoltenVK / D3DMetal / DXMT」的總開關。
- `cb_access_map_w=1` 也存在；不過相同設定同時出現在 CrossOver 通用
  `crossover.inf`，不宜直接視為楓之谷專屬修補。
- 沒有 active `D3DMetal`、`DXMT` 或 `DXVK` bottle flag，是很重要的「未發現」結果。

此外，registry 有一組廣泛的 native/builtin overrides，以及 VC++ runtime、DirectPlay、
Quartz、MSHTML 等相依元件。這些大多來自 CrossOver recipe，不能只挑一個 DLL override
複製到乾淨 bottle 後便宣稱等價。

## 三個環境的差異與目前結論

### 1. `CSMT=disabled` 不是充分條件

北美包的正常顯示若已被外部確認，最多只能說 `CSMT=disabled` 是其已知組態之一。它與
精確 OEM Wine build、managed bottle、launcher handoff、MachineGuid、工作目錄、
alternate loader、runtime dependencies 同時存在，沒有單變量實驗可以證明 CSMT 是
關鍵原因。

### 2. Retail CrossOver 25 不等於北美 OEM CrossOver 25.0.1

北美 build tag 明確是 `oem-maplestory-na-ngl`，可能包含未出現在一般 GUI 選項或標準
CrossOver 發行版中的產品 patch、簽章、loader 配置與 application database 規則。台版
CX25 log 又顯示 alternate loader socket 未建立，因此兩者目前並非同條件比較。

### 3. CX26 黑畫面表示進度更遠，不代表 graphics backend 已正確

遊戲游標出現與視窗持續存在，代表程式至少沒有在 CX25 的同一位置立即終止；但若缺少
`+d3d`、`+dxgi`、`+macdrv` 或對應 backend log，仍不能判定黑畫面是 shader、present、
解析度還是遊戲主執行緒等待。

### 4. 台版與北美版遊戲本體也不是控制變量

台版使用 Beanfun OTP 與自己的防護／服務端；北美版透過 Nexon Launcher。即使 Wine
設定完全相同，遊戲 binary、overlay、防護模組與啟動握手差異仍可能產生完全不同結果。

## 歷史驗證順序（已由 fresh-prefix 結果取代）

下列是 2026-07-19 尚未完成 OEM fresh-prefix 對照時的排障順序，保留用來解釋研究演進。
其中 alternate loader、managed bottle 與實體 `drive_c` 已在 2026-07-20 排除為必要條件，
後續工作應改以 [OEM engine 差異研究](oem-engine-differences.md) 為準。

1. **當時：確認 alternate loader**：每次啟動先檢查 log；成功條件不是命令列有選項，而是
   不再出現 `CX_ALT_LOADER_SOCKET is not set`，且 loader 欄位不為 null。
2. **固定乾淨 bottle 與遊戲檔案**：分別保存 CX25、CX26，不在同一 bottle 升降級。
3. **北美明確設定已完成第一輪**：`RAW_AUDIO_PARSE=1`、`CSMT=disabled`、
   `cb_access_map_w=1` 均已存在；MachineGuid 同步對照無改善。下一步不要重複這些變量。
4. **確認 working directory**：以 MapleStory.exe 所在目錄作為 `--workdir`，排除相對
   路徑與資源檔尋找差異。
5. **下一個 renderer 對照**：D3DMetal 與 WineD3D 已完成；視需要再測 DXMT，但目前兩者
   已足以顯示例外早於真正 device / swap-chain 建立。
6. **後續精簡 debug**：不要使用 `+module`；`+process` 也會被 `rsaenh.dll` 查詢淹沒。
   基線使用 `+timestamp,+pid,+seh,+threadname,+winediag`，需要視窗時只短暫加 `+macdrv`。
7. **當時：集中 alternate loader / OEM runtime**：設法由真正建立 loader socket 的 OEM helper
   啟動，或在北美 OEM runtime 中建立可控台版 bottle；這比繼續調 renderer 更有價值。

### OEM alternate loader 的後續靜態分析（2026-07-19）

已確認 `--enable-alt-loader macdrv` 只是 client-side 開關，不會自行建立 socket。北美包的
原生內層 `MapleStory.app` 會建立並監聽 `AF_UNIX` socket，將暫存路徑放入
`CX_WINEWRAPPER_ALT_LOADER_SOCKET`；`winelib.so` 再將它轉成
`CX_ALT_LOADER_SOCKET`。`ntdll.so` 連回 helper，傳送 cwd、environment、argv 與多個 file
descriptor，最後由 helper 載入 `ntdll.so` 並呼叫 `__wine_main`。

此外，北美 OEM bottle 在 `Software\\CrossOver\\UseAltLoader` 明確列出
`MapleStory` 與 `nexon_client`；CX26 `test` bottle 尚無此 whitelist。這證明北美 helper
路徑會使用該機制，但 fresh prefix 沒有 whitelist/socket 仍成功，故它不是台版必要條件。
原始逆向筆記留在本機忽略的 `debug/`。

實測 signed OEM helper 將 socket 交給 CX26 後，MapleStory request 已成功送出，但 OEM
helper 載入 protocol 1797 的 `ntdll.so`，與 CX26 wineserver protocol 1809 不相容。再以
workspace 合成 bundle 令 helper 的 `CX_ROOT` 指向 CX26，可消除版本不合；sample 也確認
載入 CX26 `ntdll.so` / `winelib.so` / `winemac.so`。但 CX26 `winewrapper.exe` 隨後停在自身
`__wine_main` / AppKit loop 與 `NtCreateFile -> wine_server_call`，尚未建立 MapleStory
子程序或送出第二階段 socket request。這把問題進一步縮小到 OEM helper 與 retail CX26
wrapper/macdrv 啟動模型，不是 MapleStory renderer 本身。
另一個可重現的 binary 差異是 OEM `winemac.so` 含有 `MS_GUID`，retail CX26
`winemac.so` 沒有，進一步支持北美包具有 MapleStory 專屬 runtime patch。

### 北美 OEM 25 直接跑台版的實測（2026-07-19）

已使用當次新取得的 Beanfun OTP，讓未修改的 signed OEM helper 啟動台版
`MapleStory.exe`。handoff 環境同時具有真正的
`CX_WINEWRAPPER_ALT_LOADER_SOCKET`、`MS_GUID` 與 `MS_IN_HELPER=1`；`lsof` 也確認兩個
Unix socket 都存在。因此這次失敗不能再歸因於「少建立 alternate-loader socket」。

不過 OEM helper 路徑仍停在 `winewrapper.exe`，沒有建立 MapleStory 子程序或視窗。移除
helper、直接用 OEM 25.0.1 runtime 與 OEM bottle 執行台版後，Wine services 都能完成
初始化，但在 `CreateProcessInternalW` 的 `find_exe_file` 階段停止。使用 `Y:` host mapping
與明確的 `C:\users\crossover\Documents\...\MapleStory.exe` 結果相同。

唯讀控制組 `cmd.exe /c dir` 則能從同一 bottle、同一 C: 路徑正常列出該檔案及其
183,627,232 bytes 大小。這表示 bottle drive mapping 和一般檔案存取正常；目前障礙更精確
地落在 OEM Wine 對台版 PE 的 executable create/open/inspection 路徑，而且發生在
alternate-loader handoff、遊戲防護初始化與任何 renderer 建立之前。這輪結果不能用來判定
CX26 黑畫面的 renderer 根因，但已排除「把北美 OEM runtime 套到台版就會直接正常」這條
捷徑。

後續 APFS clone 對照修正了上述結論中的一個重要限制：先前即使使用 C: 路徑，
`C:\users\crossover\Documents` 仍是指向 `/Users/jjc/Documents` 的 symlink。將 EXE clone
到 bottle 實體 `C:\MapleTest` 後，OEM Wine 立即越過 `find_exe_file` 並成功建立
MapleStory 程序。因此原本的停點是 host Documents mapping 上的 executable loading，
不是預設安裝目錄名稱或缺少 Gamania `InstallLocation`。

完整遊戲資料以 `cp -cR` clone 到 `C:\MapleTest` 後，下一個明確需求是繁體中文 code
page。OEM runtime 的實測為 `LANG=C.UTF-8 -> chcp 437`、
`LANG=zh_TW.UTF-8 -> chcp 950`。只改 bottle registry 不夠，因為 OEM helper 會在讀取
one-shot `.ms-launch-args` 前先啟動 Wine 執行 `winepath`。必須從 LaunchServices 建立
helper 行程時便注入 `LANG`、`LC_ALL`、`LC_CTYPE=zh_TW.UTF-8`。

在 native drive_c、完整資料、CP950、新 OTP 與 genuine alternate-loader socket 同時成立
後，台版已通過 code-page 檢查並建立 `BlackXchg.aes`、`BlackCipher64.aes`、
`NGService.exe` 與 `NxOverlay/DwarfAxe.exe`；WineD3D 選擇 Vulkan renderer 並建立 DXGI
swapchain。最後將 argv 的帳號欄位由 display name 修正為 `ServiceAccountID` 後，使用者
確認登入成功、畫面正常並實玩 20 分鐘。先前的無視窗與「未登錄的帳號」都已解決。

### OEM 25 engine 建立全新 prefix 的實測（2026-07-20）

為確認 Cyder 是否必須配送或借用北美 OEM bottle，本輪只使用已打包的 OEM CrossOver
25.0.1.38865 engine，在 `/private/tmp` 建立全新 prefix；沒有讀取或 clone
`MapleStoryNA/Bottles/maplestory` 的 registry、Windows 目錄或 bottle 設定。

OEM `cxbottle --create --template win10_64` 會刻意拒絕並回覆
`This OEM version does not allow creating extra bottles`。這是 OEM 管理工具的產品限制，
不是 Wine 無法建立 prefix。將 engine 自帶的
`share/crossover/bottle_data/cxbottle.conf` 複製為新 prefix 的最小 CrossOver metadata
後，以 `LANG/LC_ALL/LC_CTYPE=zh_TW.UTF-8` 執行 `wineboot -u` 成功：

- 新 prefix 約 338 MiB，`cmd.exe /c chcp` 回覆 950；
- `wineboot` 自動產生獨立 `MachineGuid`、`system.reg`、`user.reg` 與 Windows 目錄；
- 第一輪以 APFS clone 將台版遊戲放入實體 `C:\MapleTest` 後成功啟動；
- 使用者目視確認遊戲視窗與登入失敗畫面正常顯示；失敗是本輪刻意使用已失效的舊登入
  資訊，不是啟動或繪圖失敗；
- log 確認載入 `MapleStory.exe`、`NGClient64.aes`、`BlackCall64.aes`、
  `BlackCipher64.aes`，並建立 WineD3D Vulkan D3D10/11 renderer。

全新 prefix 沒有 OEM bottle 的 `CSMT=disabled` 與 `UseAltLoader` registry 項目，仍成功
顯示；`cb_access_map_w=1` 則由這個 OEM engine 的初始化路徑自動產生。`RAW_AUDIO_PARSE=1`
本輪仍由啟動環境注入。因此目前產品結論是：**Cyder 必須配送 OEM engine，但不必配送
完整 OEM bottle，也不必要求使用者先安裝北美版 MapleStory**。Cyder 可在第一次執行時
從 engine 內建的通用 `cxbottle.conf` bootstrap 約 338 MiB 的新 prefix。

同日再以相同 fresh prefix 直接啟動 Documents 中的原始遊戲目錄。OEM Wine 將 macOS
絕對路徑轉為 `Z:\Users\jjc\Documents\...\MapleStory.exe`，成功建立 MapleStory、
`BlackXchg.aes`、`BlackCipher64.aes`、`NGService.exe`、WineD3D Vulkan 1366×768
swapchain 與 NxOverlay。這推翻先前由 managed OEM bottle 得出的「遊戲必須位於實體
drive_c」限制；真正差異較可能是舊 managed bottle／啟動環境，而不是 `Z:` 或 Documents
本身。測試版因此直接使用使用者選取的 EXE，不再 clone 遊戲資料。其後使用者已在另一台
完全沒有北美 MapleStory Launcher 的 Mac，以這個 OEM engine＋fresh prefix 特別版完成
登入與遊玩；產品不應再要求外部 Launcher 或 managed bottle。

## 證據限制

- CX25 與 CX26 現在都有可重讀 log；CX26 另有 5 秒 macOS thread sample。
- 北美 OEM runtime 已完成啟動台版 EXE 的動態對照；但本次沒有使用北美帳號完成
  Nexon Launcher 登入，也沒有北美版成功進入遊戲的 runtime trace。
- 台版成功結論包含使用者目視登入與 20 分鐘實玩確認；尚未完成長時間、睡眠喚醒、更新
  後重啟與多台 Mac 的回歸測試。
- CodeWeavers changelog 只證明各 CrossOver 大版本的基礎元件差異，不證明台灣楓之谷
  官方相容。
- 本文件不把正常 Wine `fixme`、HID、Bluetooth、Kerberos 訊息直接當成根因；必須有
  時序或單變量測試支持才升級為根因候選。

## 參考資料

- `/Users/jjc/Downloads/maplestory-cx25-clean.log`（本機原始 log，未納入版本庫）
- [`dist/maplestoryna`](../../../dist/maplestoryna)
- [CodeWeavers CrossOver changelog](https://www.codeweavers.com/crossover/changelog)
- [Nexon MapleStory 官方網站](https://www.nexon.com/maplestory/)
- [lshw54/maplelink](https://github.com/lshw54/maplelink)
