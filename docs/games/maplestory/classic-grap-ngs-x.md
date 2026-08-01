# 經典版 GRAP／NGS-X 插件盤點（初步）

最後更新：2026-07-31  
遊戲路徑範例：`…/Maplestory_Classic_Data/Plugins/x86_64/`  
相關：

- 離開遊戲 livelock：[`debug/hang-20260731-182944-leave-game/analysis.txt`](../../../debug/hang-20260731-182944-leave-game/analysis.txt)
- wineserver／離場總覽：[`maplestory-classic-wineserver-hang.md`](../../maplestory-classic-wineserver-hang.md) §2.5
- 舊版（V280／OEM）BlackCipher lifecycle：[`launch-lifecycle-and-anticheat.md`](launch-lifecycle-and-anticheat.md)

**範圍：** 靜態檔案盤點、字串／PDB、與 Cyder hang 取樣對照。  
**不做：** 停用、修改、繞過防作弊；不逆向還原協定。

## 1. 摘要

《新楓之谷：經典版》的防作弊是 **Nexon NGS-X（產品字串）／GRAP（模組命名空間）**，
以 Unity native plugin `grap64.dll` 為進程內入口，再拉起獨立 process
`grap-core64.aes` 等。副檔名 `.aes` **仍是一般 PE**（`file(1)` 顯示 PE32／PE32+），
不是加密容器。

與 OEM 台版 V280 文件中的 `BlackCipher64.aes` **不是同一套檔名樹**，但同屬 Nexon NGS
家族：`NGService.exe` 字串仍出現 `Service_BlackCipher` 與 Dock／視窗名
**「Nexon Game Security」**。

離場卡住時高 CPU 的是 **`grap-core64.aes`**（約 55%），不是 `grap64.dll`。
core 忙於 `NtQueryDirectoryObject` → wineserver `req_get_directory_entries`；
主遊戲多半在 wait。詳見 hang analysis。

## 2. 目錄與元件

路徑（相對遊戲 Data）：

```text
Plugins/x86_64/
  grap64.dll                 # Unity plugin／介面（進程內）
  grap/
    grap-core64.aes          # 主掃描 process（PE32+ EXE）
    grap-communicator64.aes  # 網路／IPC 模組（PE32+）
    grap-updater.aes         # 更新器（PE32 x86）
    NGService.exe            # Windows 服務（PE32 x86）
    NGService_Install.bat    # NGService.exe -install
    NGService_Uninstall.bat  # NGService.exe -uninstall
    BlackCat64.sys           # 核心驅動（macOS／Wine 無法載入）
    *.log                    # 二進位／加密，不可當明文 debug 讀
```

| 檔案 | 約略大小 | 架構 | 證據要點 |
|------|----------|------|----------|
| `grap64.dll` | 13M | x64 DLL | PDB `grap-client-pc-release-1.5.0.0\…\grap-interface\…\grap64.pdb`；`GRAP::Interface::Patcher`；`CreateProcessW`／mutex／pipe |
| `grap-core64.aes` | 38M | x64 EXE | PDB `…\grap-core\…\grap-core64.pdb`；`ProcessManager`／`ModuleManager`／`DriverManager`；`EnumProcesses`、`CreateToolhelp32Snapshot` |
| `grap-communicator64.aes` | 37M | x64 | OpenSSL／curl／socket；NGS-X 錯誤字串；亦含「Nexon Game Security」 |
| `grap-updater.aes` | 19M | x86 EXE | 字串引用 `grap-communicator(64).aes` |
| `NGService.exe` | 4.1M | x86 | PDB `NGS_04\…\NGService.pdb`；`[SERVICE] Service_BlackCipher::…`；標題 **Nexon Game Security** |
| `BlackCat64.sys` | 3.9M | x64 driver | PDB `NGS-X\…\BlackCat64.pdb`；字串 `NGS Driver`／`BlackCat` |

簽章主體：NEXON Korea Corporation（DigiCert code signing）。

## 3. 推得的啟動關係（推論 + 字串）

```text
Maplestory_Classic.exe (Unity / il2cpp)
    │  載入 Plugins/x86_64/grap64.dll
    │  （metadata 可見 grap64.dll／「grap64.dll not found」類字串）
    ▼
grap64.dll  (NGS-X Init / Run)
    ├── 期望 %ws\grap\grap-updater.aes
    ├── 可能啟動 / 連線 grap-updater、grap-communicator
    ├── 嘗試 NGService（失敗字串：Failed to launch NGService.exe；
    │     安裝提示：執行 grap/NGService_Install.bat）
    └── 拉起 grap-core64.aes（遊玩期常駐）
            │
            ├── Process / Module / Driver 盤點
            ├── 嘗試與 BlackCat 驅動互動（Mac 上必失敗 → 使用者態降級，假設）
            └── 離場時可持續 NtQueryDirectoryObject 掃描（已取樣證實忙迴圈）
```

使用者可見錯誤字串（UTF-16，出自 `grap64.dll`／communicator）包括：

- `NGS-X Init is not Called!!!` / `NGS-X Run is not Called!!!`
- `Failed to initialize NGS-X on your system…`
- `Please add an exception for NGS-X (grap-core.aes or grap-core64.aes)…`
- `Service installation has failed. Please run the 'grap/NGService_Install.bat'…`
- `NGS-X reset failed. Please run the game as an administrator…`

這些說明產品內部正式名是 **NGS-X**，檔案／C++ namespace 多用 **GRAP**。

### 3.1 離場 hang 現場命令列

`debug/hang-20260731-182944`：

```text
…/grap/grap-core64.aes 2982 32 000000000000068C
```

