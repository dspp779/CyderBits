# `grap-core64.aes` 遊戲退出後殘留與 Wine 高 CPU 問題分析

> 本文件專門整理 MapleStory Classic 結束後，`grap-core64.aes` 未正常退出、Wine / wineserver 長時間持續 CPU，以及 `NtQueryDirectoryObject` / `get_directory_entries` busy-loop 的分析結果。

## 1. 問題現象

MapleStory Classic 遊戲本體可正常運作並正常關閉。

執行：

```text
wine Maplestory_Classic.exe
```

遊戲主程式結束後：

- shell 已立即返回
- `Maplestory_Classic.exe` 已從 Windows process table 消失
- `grap-core64.aes` 仍持續存在
- macOS Activity Monitor 中 `wine`、`wineserver` 持續存在並消耗 CPU
- 長時間等待後情況不會自行恢復

在 CrossOver/macOS Dock 對顯示為 NGS 的 application 執行「結束」後：

- `grap-core64.aes` 消失
- Wine / wineserver 相關 activity 隨之停止

因此目前可將問題定義為：

> **`grap-core64.aes` 在 game process 結束後沒有完成 post-game shutdown，並使 Wine/wineserver 進入長時間高 CPU 狀態。**

## 2. Process lifecycle 證據

使用：

```text
wine wmic process get ProcessId,ParentProcessId,Name,CommandLine
```

### 遊戲運行中

觀察到：

```text
Maplestory_Classic.exe
ProcessId = 32
ParentProcessId = 0

grap-core64.aes
ProcessId = 684
ParentProcessId = 664
```

### 遊戲退出後

`Maplestory_Classic.exe` 已消失，PID 32 不存在；但：

```text
grap-core64.aes
PID 684
```

仍存在。

### 手動從 Dock 結束 NGS 後

`grap-core64.aes` 消失。

因此可以確認：

1. MapleStory PID 32 的確已正常退出
2. Wine/WMI process namespace 也已確認 PID 32 不存在
3. 殘留的是 `grap-core64.aes`
4. 不是單純 shell 誤以為遊戲已退出
5. Dock 上被結束的 NGS application 與 `grap-core64.aes` 高度相關

## 3. `grap-core64` 為何應該與 Game Session 綁定

啟動參數曾觀察到：

```text
grap-core64.aes 2982 32 <EventHandle>
```

已知：

```text
2982 = Game Code
32   = Game PID
```

另建立：

```text
Local\grap-core-mutex-2982
Local\grap-core-32
```

以及：

```text
\\.\pipe\grap-core64\2982
```

因此 `grap-core64.aes` 顯然具有非常強的 per-game / per-session state。

目前沒有證據支持它是純粹通用、永久常駐的 daemon。

## 4. 遊戲退出後出現的異常 busy-loop

第三輪 `WINEDEBUG=+server` log 在遊戲退出後產生約：

```text
9,808,081 行
約 1.28 GB
```

大量重複：

```text
0278: get_directory_entries(
    handle=0124,
    index=00000000,
    max_count=00000001
)

0278: get_directory_entries() = 0 {
    total_len=170,
    count=00000001,
    entries={{
        name=L"HID#VID_845E&PID_0001#0&0000&0&0&0#{378de44c-56ef-11d1-bc8c-00a0c91405dd}",
        type=L"SymbolicLink"
    }}
}
```

特徵：

- 同一 thread：`0x278`
- 同一 handle：`0x124`
- 每次 `index=0`
- 每次最多取一筆：`max_count=1`
- 每次成功：`= 0`
- 每次回一筆：`count=1`
- 沒有明顯 sleep / wait
- request 以非常高速度增加

## 5. `0x278` 是誰

前面的 process / thread log 已對應 `thread 0x278` 屬於 `grap-core64.aes`。

因此大量 `get_directory_entries()` 不是 Wine 一般 HID background service 自己產生，而是 `grap-core64.aes` thread 直接觸發的 Windows Object Manager directory query。

