# Cyder 專案開發狀態 Dashboard

> 最後整理：2026-08-17
> 基準：Cyder `0.10.1` test channel 工作版本
> 讀法：本頁是跨文件的狀態總覽；實作行為以程式碼與測試為準，研究結論以各主題文件為準。

## 一句話結論

Cyder／CyderBits 的核心啟動器、遊戲庫、每遊戲設定、圖形 backend、診斷記錄與單一選單列
instance 已經形成可測試的產品骨架；目前離「可以放心宣告 0.10.1」最近的工作，不是再加
功能，而是完成 DXMT／Steam／反作弊遊戲的實機回歸，以及把目前保守的
prefix-level 程序等待，升級成能辨識每個遊戲與 helper 的 LaunchGroup monitor；後者排定於 0.11.0，
不列入 0.10.1 release gate。

最需要持續追蹤的兩個技術風險是：

1. MapleStory Classic 離場後 `grap-core64.aes` 的 `NtQueryDirectoryObject` →
   `get_directory_entries` 高 CPU livelock；Cyder009 已有窄範圍緩解，但語意根因尚未關閉。
2. 台版 OEM MapleStory 的 CX26 source port 已完成多層 patch 與編譯／lifecycle 驗證，
   但完整有效 OTP 進入角色／地圖並連續遊玩的畫面驗收仍未完成。

## 狀態圖例與優先級

| 標記 | 意義 |
|---|---|
| 🟢 已完成／已出貨 | 有程式碼、測試或實機證據支持；仍需留意回歸 |
| 🟡 進行中／待驗證 | 主體已存在，但缺實機、長跑、release 或跨遊戲驗收 |
| 🟠 workaround／已知限制 | 使用者可運作，但不是根因修復或產品級完整解法 |
| ⚪ 待開發 | 已有設計／計畫，尚未形成完整實作 |
| P0 | 會直接影響 release、遊戲能否結束，或可能留下高 CPU／殘留程序 |
| P1 | 影響主要遊戲支援、維護成本或使用者體驗 |
| P2 | 品質提升、研究或可延後的相容性工作 |

## 總覽

| 工作線 | 目前狀態 | 重要性 | 目前判斷 |
|---|---|---:|---|
| Cyder 0.10.1 release | 🟡 test channel，待實機回歸 | P0 | `CX26.3.0-W11-Cyder011` 已 pin；MapleStory WZ adaptive cache 預設開啟且可於進階關閉；DXMT、Steam／反作弊仍要逐款驗證；DXVK 2 已列入待開發 |
| 啟動器／遊戲庫／設定 | 🟢 核心已落地 | P1 | 已有 per-profile、圖形 backend、環境變數、argv、診斷與執行中套用流程 |
| 執行中的程序管理 | 🟡 部分完成 | P1／0.11.0 | 單一 primary icon、session sidecar、背景等待已存在；真正的 per-game process monitor 延後至 0.11.0 |
| 台版 MapleStory OEM | 🟡 OEM baseline 可玩；CX26 port 待完整畫面驗收 | P0 | OEM25 已實玩；CX26 第一層／G 組 patch 可建置，仍缺有效 OTP 的地圖級驗收 |
| MapleStory Classic directory query | 🟠 Cyder009 bandage 已出貨 | P0 | QDO `optnone` 可消除已觀察 livelock；HID／`\??` 目錄語意與 session 清理仍開放 |
| 每遊戲客制設定 | 🟢 基本能力已完成；邊界固定 | P1 | 可覆寫 backend、高解析度、字體、環境變數、argv；MSync／ESync／能源模式仍是 global |
| 遊戲相容性矩陣 | 🟡 有廣度，需跟 0.10.1 artifact 重跑 | P1 | 老遊戲 workaround 已文件化，但新版 graphics payload 尚未逐款宣布通過 |
| Wine Engine 瘦身／CyderBits Bash 化 | ⚪ 文件化待開發 | P2 | 不阻擋目前 Cyder 0.10.1；若涉及 Wine engine，工作應移至 sibling checkout |

## 1. Release 與產品主線

### 現況

- 目標版本為 **Cyder 0.10.1**，目前以 test channel 驗證。
- Engine pin 為 `CX26.3.0-W11-Cyder011`。
- MapleStory WZ adaptive cache 只處理唯讀 `.wz` 小讀取；正式 engine 不含 ring／summary／timeline／mmap／prewarm 診斷 patch，Cyder 預設開啟並可在進階設定關閉。
- DXMT／D3DMetal runtime 已接上 ensure、capability gate、設定與 launch path；MapleStory.exe／Maplestory_Classic.exe 在 default 下於 macOS 15+ 自動選 DXMT，舊版選 DXVK。
- 設定套用、單一選單列 instance、session 狀態與診斷 log 已有實作。
- 目前 release note 明確保留的缺口是：DXMT、Steam 與反作弊程序的實際啟動、
  離場、長跑與背景程序清理。

