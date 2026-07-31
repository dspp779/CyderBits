# 楓之谷啟動 lifecycle 與防作弊機制

最後更新：2026-07-20

## 文件目的與證據界線

本文描述台灣版楓之谷 V280 在 macOS、Nexon 北美 OEM CrossOver 25.0.1.38865 中的
實際啟動生命週期，以及 BlackCipher／Nexon Game Security（NGS）對 launcher 設計、
成功判斷與結束處理的影響。

證據分三級：

1. **已觀察**：Wine `+process`／`+loaddll` log、macOS process list、畫面與 20 分鐘實玩。
2. **官方可確認**：Nexon 支援文件明確把 BlackCipher 視為 MapleStory 執行樹的一部分，
   並指出殘留的 BlackCipher 可造成下一次 NGS 初始化失敗。
3. **推論**：依程序時序推測元件職責。沒有公開協定或 log 證據的內部細節，不寫成事實。

本文只處理相容性與正常生命週期，不嘗試停用、修改或繞過防作弊。

## Lifecycle 總覽

```text
外部 Beanfun OTP 專案
    │  ServiceAccountID + OTP
    ▼
LaunchServices 把 EXE open event 與 argv 交給 Cyder
    │  首次安裝 OEM engine／建立 fresh prefix
    ▼
OEM winewrapper / wineserver / Wine services
    │  CP950、RAW_AUDIO_PARSE=1、正確 cwd
    ▼
MapleStory.exe
    ├── 載入 NGS／防護相關 DLL 與 AES 模組
    ├── 啟動 BlackXchg.aes（交換／初始化階段）
    ├── 啟動 BlackCipher64.aes（遊戲期間持續存活）
    ├── 建立 DXGI → WineD3D → Vulkan/MoltenVK swapchain
    └── 啟動 NxOverlay/DwarfAxe.exe 與其 CEF 子程序
            │
            ▼
      Beanfun 驗證 → 角色登入 → 遊玩中
            │
            ▼
      遊戲正常結束 → 等待整個 session process tree 收斂
```

防作弊並非「啟動前掃描一次」的單一步驟。成功測試中，`BlackCipher64.aes` 在使用者遊玩
時仍持續執行；這與 Nexon 官方把 MapleStory、launcher、BlackCipher 視為同一需共同結束
的 process tree 相符。因此 launcher 不能在看見 BlackCipher 還活著時，把它一律判定為
殭屍程序；也不能在 `MapleStory.exe` 剛出現後就宣布啟動成功。

## Phase 0：外部認證資料交付

Beanfun QR 登入與 OTP 取得已移至獨立專案。遊戲 launcher 的輸入只有：

```text
account_id = ServiceAccountID（T9...）
otp        = 與同一 service account 綁定的短期 OTP
```

遊戲 argv 固定為：

