# 新楓之谷經典版：商城／進場凍結與 wineserver 無聲死亡

更新日期：2026-07-31  
引擎：`CX26.3.0-W11-Cyder007`（runtime `~/.cyder/runtime/Engines/wine-x86_64`）  
相關：frame-walk／SEH 修補見 [maplestory-classic-cx26-frame-walk-debug.md](./maplestory-classic-cx26-frame-walk-debug.md)

## 1. 摘要

在 NTDLL frame-walk 修補之後，遊戲已能登入並進地圖，但仍會在下列操作間歇凍結：

- 進出商城；
- 選角後按「開始遊戲」；
- 同一組設定下，卡點可能不同。

凍結時的共同現象是：**wineserver 程序消失，遊戲與 helper（services／rpcss／grap 等）仍在，CPU 接近 0%。**  
畫面卡住不是 busy loop，而是所有 client 永久阻塞在等待 wineserver 回覆。

目前實測**唯一穩定組合**是 **MSync + DXVK**（可反覆進出商城 5–6 次以上）。其餘 sync × 圖形後端組合均曾出現 wineserver 死亡或等價僵屍狀態。

CompatDB 規則 `game.maplestory-classic.dxvk`：當全域圖形為**預設**（`.default`，不強制後端）時，
`Maplestory_Classic.exe` 會自動選 DXVK；若全域改為 **自動**／D3DMetal／DXVK／WineD3D，則以全域（或遊戲覆寫）為準。

注意：DXVK 長跑另有 **Mach Ports 洩漏**（與本文件 wineserver 死亡不同根因），見
[maplestory-classic-dxvk-ports-leak.md](./maplestory-classic-dxvk-ports-leak.md)。

## 2. 症狀與機制（已確認）

### 2.1 現場證據

凍結當下以 `debug/capture-wine-hang.sh` 取樣（例：`debug/hang-20260731-011408`）：

- `ps` 全系統無 `wineserver`；遊戲啟動時附近的 PID 空缺與 server 目錄一致。
- 每個 Wine client 持有的 wineserver unix socket 對端皆為 `->(none)`。
- prefix 對應的 `/tmp/.wine-<uid>/server-<dev>-<ino>/` **沒有 `socket` 檔**，`lock` 亦無持有者。
- 遊戲主程序大量 FIFO／pipe（每執行緒一組 `wait_fd`）仍開著。

### 2.2 為什麼 client 「凍住」而不是立刻崩潰

Wine 每支執行緒的 select 等待讀的是 `wait_fd[0]`，而其**寫端 `wait_fd[1]` 由 client 自己保留**（見 `dlls/ntdll/unix/server.c` 的 `server_pipe`／`wait_select_reply`）。因此 wineserver 死後：

- `read(wait_fd[0])` **不會**收到 EOF；
- 已停在等待裡的執行緒永遠阻塞；
- 只有之後還要再 `write` request 的路徑才會看到 `EPIPE`。

這解釋了「關窗／畫面死了，但程序還在、wineserver 卻不在」。

### 2.3 wineserver 如何「安靜」結束

完整 launch log 中**沒有**：

- `Assertion failed: (poll_users[user] == fd)`；
- `wineserver crashed, please enable coredumps...`；
- `stale poll slot`（Cyder poll-slot guard 診斷字串）。

同時 macOS 當夜也沒有對應的 wineserver crash／jetsam 報告，但 server 目錄的 `socket` 已被 unlink（`socket_cleanup` atexit）。

原始碼上，這種「無訊息 + 跑完 atexit」與下列路徑相符：

| 路徑 | 行為 |
|------|------|
| SIGTERM | `sigterm_callback` → `flush_registry(); exit(1);`（無日誌） |
| SIGINT | `sigint_callback` → `shutdown_master_socket()`（無日誌） |
| 自行收工 | `running_processes` 歸零等條件 → `close_master_socket` → `active_users` 歸零 → `main_loop` 返回 |

**尚未二分**究竟是「被信號終止」還是「誤以為沒有 client 而自行退出」。下一輪引擎診斷應印出信號 `si_pid` 與 `main_loop` 退出時的 `active_users`／`running_processes`。

### 2.4 與早期 assertion 凍結的關係

較早的 log（`Cyder-last-game.log`）曾出現：