### 為什麼重要

圖形 backend 已進入產品 UI，不代表每個遊戲都已相容。若沒有用相同 engine artifact
完成實機回歸，使用者看到的是「可選」而不是「已驗證」；尤其 DXMT 要求 macOS 15+、
D3DMetal 要求 macOS 14+，不能只依編譯或 payload 存在判定成功。

### 下一個完成條件（P0）

- 以 `Cyder011` test artifact 實測 BlueCG、Steam、台版 MapleStory、MapleStory Classic，
  覆蓋啟動、畫面、輸入、長跑、正常退出與異常退出。
- 對 DXMT、D3DMetal 各保留一輪可追溯的 engine／macOS／遊戲／設定紀錄。
- 在 release checklist 中把「視窗建立」與「畫面真的不是黑屏」分開驗收；後者需要人工看畫面。

參考：[0.10.1 test release note](releases/v0.10.1.md)、[0.10.0 release note](releases/v0.10.0.md)、[圖形 backend 文件](cyder-graphics-backends.zh-TW.md)。

## 2. 執行中的程序管理

### 已完成的部分

| 能力 | 現況 |
|---|---|
| 多個 Cyder native instance | 同一 bundle／support root 由 primary instance 統一處理，避免多個選單列 icon |
| Launch request relay | EXE、動態 argv、Finder open event 可轉送到 primary |
| Lifecycle sidecar | 每次啟動有 session／operation 記錄，可回報啟動與退出狀態 |
| 選單列狀態 | 能顯示啟動中、執行中、背景等待等較粗粒度狀態 |
| 最後排空 | 仍以 prefix-level `wineserver -w` 作為後備，不再把它當成精準的 per-game 結束判斷 |

### 尚未完成的部分

目前沒有正式的 Wine 內 hidden Win32 monitor，因此還不能可靠回答：

- `steam.exe` 結束後，`steamwebhelper.exe` 是否仍屬於 Steam；
- MapleStory 主程序結束後，`grap-core64.aes`、`grap-communicator`、`NGService` 是否仍存活；
- 同一個 shared prefix 同時跑 Steam 與楓之谷時，哪一組程序可以先從 UI 消失；
- 某個 helper reparent 或 PID 重用後，是否會被誤算到另一個遊戲。

### 目標方案與驗收（0.11.0）

以 `LaunchGroup` 綁定 root executable、已觀察 PID 歷史、parent tree、foreground PID 與
每次啟動 sidecar：

1. monitor 只追蹤該次啟動可歸屬的 root／子孫，不用全 prefix 是否還有 client 代替。
2. root 結束但 helper 尚在時，UI 顯示「背景執行」，不立刻刪除 session。
3. 無法歸屬的程序顯示為同 prefix 的其他程序，不猜測所屬遊戲。
4. 所有 LaunchGroup 結束後 monitor 先退出，再由 `wineserver -w` 做最後排空，避免 monitor 自己讓 wineserver 永遠不空。
5. 特別驗收 Steam helper、MapleStory Classic GRAP／NGS、同 prefix 多遊戲、PID 重用與 monitor crash。

這是 0.11.0 規劃，0.10.1 不納入。設計文件目前標記為「設計記錄，尚未實作」：[Cyder Session 與 Windows 程序監控設計](cyder-session-process-monitoring.zh-TW.md)。

## 3. 台版 MapleStory OEM 新楓之谷移植

### 現況分層

| 層級 | 狀態 | 證據／限制 |
|---|---|---|
| OEM25 baseline | 🟢 已驗證 | OEM 25.0.1.38865、乾淨 win10_64 prefix、台版 V280，曾完成登入並實玩 |
| OEM 特別版整合 | 🟢 已有腳本 | `scripts/create-cyder-maplestory-oem-app.sh` 與 OEM bootstrap；不把 OTP／帳號資料納入本 repo |
| CX26 第一層 port | 🟡 已編譯／lifecycle smoke | `winemac`、WineD3D texture、`rawaudioparse` patch 可 dry-run／編譯，無 OTP lifecycle 已通 |
| CX26 D3D11／G 組 | 🟡 實驗引擎 | `ClearView`、`OpenSharedResource`、shared texture、full-clear、dbghelp guard 已有實驗 patch |
| CX26 完整可玩 | ⚪ 尚未關閉 | 有效 OTP 後的人工畫面、角色／地圖、滑鼠／UI、20 分鐘實玩仍是 gate |