## 6. `get_directory_entries()` 是什麼

它不是 Windows application API，而是 Wine client → wineserver 的內部 protocol request。

上層對應的 Windows NT API 為：

```text
NtQueryDirectoryObject()
```

概念：

```text
grap-core64.aes
    │
    │ NtQueryDirectoryObject(...)
    ▼
Wine ntdll
    │
    ▼
wineserver
    │
    └─ get_directory_entries(...)
```

## 7. 單筆 log 欄位解析

```text
0278: get_directory_entries(
    handle=0124,
    index=00000000,
    max_count=00000001
)
```

### `0278`

Wine Windows thread ID `0x278`，屬於 `grap-core64.aes`。

### `handle=0124`

Windows HANDLE value `0x124`。

Handle value 會被回收重用。同一份 log 中 `0x124` 曾依序代表 Thread、Event、Semaphore、Mapping、File、Directory。

真正重要的是 busy-loop 開始前：

```text
0278: open_directory() = 0 { handle=0124 }
```

之後才開始：

```text
get_directory_entries(handle=0124,...)
```

因此在這一段時間：

```text
0x124 = grap-core 自己 process 中的一個 NT Directory handle
```

### `index=0`

代表 wineserver 被要求從 directory entry index 0 開始查詢。

重要現象是同一個 `open_directory` handle 後面持續：

```text
index=0
index=0
index=0
...
```

### `max_count=1`

一次最多只要求 1 entry，這與：

```text
NtQueryDirectoryObject(ReturnSingleEntry = TRUE)
```

非常吻合。

### `= 0`

server request 成功，可視為 `STATUS_SUCCESS`。

### `count=1`

本次回傳一筆 entry。

### `name=L"..."`

`L""` 代表 UTF-16 / wide string，內容是 HID device interface symbolic-link object。

### `type=L"SymbolicLink"`

是 Windows NT Object Manager `SymbolicLink` object type，不是 Unix filesystem symlink。

## 8. HID symbolic link

重複出現：

```text
HID#VID_845E&PID_0001...
```

以及曾看到 `PID_0002`。

GUID：

```text
{378de44c-56ef-11d1-bc8c-00a0c91405dd}
```

屬於 HID / device-interface 相關 namespace。

`VID_845E` 很可能是 Wine/CrossOver 建立的虛擬 HID 識別，不一定是實際 USB vendor ID。

這與 `grap-core64.aes` 靜態 imports：

```text
SetupDiGetClassDevsW
SetupDiEnumDeviceInfo
SetupDiEnumDeviceInterfaces
SetupDiGetDeviceInterfaceDetailW
```

完全吻合。

因此 GRAP 確實包含 active device / HID inspection。

## 9. Busy-loop 前的行為

同一 `grap-core` thread 在 loop 前曾執行：

```text
get_system_handles()
```

後面又做：

```text
open_mapping
get_mapping_info
create_file
get_handle_fd
create_mapping
open_directory
get_directory_entries
```

這個 sequence 比較像：

```text
System inspection / environment scan
    │
    ├─ enumerate system handles
    ├─ inspect file/mapping objects
    ├─ inspect object directories
    └─ inspect HID/device symbolic links
```

而不只是單純：

```text
if (!ProcessExists(GamePid)) exit();
```

因此目前較合理的推測是：

> MapleStory 結束後，GRAP 進入 post-game / teardown / final inspection 流程；其中某個 object/device enumeration 無法在 Wine 中完成，造成 scanner 或 shutdown worker tight-loop。

## 10. `NtQueryDirectoryObject` 的關鍵參數

Windows API：

```c
NTSTATUS NtQueryDirectoryObject(
    HANDLE DirectoryHandle,
    PVOID Buffer,
    ULONG Length,
    BOOLEAN ReturnSingleEntry,
    BOOLEAN RestartScan,
    PULONG Context,
    PULONG ReturnLength
);
```

真正需要區分：