```text
wineserver: server/fd.c:…: set_fd_events: Assertion `(poll_users[user] == fd)' failed.
```

那會讓 wineserver **abort**，client 同樣永久等待。Cyder 引擎專案因此加入：

- `cyder-wineserver-sock-reselect-pseudo-fd.patch`：未初始化 socket（pseudo-fd）不要 `sock_reselect` → `set_fd_events`；
- `cyder-wineserver-poll-slot-guard.patch`：`set_fd_events` 遇不一致 poll slot 時改印診斷並跳過，避免 assert abort。

後續多輪重現中，**soft-guard 字串未再出現**，但 wineserver 仍會無聲消失。因此：

- poll-slot／pseudo-fd 修補可能消掉「大聲 assert」那一類；
- **不能**證明已修掉根因；soft-guard 也可能把同一類不一致變成更難觀察的退出形狀。
- `remove_poll_user()` 仍保留 `assert(poll_users[user] == fd)`，尚未一併處理。

假設（未證實）：macOS kqueue 路徑以 `udata` 帶 poll slot、以 `unix_fd` 做 `EV_DELETE`；fd 重用／註銷交錯可能誤送 `POLLHUP` 到 client `msg_fd`，導致 `running_processes` 誤判歸零。可用「強制 fallback 到 `poll()`」做對照實驗驗證。

### 2.5 離開遊戲卡住（wineserver 仍在、高 CPU livelock）

另一類終態：**遊戲內結束／離開後畫面卡死，BGM 仍播，wineserver 與 `grap-core64.aes` 各吃約 50% CPU，Maple 主程序低 CPU 等待。**  
這與「wineserver 消失」不同——server **還活著**，但收工路徑走不完。

2026-07-31 晚間在 **Cyder 0.9.0 / Cyder007**、**D3DMetal、同步關閉** 重現並採樣（BGM 仍在）：

| 程序 | CPU | 取樣重點 |
|------|-----|----------|
| wineserver | ~47% | `main_loop` 忙於處理請求；可辨識符號為 `req_get_directory_entries` |
| grap-core64.aes | ~55% | `NtQueryDirectoryObject` → `wine_server_call` 忙迴圈 |
| Maplestory_Classic.exe | ~3% | 多半 `NtWaitForSingleObject`／`NtWaitForAlertByThreadId` |

完整分析與 sample：`debug/hang-20260731-182944-leave-game/analysis.txt`  
（同型：`hang-20260731-154434`、`hang-20260731-161329`）。

GRAP／NGS-X 檔案樹與產品含義見
[`docs/games/maplestory/classic-grap-ngs-x.md`](./games/maplestory/classic-grap-ngs-x.md)
（`grap64.dll` 進程內入口；高 CPU 的是獨立 process `grap-core64.aes`；Dock 名
「Nexon Game Security」來自 NGService／communicator）。

強制結束時 diag 仍見 teardown SEGV：本次 `pipe_end_disconnect`；稍早同 bottle 為 `add_completion` ← `release_job_process`。離場 hang 本身是 **GRAP 目錄列舉 ↔ wineserver 請求風暴**，不是這兩次崩潰。

**2026-07-31 晚間引擎加固 → 下一版 `Cyder008`：** `cyder-wine-engine` 已提交
`async_terminate` null-fd、`pipe_end_disconnect`→`free_async_queue`／`async_clear_weak_fd`、
`add_completion` 無效 port 防護（引擎文件
`docs/wineserver-teardown-hardening-cyder008.md`）。本機 runtime 已換過修補後的
wineserver；**正式 GA 仍為 Cyder007**，待 `pack-engine-artifact` 產出並 pin 後才算進 App。

同晚稍早實玩離開曾**未卡住**，但離場 hang 本就不穩定重現，**不能**據此宣告 livelock 已解。

**2026-07-31 ~20:05 再重現（已確認 patch 在 live wineserver）：**

| 項目 | 值 |
|------|-----|
| 設定 | **MSync + DXVK**（可玩基線組合仍可踩 livelock） |
| wineserver | ~48% CPU；`req_get_directory_entries` |
| grap-core64.aes | ~54% CPU；`NtQueryDirectoryObject` |
| 二進位 | runtime wineserver **含** Cyder008 teardown 字串／`async_clear_weak_fd`（與 `cyder-wine-engine/install` SHA 相同）；App 封裝標籤仍為 Cyder007 |
| diag | `diag start pid=` 與 live PID 一致；**本次 hang 無新 SIGSEGV** |

採樣與結論：`debug/hang-20260731-200537/analysis.txt`。  
→ teardown soft-guard **不能**消掉此 livelock；下一步仍是 session 清 grap／產品清理，而非重做 pipe／completion patch。

## 3. Sync × 圖形後端實測矩陣（2026-07-31）

測試重點：進出商城、選角後開始遊戲。同一設定卡點可不固定；判定以 **wineserver 是否消失／畫面永久凍結** 為準。

| 同步 | D3DMetal | DXVK | WineD3D |
|------|----------|------|---------|
| **關閉** | 卡住 | 卡住 | 卡住；GPU 使用率飆高後關窗，程序仍在（wineserver 已不在） |
| **MSync** | 卡住 | **穩定**（進出商城 5–6 次以上通過；遊戲內 GPU 偏高；有開 60 FPS 限制） | 卡住 |
| **ESync** | 曾進出 5–6 次後遊戲內伺服器斷線並關閉（是否反作弊／過頻進出未定）；**另測第 3 次進商城即卡住且 wineserver 死亡** | 卡住 | 卡住 |

### 結論

- **唯一可玩基線：MSync + DXVK**（建議維持幀率限制 60）。
- Sync 關閉時三個後端皆失敗 → 問題重心在 **wineserver／同步路徑**，不是單一圖形後端。
- MSync 大幅降低對 wineserver `server_select` 的依賴，可解釋為何「只有 MSync+DXVK」較穩；但 MSync + D3DMetal／WineD3D 仍失敗，代表後端執行緒／呈現節奏仍可踩中死亡路徑。
- ESync **不是**可靠替代；ESync+D3DMetal 亦已確認可因 wineserver 死亡而凍住。
- 既有文件曾寫「此遊戲基線宜關閉同步、暫勿預設 MSync」——**已被本矩陣推翻**，應以本文件為準。

## 4. 診斷工具與設定（Cyder App）

### 4.1 Wine 診斷層級新增 `sync`

偏好設定「除錯 → Wine 診斷記錄」：

| 層級 | `CYDER_WINE_DIAGNOSTICS` | `WINEDEBUG` |
|------|--------------------------|-------------|
| 安靜 | `quiet` | `-all` |
| 只記錄錯誤 | `errors` | `-all,err+all,+timestamp,+pid,+tid` |
| **等待與凍結追蹤** | `sync` | `-all,err+all,+timestamp,+pid,+tid,+sync` |
| 完整堆疊追蹤 | `unwind` | `-all,+timestamp,+pid,+tid,+seh,+unwind` |

凍結類問題應優先用 `sync`，不要用 `unwind`（資料量大且改時序）。日常可玩請切回「安靜」。

實作位置：`scripts/cyder_settings.swift`、`scripts/cyder_settings_ui.swift`、`scripts/cyder-common.sh`。

### 4.2 凍結當下取樣

```bash
debug/capture-wine-hang.sh 5
```

腳本會寫入 `debug/hang-<timestamp>/`（目錄由 `.gitignore` 的 `debug/` 排除），包含：

- `ps-all.txt`：完整行程快照；
- `summary.txt`：是否偵測到 wineserver（**不在則明確標示**）；
- 各 client 的 `sample` 輸出。

注意：Rosetta 翻譯下的 PE 呼叫鏈在 `sample` 中幾乎不可讀；價值在於確認「全體阻塞／server 是否存活」。

### 4.3 已知診斷限制
- **hang-20260731-143139**：若 wineserver 死前 diag 只有 `diag start pid=`、沒有
  `SIGSEGV`／signal 行，可能是舊 binary 在 cores 允許時未安裝 SEGV logger；請確認
  runtime wineserver 已含 always-on SIGSEGV／SIGBUS 診斷後再重現。

- wineserver stderr 會進 launch log（早期 assert 訊息曾出現在同一管道），因此「log 無 wineserver 字樣」有診斷意義。
- 若 launch log 經 gzip 串流且程序僵屍未結束，末尾可能尚未 flush；結束卡住的 client 後再讀完整 `.log.gz`。
- `+sync` 量級仍可能影響時序；確認組合後請關閉診斷。

## 5. 建議後續工作

1. **產品**：MapleStory Classic／OEM 預設或明確建議 **MSync + DXVK**；修正「凍結時先關同步」對此遊戲的誤導文案。
2. **引擎診斷（已落地，待重現）**：`cyder-wine-engine` 的
   `cyder-wineserver-exit-diagnostics.patch` 已套入本機 runtime wineserver：
   - 收到 SIGTERM／SIGINT／SIGHUP／SIGQUIT 時印 `signum`、名稱、`si_pid`／`si_uid`（Apple 另有 sender `path=`）；
   - `main_loop` 返回時印 `active_users`／`nb_users` 與 `running_processes`／`user_processes`／`shutdown_stage`；
   - stale poll slot 訊息升級為 `FATAL:` 並立即 `fflush`（仍不 abort）；
   - SIGSEGV／SIGBUS 時**一律**印 `si_addr`／`si_code` 與 `backtrace()` 影格後 abort
     （不再只在 `RLIMIT_CORE==0` 時安裝 handler；否則 cores 開啟時會無聲死亡，diag
     只剩 `diag start pid=`）。另有 `atexit pid=` breadcrumb。
   **死因已確認為 SIGSEGV**（非外部 SIGTERM）：`fd_reselect_async` 在
   `fd->fd_ops == NULL` 時呼叫 vtable（`si_addr=0x58`）。引擎已加
   `cyder-wineserver-fd-reselect-async-null-ops.patch`（null-check + diag，不 abort）。
   另確認離場／`kill_process` teardown 一條：`pipe_end_disconnect` 在
   `pipe_end->fd == NULL` 時呼叫 `fd_async_wake_up`（`si_addr=0xf8`＝`wait_q`）；
   引擎已加 `cyder-wineserver-pipe-end-disconnect-null-fd.patch`。
   若仍有 SEGV，讀 diag log 的 `SIGSEGV pid=`／`frame[`／`sym[`；若只見
   `fd_reselect_async: missing ops` 或 `pipe_end_disconnect: null fd` 則為已攔截路徑。
   Soft-guard 後離場曾變 **wineserver 活著但 ~50% CPU 的 livelock**
   （`hang-20260731-154434`）：根因是 sock 換 `fd` 後 sock-local async 佇列上的
   weak `async->fd` 仍指向已釋放物件。引擎另加
   `cyder-wineserver-sock-rebind-async-fd.patch`（`sock_rebind_async_fds`／
   `async_queue_rebind_fd`，在 `accept_into_socket`／`init_socket` 釋放舊 fd
   **之前**把 weak 指標改綁到新 fd）；null-ops soft-guard 仍保留作雙保險。
   重現時請用最容易卡的組合（例如 Sync 關閉 + DXVK），診斷層級建議「只記錄錯誤」。
   卡住後先跑 `debug/capture-wine-hang.sh`，再結束遊戲；**優先讀**
   `~/Library/Application Support/Cyder/bottles/shared/cyder-wineserver-diag.log`
   （不依賴 gzip launch log）。若需 flush gzip，只結束 Wine 程序、不要 SIGKILL gzip。
3. **對照**：強制 wineserver 走 `poll()`（關閉 kqueue）後，用 Sync 關閉 + DXVK 重測。
4. **補齊**：評估 `remove_poll_user()` 的同型 assert；引擎 patch 維護於 `cyder-wine-engine` 專案。

## 6. 相關檔案

| 位置 | 說明 |
|------|------|
| `docs/maplestory-classic-cx26-frame-walk-debug.md` | 先前 NTDLL frame-walk／登入卡住紀錄 |
| `scripts/cyder_settings.swift` 等 | `sync` 診斷層級 |
| `debug/capture-wine-hang.sh` | 凍結取樣（未進版控，見 `debug/`） |
| `debug/hang-20260731-182944-leave-game/` | 0.9.0 離開遊戲 livelock（sample + `analysis.txt`；D3DMetal、sync-off） |
| `debug/hang-20260731-200537/` | 同型 livelock；**MSync+DXVK**；live wineserver 已含 Cyder008 teardown markers |
| `docs/games/maplestory/classic-grap-ngs-x.md` | 經典版 GRAP／NGS-X 插件靜態盤點與處理建議 |
| `cyder-wine-engine`：`patches/cyder-wineserver-*.patch` | pseudo-fd／poll-slot／fd_reselect／sock-rebind／pipe_end null-fd 修補與測試 |

## 7. 一句話結論

商城／進場凍結的共同終態是 **wineserver 無聲消失 → client 永久等在自持的 `wait_fd`**；
另有離開遊戲終態為 **wineserver 仍在、與 GRAP 陷入 `NtQueryDirectoryObject`／`req_get_directory_entries` livelock**（見 §2.5）。
**Cyder 0.9.0 / `CX26.3.0-W11-Cyder007`** 已含 soft-guard、`sock-rebind-async-fd` 與 diag
dual-write，並強制打包 DXVK／minOS ≤ 10.15。可玩建議仍為 **MSync + DXVK 或 D3DMetal**；
WineD3D 不建議。離開遊戲 livelock 仍未解。

## 8. 與 OEM-25「什麼 sync／後端都較穩」的對照

來源：`codex/maplestory-oem-special` 的
[`docs/games/maplestory/`](./games/maplestory/README.md)（已合入本樹供閱讀）與
[`patches/oem25-bisect/`](../patches/oem25-bisect/README.md)。

### 8.1 為什麼 OEM 經驗不能直接當經典版解法

| 面向 | OEM-25 正式版 | 經典版 CX26（Cyder007） |
|------|---------------|-------------------------|
| Wine 基線 | CrossOver OEM 25／Wine **10** | CrossOver 26／Wine **11** |
| 引擎一致性 | 整包同 build（wineserver／ntdll／winemac／DLL） | 正式 CX26 + Cyder patch；與 OEM binary **不可混用**（protocol 曾不一致） |
| 使用者觀察 | 同步機制與圖形後端切換較少踩雷 | 幾乎只有 **MSync+DXVK** 能反覆進出商城 |
| Hang 形狀 | 歷史主線多為黑畫面／進世界／防作弊路徑 | **wineserver 進程消失** 後 client 僵屍等待 |

OEM bisect 的「必要集」是 MoltenVK、dbghelp、kernelbase `.msf`、整包 G（ClearView／shared texture），目標是**畫面／進世界**，不是修復「server 進程無聲退出」。

### 8.2 OEM 文件裡真正跟 wineserver／同步有關的項目

文件把「同步」分成兩類，容易混淆：

1. **GPU／overlay 狀態同步**（shared-resource `finish`、ClearView 等）— D3D 正確性，不是 wineserver keep-alive。
2. **效能 workaround（減少 wineserver 往返或 scheduler 成本）**：

| 項目 | 做什麼 | Bisect 判定 | 對經典版 hang 的含義 |
|------|--------|-------------|----------------------|
| 8 KiB userspace file cache | 小檔讀取少打 wineserver | 無 OTP **非必要**（rev-Pfc） | 可能降低壓力，**未證明**能阻止 server 死亡；侵入性高 |
| 停用 `NtYieldExecution`→`sched_yield` | 避免 tight poll 一直讓出 CPU | 無 OTP **非必要** | 改排程時序；可能改變重現機率，不是 server 生命週期修補 |
| display-mode cache | 少打 `EnumDisplaySettings`／wineserver | 無 OTP **非必要** | 同上，效能向 |
| OEM `wine --wait-children` | 主程式先結束、子進程仍在時不要過早放掉 session | 產品／防作弊 lifecycle | 防的是「誤判遊戲已關」；經典版是 **server 先死、client 還在**，方向相反，但提醒要區分「正常收工」與「異常消失」 |

OEM 文件**沒有**記載等同於目前 classic 的「poll_users assert／無聲 exit／MSync 獨活」根因分析，也**沒有**把 MSync／ESync 開關當成黑畫面解法（明確寫過不是單純 CSMT／MSync）。

### 8.3 對後續實驗的建議（仍屬假設）

- 優先完成 wineserver **死因二分**（信號 `si_pid` vs `main_loop` 自行返回），再考慮移植 OEM 效能 patch。
- 若要做 A/B：單一變因試 `maplestory-cx26-no-sched-yield.patch`（改動小）；file cache 另案且需回歸。
- 勿把整包 OEM CX25 與 CX26 runtime 混接；protocol／ABI 不一致會製造假陽性。
- 參考 patch 已放在 `patches/maplestory-cx26-*.patch`，**預設不套用**。