### 已知必要契約

- OEM baseline 需要與版本一致的 OEM engine、乾淨 prefix、`zh_TW.UTF-8`／CP950、
  `RAW_AUDIO_PARSE=1`、EXE 所在目錄為 working directory、有效 OTP 與正確 `ServiceAccountID`。
- 預編譯 OEM binary 可從 Documents 的 `Z:` 執行；自行編譯的 CX26 port 目前以
  `C:\MapleTest`／APFS clone 作為較可靠的驗證路徑。
- CX26 forward-port 的進世界必要集合目前記錄為：OEM MoltenVK、dbghelp guard、
  kernelbase `.tmp`／`.msf`、整包 G（shared-texture + full-clear）及 `C:\MapleTest`。
- Beanfun 登入／OTP 由外部 CitrusGate 負責；本專案只消費 argv，不保存 Cookie／OTP。

### 為什麼重要

目前「OEM25 可玩」與「Cyder 自己維護的 CX26 engine 可玩」是兩個不同承諾。若未完成
CX26 的畫面與反作弊長跑驗收，不能把實驗 patch 或 `maplestory1` artifact 當成正式發布
引擎；但若只依賴 OEM binary，長期會受外部 runtime、授權與版本封裝限制。

### 下一步（P0）

- 固定相同遊戲目錄、prefix、MoltenVK 與 OTP，逐組只替換一個 patch／DLL。
- 完成有效 OTP → 進角色／地圖 → 滑鼠／UI／renderer → 至少 20 分鐘 → 正常退出的人工驗收。
- 同時記錄 `BlackCipher`／NGS／DwarfAxe／`CrashReportClient` 的 lifecycle，確認不是只看到視窗。
- 任何 Wine／wineserver／ntdll／engine build 或 pack 工作，移至 sibling `cyder-wine-engine`，
  並遵守該 repo 的 `AGENTS.md` 與 incremental build 文件；本 repo 保留 app 整合、patch 契約與驗證紀錄。

參考：[OEM 成功基線](games/maplestory/oem25-tw-success-baseline.md)、[OEM engine 差異](games/maplestory/oem-engine-differences.md)、[MapleStoryPort ↔ CX26](games/maplestory/maplestoryport-cx26-port.md)。

## 4. Directory query bug／MapleStory Classic 離場 livelock

### 現況

症狀是遊戲離開後主畫面可能已結束，但 `grap-core64.aes` 與 wineserver 仍高 CPU。取樣顯示
熱路徑為：

```text
grap-core64.aes
  NtQueryDirectoryObject(index=0, single-entry)
    → Wine server get_directory_entries
      → 同一 HID／device-interface 目錄反覆查詢
```

- **Cyder008**：已出貨 wineserver teardown soft-guard，降低強制結束時的 SEGV 風險。
- **Cyder009／0.9.5**：對 `NtQueryDirectoryObject` 使用 `optnone`，已實測可消除這一輪
  `-O2` codegen heisenbug 造成的離場 busy-loop。
- 這是 **bandage，不是語意修復**：尚未證明真正根因是在 ntdll marshalling、HID／`\??`
  目錄內容差異、NGS 外層狀態或多者組合。
- 目前 Cyder 仍沒有依遊戲追蹤 GRAP／NGS、離場逾時只清本輪程序、或啟動前殘留檢查的完整產品路徑。

### 為什麼是 P0

這不只是 log 噪音：會留下高 CPU 的背景程序、消耗電量、污染下一次 NGS-X 初始化，並讓
「關閉遊戲」與「Cyder session 已結束」不一致。粗暴地對整瓶執行 `wineserver -k` 也可能
影響同 prefix 的其他遊戲。

### 收斂策略

1. 短期：保留 QDO bandage，release 中明確標示它不是根因修復。
2. **0.11.0 產品層**：完成 LaunchGroup monitor、啟動前殘留提示、grace → TERM → 必要時 KILL 的
   **本輪 GRAP／NGS PID 樹**清理；不要直接修改遊戲檔案或繞過防作弊。
3. 引擎層：再以 Windows／Wine HID directory enumeration 對照確認 QDO 語意與 `VID_845E`
   symlink 行為；必要的 engine patch 在 sibling repo 完成。

參考：[GRAP／NGS-X 盤點](games/maplestory/classic-grap-ngs-x.md)、[grap-core64 residual analysis](games/maplestory/grap-core64-residual-process-analysis.md)。