參數語意未公開驗證；第一個十進位參數常見於「父 PID／工作階段 token」類用法，
**僅作觀察標記**。重點是：**離場時 core 仍在且高 CPU**，與主遊戲 wait 同時存在。

## 4. 與舊版 BlackCipher 文件的差異

| | OEM／V280（既有文件） | 經典版（本盤點） |
|--|----------------------|------------------|
| 進程內／交換 | `BlackXchg.aes` 等 | `grap64.dll` |
| 常駐掃描 | `BlackCipher64.aes` | **`grap-core64.aes`** |
| 服務 | `ProgramData\Nexon\NGS\NGService.exe`（常見） | 遊戲目錄 `Plugins/…/grap/NGService.exe` |
| 驅動 | （視版本） | **`BlackCat64.sys`（Mac 無效）** |
| Dock 名 | Nexon Game Security／BlackCipher | **Nexon Game Security**（NGService／communicator 字串） |

[`launch-lifecycle-and-anticheat.md`](launch-lifecycle-and-anticheat.md) 的 session 收斂原則
**仍然適用**（以 process tree 為單位、grace → TERM → 必要時 KILL、啟動前清殘留），
但經典版的 PID 名稱應改追 **grap-***／**NGService**，不要只 `pgrep BlackCipher`。

## 5. 對 Cyder／Wine 的含義

1. **不要改遊戲目錄裡的 grap 檔**當「修掛」手段。
2. **BlackCat64.sys 無法在 macOS 載入** → 可能迫使 NGS-X 走純使用者態路徑；是否因此讓
   離場 `NtQueryDirectoryObject` 更兇，**尚未證明**，但是合理下一假設。
3. **離開卡住／Dock 殘留** 屬同一 lifecycle 問題：主程式結束或卡死後，
   `grap-core`／`NGService`／communicator 未收斂。
4. **強制結束 session 時** 曾踩 wineserver teardown SEGV
   （`pipe_end_disconnect`／`add_completion`）。**Cyder008 候選**已含對應 soft-guard
   （引擎 `docs/wineserver-teardown-hardening-cyder008.md`）；產品 session 清理仍應並行。
5. 可玩設定仍見 [`maplestory-classic-wineserver-hang.md`](../../maplestory-classic-wineserver-hang.md)：
   建議 **MSync + DXVK 或 D3DMetal**；離場 livelock 在 sync 關／開皆曾出現。

## 6. 建議處理（產品優先）

| 優先 | 項目 | 說明 |
|------|------|------|
| P0 | Session PID 樹 | 啟動後追蹤 `Maplestory_Classic.exe`、`grap-core64.aes`、`grap-communicator*`、`grap-updater*`、`NGService.exe`、UnityCrashHandler |
| P0 | 離開逾時清理 | 遊戲內結束後若 N 秒仍卡（或主程式已退、helper 仍在），grace 後 TERM→KILL **本輪** PID |
| P0 | 啟動前殘留檢查 | 發現上次 grap／NGS 殘留則提示或一鍵清理（對齊 Nexon 官方「殘留害下次 init」） |
| P1 | UX | 「結束遊戲殘留程序」；Dock 上 Nexon Game Security 發呆時可對應同一清理 |
| P1 | 引擎 | teardown SEGV soft-guard → **Cyder008**（已入引擎 tree；待 pack／pin） |
| P2 | 診斷 | 一輪 `WINEDEBUG=+process,+loaddll`（或 Cyder「只記錄錯誤」以上）對照誰 spawn core／NGService、BlackCat 載入失敗字樣 |
| 不做 | 卸載／patch GRAP | 超出相容性範圍 |

### 6.1 現有 Cyder 能力（缺口）

- 啟動已帶 `--wait-children`（避免主程式早退就拆 session）——對「主程式還在、離場卡死」**不夠**。
- 設定 UI 有對整瓶執行 `wineserver -k` 的停止手段——能清殘留，但是**整 bottle 粗暴結束**；
  Cyder007 曾在此路徑 SIGSEGV，Cyder008 候選加固 teardown。仍不是「只清 grap／NGS」的產品路徑。
- **尚無**依遊戲 session 追蹤 grap-core／NGService、離場逾時自動清理、或啟動前殘留檢查。

## 7. 後續驗證清單

- [x] 引擎 teardown soft-guard（async／pipe／completion）→ Cyder008 候選（2026-07-31）
- [x] **2026-07-31 ~20:05**：MSync+DXVK 離場 livelock 再重現；live wineserver **已含**
      Cyder008 markers（`debug/hang-20260731-200537`）→ 證明 livelock ≠ 缺 patch
- [ ] 開啟適度 Wine process／loaddll log，截一輪從進遊戲到正常離開（或卡住）的 spawn 序
- [ ] 確認 Wine 下是否出現 `BlackCat`／`.sys`／service install 相關失敗（不要求修驅動）
- [ ] 對照更多後端／sync 的離場：directory 風暴是否一律出現（已見 sync-off+D3DMetal 與 MSync+DXVK）
- [ ] Cyder session 清理 prototype：逾時後只殺本 bottle／本輪 grap 樹，驗證下次啟動 NGS-X 是否較穩
- [ ] （可選）macdrv 是否把 NGService 推成 Dock app；能否在不破壞 AC 的前提下減少前景污染
- [ ] Cyder008 pack + App pin 後，重複「離開／強制停止 Wine」並確認 diag 無 teardown SIGSEGV

## 8. 取樣指令（重現離場 hang 時）

```bash
# 卡住且 BGM 仍在時
bash debug/capture-wine-hang.sh 8
# 讀
#   debug/hang-*/summary.txt
#   bottles/.../cyder-wineserver-diag.log
```

重點看：`grap-core64.aes` CPU、`NtQueryDirectoryObject`、wineserver `req_get_directory_entries`。
