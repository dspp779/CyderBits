# 台灣楓之谷 macOS 成功執行基線

最後更新：2026-07-20

## 結論

台灣版楓之谷 V280 已在 macOS 使用 Nexon／CodeWeavers 的 MapleStory OEM CrossOver
25.0.1.38865 engine 成功顯示、通過 Beanfun 登入並實際遊玩。相同的 fresh-prefix 特別版
也已在另一台從未安裝北美 MapleStory Launcher 的 Mac 成功。

目前驗證過的最小基線是：

- 完整且同 build 的 OEM engine，不混用 CX26 的 wineserver、ntdll 或 macdrv；
- 從 engine 通用 `cxbottle.conf` 建立的 win10_64 fresh prefix；
- `LANG/LC_ALL/LC_CTYPE=zh_TW.UTF-8`，Windows code page 950；
- `RAW_AUDIO_PARSE=1`；
- EXE 所在目錄作為 working directory；
- `MapleStory.exe` 後傳入正確的 Beanfun host、port、`ServiceAccountID` 與未使用 OTP；
- BlackCipher／NGS 與遊戲在同一 Wine session 中正常建立並持續運作。

以下曾屬第一輪成功配置，但 fresh-prefix A/B 已排除為必要條件：北美 managed bottle、
官方 signed helper、alternate-loader socket、`MachineGuid` 同步、`CSMT=disabled`、把遊戲
clone 到實體 `drive_c`。**預編譯 OEM binary** 可將遊戲留在 Documents，Wine 會用 `Z:` 對應
原始 host 路徑。**自行編譯 OEM CX25／CX26 source** 進世界請改用 bottle 內 `C:\MapleTest`
（APFS `cp -cR`）；Documents `Z:` 在 source 上易出現「遊戲檔案損毀」（2026-07-23 OTP A/B）。

## 已驗證環境

| 項目 | 成功值 |
| --- | --- |
| Host | macOS／Apple Silicon，Rosetta 執行 x86_64 OEM engine |
| Runtime | CrossOver OEM 25.0.1.38865，build tag `oem-maplestory-na-ngl-0.0.31` |
| Bottle | 由 OEM engine 自行建立的乾淨 win10_64 prefix，約 338–341 MiB |
| 遊戲目錄 | 使用者原始安裝位置；Documents 經 `Z:` 已驗證 |
| 遊戲版本 | V280；畫面顯示 `Ver. 1.2.2.80` |
| Windows ANSI/OEM code page | 950 |
| Unix locale | `LANG/LC_ALL/LC_CTYPE=zh_TW.UTF-8` |
| Renderer | WineD3D Vulkan；log 確認建立 DXGI swapchain |
| 登入 | Beanfun WebStart OTP、`ServiceAccountID` argv |
| 防作弊 | `BlackXchg.aes`、`BlackCipher64.aes`、`NGService.exe` 正常建立 |

## 啟動契約

### Locale

台版主程式會在主畫面前驗證繁體中文 code page。實測：

```text
LANG=C.UTF-8      -> cmd.exe chcp = 437 -> Traditional Chinese code-page error
LANG=zh_TW.UTF-8  -> cmd.exe chcp = 950 -> 通過
```

因此 locale 必須在 Wine process 建立前就注入，不能只在 Wine 啟動後改 registry：

```text
LANG=zh_TW.UTF-8
LC_ALL=zh_TW.UTF-8
LC_CTYPE=zh_TW.UTF-8
```

### Prefix

OEM `cxbottle --create` 會顯示 `This OEM version does not allow creating extra bottles`，但
這只是 OEM 管理 UI/CLI 的產品限制。把 engine 自帶的通用 `cxbottle.conf` 複製到 prefix、
設定 `WineArch=win64`／`Template=win10_64`，再執行 `wineboot -u` 可建立完整 prefix。

特別版另在 `cxbottle.conf` 加入：

```text
[EnvironmentVariables]
"RAW_AUDIO_PARSE" = "1"
```

fresh prefix 會由 OEM engine 自動產生 `cb_access_map_w=1`；沒有 `CSMT=disabled` 或
`UseAltLoader` 仍可成功。

### 遊戲路徑與工作目錄

遊戲不必在物理 `drive_c`。fresh prefix 已直接從 Documents 的原始目錄啟動，log 中 Wine
轉換為：

```text
Z:\Users\<user>\Documents\...\MapleStory.exe
```

MapleStory、BlackCipher、NGS、NxOverlay 與 Vulkan swapchain 均正常建立。Cyder 因此不
clone、搬移或刪除遊戲資料；遊戲更新也會落在同一份原始安裝。working directory 仍必須
設為 `MapleStory.exe` 所在目錄，確保相對資源與防護檔案能被找到。

先前在北美 managed bottle／helper 路徑曾於 Documents 卡在 `find_exe_file`，APFS clone
到 `C:\MapleTest` 後才越過。後續 fresh-prefix 對照證明那不是 `Z:` 的普遍限制，不能再
把 clone 當成產品需求。

### Beanfun argv

帳號資料的三個欄位用途不同：

```text
id   = T9...       # ServiceAccountID，遊戲 argv 使用
sn   = 純數字      # Beanfun step2 的 sotp／帳號選擇
name = 顯示名稱    # UI／record_service_start；不可放入遊戲 argv
```

