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

- wineserver stderr 會進 launch log（早期 assert 訊息曾出現在同一管道），因此「log 無 wineserver 字樣」有診斷意義。
- 若 launch log 經 gzip 串流且程序僵屍未結束，末尾可能尚未 flush；結束卡住的 client 後再讀完整 `.log.gz`。
- `+sync` 量級仍可能影響時序；確認組合後請關閉診斷。

## 5. 建議後續工作（尚未實作）

1. **產品**：MapleStory Classic／OEM 預設或明確建議 **MSync + DXVK**；修正「凍結時先關同步」對此遊戲的誤導文案。
2. **引擎診斷**（純輸出）：SIGTERM／SIGINT 用 `SA_SIGINFO` 印 `si_pid`；`main_loop` 返回後印 `active_users`／`running_processes`。
3. **對照**：強制 wineserver 走 `poll()`（關閉 kqueue）後，用 Sync 關閉 + DXVK 重測。
4. **Guard 策略**：在仍有 MSync+DXVK 可玩的前提下，考慮診斷組合暫將 soft-guard 改回 assert／FATAL，避免無聲死亡。
5. **補齊**：評估 `remove_poll_user()` 的同型 assert；引擎 patch 維護於 `cyder-wine-engine` 專案。

## 6. 相關檔案

| 位置 | 說明 |
|------|------|
| `docs/maplestory-classic-cx26-frame-walk-debug.md` | 先前 NTDLL frame-walk／登入卡住紀錄 |
| `scripts/cyder_settings.swift` 等 | `sync` 診斷層級 |
| `debug/capture-wine-hang.sh` | 凍結取樣（未進版控，見 `debug/`） |
| `cyder-wine-engine`：`patches/cyder-wineserver-*.patch` | pseudo-fd／poll-slot 修補與測試 |

## 7. 一句話結論

商城／進場凍結的共同終態是 **wineserver 無聲消失 → client 永久等在自持的 `wait_fd`**；目前可玩 workaround 是 **MSync + DXVK**，根因仍待信號／自行退出二分與（可能的）kqueue／poll 對照確認。