```text
tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

這個階段的失敗與 Wine／防作弊無關：

- 缺 OTP 可在部分 runtime 看到錯誤 5；
- OTP 已過期或重複使用會在登入握手失敗；
- 把 display name 當成 `ServiceAccountID`，會在畫面正常後顯示「未登錄的帳號」。

launcher 應在記憶體與 argv 邊界中傳遞 OTP，不寫入一般設定檔。Cyder fresh-prefix 路徑
不需要 OEM `.ms-launch-args` one-shot 檔。

## Phase 1：Cyder 與 OEM engine

目前正式成功路徑由 LaunchServices 將 EXE 與動態 argv 交給 Cyder，再由 Cyder 直接使用
完整 OEM engine。Cyder 在建立 Wine process 前注入：

```text
LANG=zh_TW.UTF-8
LC_ALL=zh_TW.UTF-8
LC_CTYPE=zh_TW.UTF-8
```

北美官方 helper 的確另有 `.ms-launch-args`、signed native wrapper 與 alternate-loader
socket 流程；`--enable-alt-loader macdrv` 本身不會建立 socket。Retail CX25/CX26 直接
執行時曾記錄：

```text
CX_ALT_LOADER_SOCKET is not set; nothing to do
```

但 fresh-prefix 路徑在沒有 helper/socket 的情況下已於兩台 Mac 成功，因此 alternate
loader 是北美官方啟動架構，不是台版必要條件。仍不可混用不同 runtime 世代的元件：
OEM 25 helper／`ntdll.so` 與 retail CX26 wineserver 曾因 protocol 1797 與 1809 不一致
而在遊戲建立前失敗。

## Phase 2：Wine bottle bootstrap

OEM wrapper 會啟動或連接該 bottle 的 `wineserver`，接著建立 `wineboot`、`services.exe`、
`winedevice.exe`、`explorer.exe` 等 Wine 基礎程序。這些不是楓之谷本體，但提供 Windows
service、device、registry 與桌面環境。

此時有三個硬性前置條件：

1. **正確 cwd 與可讀的遊戲目錄**：fresh prefix 已驗證 Documents 經 `Z:` 可直接啟動，
   不必 clone 到實體 `drive_c`；cwd 仍設為 EXE 目錄。
2. **CP950**：必須一開始就以 `zh_TW.UTF-8` 建立 Wine。只在稍後改 registry，無法修正
   已用 CP437 完成的 Wine 初始化。
3. **完整 engine 一致性**：成功路徑固定使用 OEM 25.0.1.38865，不與 CX26 的
   `ntdll`、wineserver 或 macdrv 混搭。

特別版保留 `RAW_AUDIO_PARSE=1`。fresh prefix 沒有 `CSMT=disabled` 或 `UseAltLoader`
仍成功；`cb_access_map_w=1` 則由 OEM engine 的通用初始化產生。

## Phase 3：MapleStory 主程序與早期模組

Wine 從正確 cwd 建立：

```text
Z:\Users\<user>\...\MapleStory.exe
```

成功 log 中，主程式 Windows PID 為 `0x0148`（十進位 328）。它先載入遊戲與周邊模組；
在其他 CX25/CX26 對照 log 中可見 `nps64.dll`、`NGClient64.aes`、
`NXOVERLAY_X64.dll`、`MachineIdLib.dll`、`nmcogame64.dll` 等。這些檔名與載入時序可證明
保護、平台整合和 overlay 代碼已進入程序，但不能僅由名稱推斷每個模組的完整內部功能。

Retail CX25 的主程式在這一帶最後發生 native access violation；CX26 則能建立視窗與
遊戲游標，但進入無有效 renderer 活動的訊息等待。這表示防護／平台模組的相容性會影響
「是否走得到 graphics 初始化」，不能把所有無視窗或黑畫面都歸因於 GPU backend。

## Phase 4：BlackCipher／NGS 初始化

成功 log 的相對時序如下。時間以 Wine log timestamp 為準：

| 相對主程式建立 | 事件 | 實際觀察 |
| ---: | --- | --- |
| 0 秒 | `MapleStory.exe` 建立 | `NtCreateUserProcess` 成功，PID 328 |
| 約 7.5 秒 | `BlackXchg.aes "100"` | 由 MapleStory 建立；以 experimental WoW64 mode 執行 |
| 約 9.9 秒 | `BlackCipher64.aes ... 328` | 由 MapleStory 建立；參數含主程式 PID 328 |
| 約 13.7 秒 | WineD3D Vulkan adapter | 主程式開始建立實際 D3D10/11 renderer |
| 約 13.8 秒 | 1366×768 swapchain | 3 個 swapchain images 建立成功 |
| 約 19.4 秒 | `NxOverlay/DwarfAxe.exe` | overlay 主程序建立，參數同樣綁定 PID 328 |

這段時序支持兩個產品設計結論：

- BlackCipher 成功建立是 renderer／登入畫面之前的重要里程碑。若它無法建立、立即退出、
  檔案缺失或 NGS 初始化失敗，遊戲可能在建立完整畫面前中止。
- BlackCipher 的建立不是「launch complete」。真正成功還要等 swapchain、可見畫面與登入
  狀態；相反地，遊玩期間 BlackCipher 繼續存活是本次正常現象。

### 各元件能確認到什麼

`BlackXchg.aes`

- 已觀察為 MapleStory 啟動的第一個獨立 BlackCipher 程序；
- 會存取 `BlackCipher\*.tmp`；
- 名稱與短暫啟動位置顯示它屬於交換／準備階段，但具體協定未公開，這只列為推論。

`BlackCipher64.aes`

- 已觀察由 MapleStory 建立，命令列帶入主程式 PID；
- 使用者在整段 20 分鐘遊玩期間持續看到它運行；
- 因此應視為 session 常駐防作弊程序，而非啟動後可安全清除的 updater；
- 官方支援文件也說殘留／卡住的 BlackCipher 可能讓下一次 NGS 初始化失敗，並要求排障
  時一併結束 MapleStory、launcher 與 BlackCipher process tree。

`NGService.exe`

- Bottle service 設定與部分測試 log 可見 `C:\ProgramData\Nexon\NGS\NGService.exe
  -service`，也曾看到 temp copy 以 `-install` 執行；
- 成功那一輪的截取 log 沒有證明每次啟動都重新建立 NGService，因此不能把它寫成固定
  由 MapleStory 每輪 spawn；
- 對 launcher 而言，它可能是已安裝、由 Wine services 管理的 bottle 級元件。偵測時應
  分開記錄「service 已註冊／可用」與「本輪新建 process」。

`NGClient64.aes`、`nps64.dll` 等 in-process 模組

- 它們和 `BlackCipher64.aes` 不是同一種可見程序：前者載入 MapleStory address space，
  後者是獨立 process；
- 只用 `pgrep BlackCipher` 無法覆蓋完整 NGS 初始化狀態，仍需結合 Wine log、主程式存活
  與遊戲畫面判斷。

Nexon 官方說明 MapleStory 登入時會掃描 hack／惡意程式；官方 NGS 排障也把
`BlackCipher.aes` 的背景殘留列為 client crash／初始化錯誤的可能原因：

- [NGS Initialization Error 0xe1600301](https://support-maplestory.nexon.com/hc/en-us/articles/211274023-NGS-Initialization-Error-0xe1600301)
- [Launch Error: This product cannot be installed](https://support-maplestory.nexon.com/hc/en-us/articles/360036594351-Launch-Error-This-product-cannot-be-installed)
- [A hacking program has been detected](https://support-maplestory.nexon.com/hc/en-us/articles/204741835--A-hacking-program-has-been-detected-error)

## Phase 5：Renderer 與遊戲視窗

成功基線使用 WineD3D 的 Vulkan renderer，經 MoltenVK 在 Metal 上建立 drawable。log
先出現兩個 113×2 的過渡 swapchain，之後建立：

```text
3 swapchain images, 1366 x 768, contents scale 1.0, WineMetalView
```

這是「畫面路徑真的建立」的證據。只有看到 MoltenVK instance、D3DMetal thread 或
載入 `dxgi.dll`，都不足以宣告 renderer 成功。CX26 黑畫面對照就有 D3DMetal 初始化，
卻缺少 MapleStory device／swapchain／present 的證據。

防作弊對這階段的影響主要在前置條件：MapleStory 必須先完成足夠的 NGS 初始化才繼續
走到 renderer。若 NGS 失敗造成主程式退出或進入 soft-failure wait，調整 D3DMetal、
WineD3D、DXMT 通常不會觸及第一原因。

## Phase 6：NxOverlay

主遊戲 swapchain 建立後，MapleStory 啟動 `NxOverlay\DwarfAxe.exe`。成功 log 顯示它是一
個 CEF 型多程序應用，會再建立 network、storage、audio、video capture 與 renderer 等
子程序；部分 renderer 子程序會退出後重建。因此：

- 多個 `DwarfAxe.exe` 不等於多開遊戲；
- overlay renderer 子程序重啟不應直接被判定為 MapleStory crash；
- overlay 也會建立自己的 Vulkan／swapchain 訊息，分析 log 時必須依 Wine PID 區分主
  遊戲 PID 與 overlay PID，不能把 overlay 的 swapchain 誤當成遊戲畫面；
- 停止遊戲時應以本輪 process tree 為範圍收斂 overlay 子程序。

## Phase 7：Beanfun 驗證與遊玩穩態

畫面建立後，client 使用 argv 中同一組 `ServiceAccountID`／OTP 登入。成功的最低判斷
不應只是一個 process 存活，而應至少包含：

1. MapleStory 主程序仍在；
2. `BlackCipher64.aes` 已建立且沒有立即失敗；
3. 主遊戲 PID 建立合理尺寸的 swapchain；
4. 使用者可見遊戲畫面；
5. 伺服器沒有回覆錯誤 5、code-page 錯誤或「未登錄的帳號」。

本輪通過上述條件，並由使用者進入遊戲實玩 20 分鐘。遊玩期間持續存在的 BlackCipher
是成功 session 的正常組成，不是需要 launcher 主動終止的背景垃圾。

## Phase 8：正常結束與殘留清理

launcher 應把一次遊戲視為一個 session，而非一個 PID。建議追蹤：

```text
helper
winewrapper / wineserver（限目標 bottle）
MapleStory.exe
BlackXchg.aes / BlackCipher64.aes
NGService.exe（若本輪或該 bottle 服務建立）
NxOverlay/DwarfAxe.exe process tree
```

正常結束策略：

1. 使用者從遊戲內結束，先等待 MapleStory 自行退出；
2. 給 BlackCipher 與 overlay 合理 grace period 自行收斂；
3. 清除尚未被 helper 消費的 `.ms-launch-args`；
4. 只對本次 session／目標 bottle 的殘留程序送 `TERM`；
5. 再次確認後，才對沒有回應的確切 PID 使用強制終止；
6. 不用廣泛的 `pkill wine` 作為產品預設，避免關掉其他 bottles 或應用。

若 MapleStory 已退出但 BlackCipher 長時間殘留，應標成「session cleanup required」，而
不是「遊戲仍在正常執行」。Nexon 官方資料支持殘留 BlackCipher 會影響下一次初始化，
所以新一輪啟動前應先做唯讀檢查並提示／清理本產品先前追蹤到的殘留 process tree。

## Launcher 狀態機建議

| 狀態 | 進入條件 | 超時／失敗判斷 |
| --- | --- | --- |
| `credentials-ready` | 收到 account ID 與 OTP | OTP 空白、格式錯誤或已過期 |
| `handoff-written` | one-shot 檔原子寫入 | 權限不是 600、寫入失敗 |
| `helper-started` | signed helper PID 出現 | helper 未建立或立即退出 |
| `wine-ready` | 目標 bottle wineserver/services 可用 | runtime protocol mismatch |
| `game-started` | MapleStory PID 出現 | `find_exe_file`、CP950 錯誤、早期 crash |
| `security-starting` | BlackXchg／BlackCipher 開始建立 | NGS process 無法建立或立即失敗 |
| `graphics-ready` | 主遊戲 PID 建立正常尺寸 swapchain | 只有黑窗／游標，無 game swapchain |
| `login-ready` | 登入 UI 可見 | 錯誤 5、未登錄帳號、OTP 失效 |
| `running` | 登入成功／遊戲 session 穩定 | MapleStory 或必要防護程序意外退出 |
| `stopping` | 使用者結束或 launcher 請求停止 | grace period 後仍有追蹤到的殘留程序 |
| `stopped` | 本輪 process tree 與 one-shot 檔均收斂 | 不應要求整台機器不存在任何 Wine |

BlackCipher 的特殊點在於它跨越 `security-starting` 到 `running`；不能在
`graphics-ready` 後將它從監控集合移除。反過來，不能只因它存活就認為遊戲健康，仍要
看 MapleStory、renderer 與登入狀態。

## Debug 與診斷建議

日常 lifecycle log 建議只開：

```text
+timestamp,+pid,+process,+seh,+threadname,+winediag
```

需要確認 DLL 時短暫加入 `+loaddll`；需要窗口時加入 `+macdrv`。`+module` 與長時間
`+process` 可能被 crypto provider／CEF overlay 大量訊息淹沒，不適合作為一般使用者
預設。

每個事件應記錄：

- 單調時間與 wall-clock；
- macOS PID、Wine PID、parent／session ID；
- component（helper、game、BlackCipher、NGService、overlay、renderer）；
- state transition 與 exit status；
- runtime build、bottle、code page、graphics backend；
- 已遮蔽的 argv（OTP 永不寫入一般 log）。

原始 debug log 已由 `.gitignore` 排除。若使用者選擇產生支援包，仍應先遮蔽 OTP、
ServiceAccountID、Cookie、socket path、使用者家目錄與完整 environment。

## 對後續開發的直接要求

- 將 OTP provider 做成外部介面，不重新把 Beanfun 實作搬回此專案；
- 啟動前驗證 OEM runtime build、Rosetta、fresh prefix 與 CP950；
- 直接轉送 EXE 與 Beanfun argv，不複製或刪除使用者的遊戲目錄；
- 追蹤整個 session process tree，特別是遊玩期間常駐的 `BlackCipher64.aes`；
- 將 NGS 初始化失敗與 graphics black screen 分成不同錯誤類別；
- 停止時先 graceful shutdown，再只清理本輪確切 PID；
- 驗收至少包含 30 分鐘遊玩、正常退出、立即重啟、更新後重啟與無殘留程序。