## 5. 每遊戲客制設定：目前能力與邊界

### 已支援的 per-game override

| 設定 | 現況 | 注意事項 |
|---|---|---|
| 環境變數 | 🟢 | 以 `KEY=value` 儲存，啟動時合併到該 EXE |
| 命令列參數 | 🟢 | 保存為 argv；Finder／`open --args` 的動態 argv 可取代本次保存參數 |
| 高解析度 | 🟢 | 該遊戲開啟時強制 Retina + 192 DPI；關閉則跟隨全域，不另設 per-game DPI |
| 圖形 backend | 🟢 | 可跟隨全域或指定 D3DMetal、DXMT、DXVK、WineD3D；依 OS／payload fail-closed |
| 字體 | 🟢 | 可選擇自訂細明體／宋體取代與平滑；關閉時跟隨全域 |
| MSync／ESync | 🟠 global-only | 目前是 session／Wine 執行選項，不在遊戲設定頁個別覆寫 |
| 能源模式 | 🟠 global-only／啟動契約 | `standard`／`energySaving` 會影響啟動優先權；不和 per-game UI 混在一起 |
| 獨立 bottle | 🟡 另一路徑 | Cyder profile 不等於獨立 bottle；需要真正隔離時使用 CyderBits／獨立 bottle workflow |

### 為什麼要保留這個邊界

Retina、DPI、字體與部分 registry 是共用 wineserver／bottle 狀態，無法假裝以
`AppDefaults` 真正隔離到單一 EXE；同一 shared prefix 同時跑多個遊戲時，這些 session-level
值不能在遊戲之間即時切換。把 MSync／ESync 或 DPI 顯示成 per-game 可獨立切換，會造成設定
看似保存、實際被下一個 Wine session 覆寫的假功能。

### 建議的遊戲設定基線

| 遊戲 | 建議客制設定／依賴 | 現況與重要性 |
|---|---|---|
| BlueCG | DirectDraw／GDI、現行 A6 same-view backing；MIDI 先記錄 log | 主要驗證基準；resize 已解決，`dmsynth underrun` 根因未定 |
| 皮卡丘打排球 | MSync／ESync 關閉；runtime 實體路徑不可含空白 | 已知 workaround；適合用來守住 loader／sync 回歸 |
| 台版新楓之谷 V280 | OEM engine／clean prefix、CP950、`RAW_AUDIO_PARSE=1`、EXE cwd、CitrusGate OTP | OEM25 已實玩；CX26 port 尚未完成正式畫面 gate |
| 新楓之谷 Classic | MSync + DXVK 或 D3DMetal；追蹤 GRAP／NGS 程序 | 可玩但離場 livelock／殘留程序是 P0 |
| Steam | CompatDB Steam rule、`-system-composer`、`-no-cef-sandbox`；helper 追加 no-sandbox／disable-gpu | backend 已整合；helper reparent 仍需 monitor 驗收 |
| 大富翁 4 | 遊戲目錄放置 `cnc-ddraw` | 原生黑畫面；屬外部 renderer workaround |
| 越南大戰／暗黑破壞神 2 | Retina Mode 關閉 | 可玩；主要是顯示相容性設定 |
| 魔獸爭霸 3 | argv 加 `-nativefullscr` | 可玩；屬固定啟動參數 |
| 小朋友齊打交 2 | 1.9c 直接跑；2.0a 需 `vcrun2005 wmp9 quartz devenum vb6run` | 依賴安裝會影響 shared prefix，應在測試時記錄 prefix 狀態 |
| 洛克人 X3／X4／X5 | X3／X4 忽略 DirectX 初始化提示；X5 接受左上角縮放 | 可玩但有已知 UI／畫面瑕疵 |
| 世紀帝國 2 | 無特殊參數 | 可玩；約每 5 秒 micro-stutter，根因未關閉 |
| 爆爆王 | 無特殊依賴 | 文件記錄可玩；台灣服務營運時程屬外部風險 |

完整矩陣：[docs/games/compatibility-matrix.md](games/compatibility-matrix.md)。

## 6. 已知錯誤與風險登錄