```text
ReturnSingleEntry
RestartScan
Context in
Context out
```

Wine server log 目前只能看到：

```text
index=0
max_count=1
```

但不能直接知道 `RestartScan`、`Context input`、`Context output`。

## 11. `index=0` 無限重複的三種主要可能

### 情況 A：GRAP 每次要求 RestartScan

例如：

```text
ReturnSingleEntry = TRUE
RestartScan       = TRUE
```

那 Wine 每次 `index=0` 是合理結果。

此時問題是：

> GRAP 的外層條件為何在 Wine 中永遠不滿足，導致它不停重新掃描第一筆。

### 情況 B：GRAP 自己每次把 Context 重設為 0

例如：

```text
RestartScan = FALSE
Context in  = 0
```

每次 caller 都重新建立 context。此時 Wine 也可能沒有錯。

### 情況 C：Wine 沒有正確更新 Context

正常預期可能是：

```text
call 1: Context in=0 → Context out=1
call 2: Context in=1 → Context out=2
```

若 Wine 變成：

```text
Context in=0 → Context out=0
```

就可能導致 `index=0` 無限重複。

這才會是 `NtQueryDirectoryObject` 本身的 Wine compatibility bug。

## 12. Wine 歷史上的相關問題

Wine 過去確實曾有 `NtQueryDirectoryObject` 相容性不足。

較重要的案例是 Wine Bug 52585：

```text
Multiple applications need NtQueryDirectoryObject to return multiple entries
```

涉及 Cygwin、Sysinternals WinObj 等程式。

Wine 9.11 中有相關修正：

```text
ntdll: Implement reading multiple entries in NtQueryDirectoryObject.
server: Generalize get_directory_entries to single_entry case.
wow64: Implement reading multiple entries in wow64_NtQueryDirectoryObject.
```

因此 `NtQueryDirectoryObject` / `get_directory_entries` 過去確實不是完全沒有相容性問題的區域。

但目前 GRAP log：

```text
max_count=1
```

是 single-entry enumeration，因此 Bug 52585 不一定就是本問題本身。

## 13. 歷史上類似的 tight-loop 現象

舊 Wine 曾有 application 產生：

```text
fixme:ntdll:NtQueryDirectoryObject multiple entries not implemented
```

並高速連續重複。

曾出現在 StarCraft、World of Warcraft、Diablo II 等使用 NT object directory enumeration 的程式。

這說明：

> Windows application 若對 `NtQueryDirectoryObject` 返回值/語意有特定期待，而 Wine 行為不一致，確實可能出現沒有 sleep 的高速 retry loop。

## 14. 與已修 Wine teardown crash 的關聯

目前曾發現兩條遊戲離場階段的 wineserver SEGV。

### 14.1 `pipe_end_disconnect`

原問題：

```text
pipe_end_disconnect
    │
    ├─ null-fd guard
    └─ async_wake_up(STATUS_PIPE_BROKEN)
              │
              ▼
      is_fd_overlapped(async->fd)
              │
         null / stale fd
```

修正方向：

- 使用 `free_async_queue`
- `async_clear_weak_fd`
- 避免對 null / stale `async->fd` dereference
- 另加 `async_terminate` 的 `!async->fd` guard

### 14.2 `release_job_process → add_completion`

原問題：

```text
release_job_process
    │
    ▼
add_completion
    │
    ▼
已釋放 / invalid completion object
```

修補：

- 驗證 `completion_ops`
- SAFE traversal wait list

### 14.3 目前解讀

上述修補可能解決的是 secondary lifetime crash，但不一定是 primary busy-loop。

可能因果：

```text
post-game GRAP loop
      │
      ├─ 大量 object-directory queries
      ├─ pipe teardown
      ├─ process/job teardown
      └─ completion teardown
             │
             ▼
        wineserver race
             │
             ▼
           SEGV
```

修掉 crash 後，不再 SEGV，但 `grap-core` busy-loop 仍存在。

## 15. 目前最合理的 shutdown 模型