遊戲命令列：

```text
MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

傳入 display name 時，遊戲能完整顯示但伺服器回覆「未登錄的帳號」；改成與 OTP 綁定的
`ServiceAccountID` 後登入成功。OTP 是短期一次性資料，不應寫入長期設定或一般 log。

## 正常 lifecycle

1. 外部 BeanfunOTP 取得 `ServiceAccountID + OTP`。
2. LaunchServices 把 EXE open event 與動態 argv 送給 Cyder。
3. Cyder 確認 OEM engine；第一次使用時解壓 engine 並建立 fresh prefix。
4. Cyder 固定 CP950 locale、注入 `RAW_AUDIO_PARSE=1`，以 EXE 目錄為 cwd 啟動 OEM Wine。
5. Wine services 與 `MapleStory.exe` 建立。
6. `BlackXchg.aes`、`BlackCipher64.aes`、`NGService.exe` 依序初始化。
7. WineD3D Vulkan 建立 renderer 與 swapchain。
8. NxOverlay／DwarfAxe 與 CEF 子程序建立。
9. Beanfun 驗證成功，進入遊戲；遊玩期間 `BlackCipher64.aes` 持續運行屬正常。
10. 遊戲結束後等待該 Wine session 的遊戲、防作弊與 overlay process tree 收斂。

詳細時序見[啟動 lifecycle 與防作弊機制](launch-lifecycle-and-anticheat.md)。

## 失敗模式

| 現象 | 已知原因／判讀 | 修正 |
| --- | --- | --- |
| Traditional Chinese code-page | Wine 以 CP437 初始化 | process 建立前注入三個 `zh_TW.UTF-8` locale 變數 |
| 「未登錄的帳號」 | argv 使用 display name、錯誤 ID 或 OTP/account 不匹配 | 使用 OTP 對應的 `ServiceAccountID` |
| 無 OTP 顯示錯誤 5 | Beanfun launch credential 缺失 | 取得新的 WebStart OTP |
| retail CX25 無視窗後退出 | OEM 相容 patch 不在 retail engine；曾見 native access violation | 使用完整 OEM engine |
| CX26 黑畫面／游標 | 視窗已建立但 renderer 前進入等待；OEM-only macdrv patch 是主要候選 | 使用完整 OEM engine；勿混搭單一 DLL |
| protocol mismatch | 混用不同 build 的 helper、ntdll、wineserver | engine 元件保持同一 build |

## Cyder 特別版驗收

- app 名稱與 bundle identifier 維持一般版 `Cyder.app`／`local.cyder.app`；
- runtime 安裝到 `~/.cyder/runtime/Engines/wine-x86_64`；
- prefix 建立在 `~/Library/Application Support/Cyder/bottles/shared`；
- 既有其他 engine bottle 改名保存，不覆寫；Wine 正在使用時拒絕切換；
- 不要求北美 Launcher，不讀取 `~/Library/Application Support/MapleStoryNA`；
- 不複製遊戲，直接更新使用者選擇的原始目錄；
- `chcp` 為 950，BlackCipher／NGS／renderer 皆建立；
- BeanfunOTP 傳入正確帳號後能登入並至少完成一次 30 分鐘回歸；
- 正常結束後不留下本輪孤兒 Wine／BlackCipher 程序。

### 首次啟動成本與 UI

2026-07-23 以全新、隔離的 runtime 與 bottle 實測 `Cyder-0.5.0-maplestory-oem25-special`
payload。測試不含 Finder 解壓 ZIP 或 Gatekeeper 的額外成本：

| 階段 | 耗時 | 說明 |
| --- | ---: | --- |
| engine 解壓、掃描與 ad-hoc 簽署 | 18 秒 | 解開 139 MiB `.tar.xz`，並掃描／簽署 OEM runtime 的 Mach-O 檔案 |
| `wineboot -u` | 27 秒 | 建立 win10_64 registry、`drive_c` 與 Wine Windows 模組 |
| `wineserver -w` | 4 秒 | 等待 registry 與 prefix 檔案寫入完成 |
| 其餘設定／manifest | 少於 1 秒 | `cxbottle.conf`、CP950 locale、`RAW_AUDIO_PARSE=1` 與 Cyder marker |
| **合計** | **49 秒** | runtime 約 567 MiB，fresh bottle 約 333 MiB |

第二次以相同 runtime／bottle 執行的準備程序量測為 0 秒（整秒解析度），表示上述成本不會在
正常後續開啟時重複。

舊版 app 在 shell entry 中先同步完成所有準備、最後才執行 `CyderSwift`，所以使用者只會看到
Dock 圖示跳動。新版改成先執行原生 UI，再由 `CyderOEMBootstrap --prepare-only` 在背景執行，
UI 顯示「正在準備 MapleStory OEM 遊戲環境…」。每次準備會寫入：

```text
~/Library/Application Support/Cyder/Logs/oem-bootstrap-timing.log
```

其中包含 `engine-install`、`wineboot` 與 `wineserver-wait` 的逐段秒數；失敗或 Wine 輸出仍在
`oem-fresh-bootstrap.log`。

OEM 與一般 engine 的靜態差異及證據強度見
[OEM engine 差異研究](oem-engine-differences.md)。原始 log、截圖與短期憑證只保留在
被 `.gitignore` 排除的 `debug/`。