| ID | 問題 | 影響 | 狀態 | 優先 |
|---|---|---|---|---:|
| BUG-01 | Classic 離場 QDO／directory query livelock | 高 CPU、grap／wineserver 殘留、可能污染下次啟動 | Cyder009 bandage；根因與產品清理未完成 | P0 |
| BUG-02 | Steam／多程序的 session 歸屬過於保守 | 主程序退出後 UI 可能一直顯示背景等待，或難以分辨不同遊戲 | 0.10.1 保留 sidecar + `wineserver -w` 後備；LaunchGroup monitor 排定 0.11.0 | P1／0.11.0 |
| BUG-03 | CX26 MapleStory port 曾有 D3D11 feature-level 退出／黑畫面 | 不能以「視窗存在」當作可玩；會直接阻擋 OEM 移植發布 | MoltenVK capability 問題已定位；G 組 patch 有實驗驗證，人工地圖驗收未完成 | P0 |
| BUG-04 | BlueCG `dmsynth underrun` | 可能是音效雜訊，也可能是未量測的音效問題 | 曾觀察；尚無聽感／失敗關聯證據 | P2 |
| BUG-05 | 含空白的 Wine engine 實體路徑 | 皮卡丘 demo 附近可能 page fault；`WINESERVER` 不一致也會放大問題 | 正式 runtime 放在 `~/.cyder/runtime/Engines/wine-x86_64` workaround | P1 |
| BUG-06 | 老遊戲顯示／啟動瑕疵 | 黑畫面、錯誤提示、左上角縮放或固定頓挫 | 已有逐遊戲 workaround；尚未全部轉成自動 profile／回歸測試 | P1 |

## 7. 待開發與建議順序

| 順序 | 工作 | 完成定義 |
|---:|---|---|
| 1 | **P0：0.10.1 實機 release regression** | DXMT／Steam／台版 MapleStory／Classic 完成啟動、畫面、長跑、退出紀錄 |
| 2 | **P1／0.11.0：LaunchGroup process monitor** | Steam helper、GRAP／NGS、同 prefix 多遊戲、reparent／PID reuse／monitor crash 均有測試 |
| 3 | **P0：MapleStory CX26 port** | 有效 OTP 進地圖，畫面／滑鼠／UI 正常，BlackCipher 存活，20 分鐘後正常退出 |
| 4 | **P0：Classic 殘留清理** | 只清本輪可歸屬程序；啟動前能提示殘留；不以整瓶 kill 影響其他遊戲 |
| 5 | **P1：遊戲 profile 回歸化** | 將相容性矩陣中的固定 workaround 映射成可測試的 profile／CompatDB 規則，並保留人工覆寫 |
| 6 | **P1：directory／loader path diagnostic** | 含空白／無空白 engine、同一 wineserver、prefix 與 payload 來源都有明確錯誤提示與測試 |
| 7 | **P2：Wine Engine 瘦身** | 依量測再決定 configure profile、symbols、media stack 與 artifact 交付方式 |
| 8 | **P2：CyderBits Bash 化與 bottle 重構** | game app 不再依賴完整 Python runtime；隔離 bottle／APFS CoW 有可回復升級路徑 |
| 9 | **P2：DXVK 2 graphics backend** | MoltenVK／Metal 具備真實 robustness、null descriptor 與 D3D11 transform feedback 語意後，重新評估 payload、CompatDB 與 UI |

## 8. 開發時的判讀規則

- 「可啟動」不等於「可玩」：至少分成 process lifecycle、renderer、畫面人工驗收、長跑、正常退出。
- 「workaround 已有效」不等於「根因已修復」：尤其是 QDO `optnone`、含空白 runtime、
  `cnc-ddraw` 與逐遊戲字體／Retina 設定。
- 不要把 MapleStory OEM25 的結果外推到 Classic，也不要把 Classic 的 QDO hang 當成 OEM25
  的同一個 wineserver 問題；兩者引擎、反作弊與 hang 形狀不同。
- 任何涉及 Wine engine build、wineserver、ntdll、host `make` 或 engine pack 的工作，
  先切到 `cyder-wine-engine` sibling repo；ogom 只維護 app、recipe、CompatDB、整合與驗證。
- 新增狀態時，必須附上：測試日期、engine label、macOS 版本、遊戲版本、prefix／runtime
  路徑、設定與結果。沒有這些欄位，只能標成「待驗證」。

## 相關入口

- [Cyder 使用指南](cyder.md)
- [Cyder 0.10.1 test release note](releases/v0.10.1.md)
- [Cyder 0.10.0 release note](releases/v0.10.0.md)
- [遊戲相容性矩陣](games/compatibility-matrix.md)
- [Session 與 Windows 程序監控設計](cyder-session-process-monitoring.zh-TW.md)
- [MapleStory 文件索引](games/maplestory/README.md)
- [圖形 runtime pipeline](cyder-graphics-runtime-pipeline.zh-TW.md)