```text
Maplestory_Classic.exe PID 32
          │
          │ exits
          ▼
Wine / WMI 確認 PID 32 不存在
          │
          ▼
grap-communicator disconnect
          │
          ▼
\\.\pipe\grap-core64\2982 broken
          │
          ▼
grap-core enters post-game state
          │
          ├─ process cleanup
          ├─ system handle inspection
          ├─ mapping/file inspection
          ├─ device/HID/object-directory inspection
          └─ worker shutdown
                    │
                    ▼
             NtQueryDirectoryObject
                    │
                    ▼
        get_directory_entries(index=0)
                    │
                    ▼
             tight retry loop
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
       wine CPU           wineserver CPU
          │                   │
          └─────────┬─────────┘
                    ▼
           grap-core never exits
```

## 16. 目前最重要的下一個診斷

**已落地（CX26 engine）：**
`cyder-wine-engine` 的
`patches/cyder-ntdll-query-directory-object-trace.patch`（說明見
`cyder-wine-engine/docs/grap-core-qdo-trace.md`）。設 `CYDER_QDO_TRACE=1` 即可在
stderr 取得 rate-limited 的 `restart`／`ctx_in`／`ctx_out`；勿再開全量
`WINEDEBUG=+server`。

不需要再開全量：

```text
WINEDEBUG=+server
```

因為會產生 GB 級 log。

更有效的是直接在 Wine `NtQueryDirectoryObject()` 入口與返回處 trace：

```c
WARN(
    "NtQueryDirectoryObject h=%p single=%u restart=%u "
    "ctx_in=%lu size=%lu\n",
    handle,
    single_entry,
    restart,
    context ? *context : ~0u,
    size
);
```

server call 後：

```c
WARN(
    "NtQueryDirectoryObject ret=%08lx ctx_out=%lu ret_size=%lu\n",
    status,
    context ? *context : ~0u,
    ret_size ? *ret_size : 0
);
```

只需要取得十幾到幾十筆：

```text
single
restart
context_in
context_out
status
```

即可區分：

1. GRAP 每次 `RestartScan=TRUE`
2. GRAP 每次自己 reset Context
3. Wine Context 沒前進
4. directory enumeration 正常，bug 在更外層 GRAP condition

## 17. 不建議的修法

目前不建議直接：

```text
index=0 → 強制 index++
```

或：

```text
針對 grap-core throttle NtQueryDirectoryObject
```

原因：

- `RestartScan=TRUE` 時 index 0 可能完全合法
- 會改變 Windows API semantics
- 可能破壞其他 application
- 會把 generic compatibility 問題變成 game-specific workaround

正確方向應先確認：

```text
NT API input
→ Wine ntdll translation
→ wineserver index
→ Context output
```

是否與 Windows 一致。

## 18. 目前結論

目前證據支持：

1. MapleStory 本體能正常退出
2. Game PID 已從 Wine/WMI namespace 正常消失
3. `grap-core64.aes` 仍殘留
4. 殘留期間 Wine / wineserver 長時間高 CPU
5. `grap-core` thread 會高速重複 `NtQueryDirectoryObject → get_directory_entries(index=0,max_count=1)`
6. 同一 directory handle 只 `open_directory()` 一次，之後反覆 query index 0
7. busy-loop 與 post-game lifecycle 時間高度相關
8. Wine 過去確實有 `NtQueryDirectoryObject` 相容性 issue
9. 目前尚不能確認根因是 Wine `Context` bug、GRAP `RestartScan`，或 GRAP outer-loop condition
10. 下一個最關鍵證據是 `RestartScan` + `Context in/out`

目前最精確的問題描述：

> **`grap-core64.aes` 在 MapleStory Classic 結束後進入無法完成的 post-game state，其中一個 thread 對 NT Object Manager directory 執行高速、無等待、永遠從 index 0 開始的 single-entry enumeration，造成 Wine/wineserver 持續高 CPU，並使 GRAP core 長時間無法退出。**
