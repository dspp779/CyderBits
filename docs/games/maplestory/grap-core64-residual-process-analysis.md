# `grap-core64.aes` 遊戲退出後殘留與 Wine 高 CPU 問題分析

最後更新：2026-08-08  
狀態：**Cyder009 已出貨窄範圍 bandage**（見 §18）；語意層 HID／目錄物件根因仍開放。

> 本文件專門整理 MapleStory Classic 結束後，`grap-core64.aes` 未正常退出、Wine / wineserver 長時間持續 CPU，以及 `NtQueryDirectoryObject`（縮寫 **QDO**）／`get_directory_entries` busy-loop 的分析結果。

相關文件：

- 架構盤點：[`maplestory-classic-ngs-x-grap-architecture.md`](maplestory-classic-ngs-x-grap-architecture.md)
- 插件速覽：[`classic-grap-ngs-x.md`](classic-grap-ngs-x.md)
- wineserver／離場總覽：[`../../maplestory-classic-wineserver-hang.md`](../../maplestory-classic-wineserver-hang.md) §2.5
- 引擎 A/B 與 Cyder009：`cyder-wine-engine/docs/grap-core-qdo-ab-findings.md`、`cyder-wine-engine/docs/cyder009-release.md`

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

## 16. 診斷結果摘要（2026-08-07～08）

完整 A/B 矩陣見引擎文件
`cyder-wine-engine/docs/grap-core-qdo-ab-findings.md`。要點如下。

### 16.1 殘留熱路徑已鎖定

殘留稳态（GDE trace，stock `-O2` ntdll）：

| 欄位 | 值 |
|------|-----|
| wineserver request | `get_directory_entries` |
| `index` | **永遠 `0`** |
| `max_count` | `1` |
| `count` | `1` |
| entry | Wine 虛擬 HID **滑鼠** symlink |

```text
HID#VID_845E&PID_0001#…#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
```

- GUID `{378de44c-…}` = `GUID_DEVINTERFACE_HID`
- `VID_845E`／`PID_0001` 來自 Wine `winebus.sys` 虛擬滑鼠（非實體 USB）

同一 session 稍早的其他 directory handle 可正常前進 index；殘留階段只卡在上述 HID 目錄 handle。

### 16.2 Heisenbug：與 `-O2` codegen 強相關

| 變更 | 離場結果 |
|------|----------|
| stock `-O2` `NtQueryDirectoryObject` | 殘留 ~17W |
| 同原始碼 `-O0` | 乾淨退出 |
| 僅在 QDO 加 `__attribute__((optnone))` | 乾淨退出 |
| 死碼多參數 `fprintf`（TRACE 關） | 乾淨退出 |
| `usleep(100)` | 仍殘留（只變慢） |
| 只換 wineserver／teardown soft-guard | 仍殘留 |

→ **不是**「任何減速都能讓 NGS 收工」；也**不是** Cyder008 teardown patch 能消掉的問題。

### 16.3 Context A/B（能觀察到的部分）

- 乾淨路徑（optnone／I/O bandage 開）：幾乎沒有 `restart=1`；同一類 handle 上 **Context 會前進**。
- 真殘留路徑：wineserver 側永遠 `index=0`。
- 多數「觀察用」ntdll 變體本身就會弄掉 heisenbug，**無法**在真殘留下穩定 dump `restart`／`ctx_in`（SIGUSR1 會被 Wine 當 thread-suspend；memonly ring 被 DCE）。

**工作模型：** livelock payload = 列舉 Wine 虛擬 HID 滑鼠 symlink；stock `-O2` 時卡在 `index=0`；QDO 被「擾動」後 NGS 能走完 Context 並退出。仍無法實證拆開「NGS 故意重掃」vs「ntdll marshalling 沒前進」。

### 16.4 可選診斷工具（勿當產品修補）

- QDO TRACE：`cyder-wine-engine/docs/grap-core-qdo-trace.md`（`CYDER_QDO_TRACE=1`）
- GDE TRACE：experimental wineserver patch（殘留擷取）
- **勿**再開全量 `WINEDEBUG=+server`（GB 級 log）

## 17. 不建議的修法

目前不建議直接：

```text
index=0 → 強制 index++
```

或：

```text
針對 grap-core throttle NtQueryDirectoryObject
```

或：

```text
把死碼 fprintf／全 ntdll -O0 當正式修補出貨
```

原因：

- `RestartScan=TRUE` 時 index 0 可能完全合法
- 會改變 Windows API semantics 或變成 game-specific hack
- 死碼 I/O 不是可維護的產品解

語意層正確方向仍是：

```text
NT API input → Wine ntdll → wineserver index → Context output
```

與 Windows／HID 目錄內容對照；或產品層 session 清理（最後手段）。

## 18. 產品／引擎現況與結論

### 18.1 已出貨（Cyder 0.9.5／引擎 Cyder009）

窄範圍 bandage（**非**語意修補）：

```text
patches/cyder-ntdll-qdo-optnone-NtQueryDirectoryObject.patch
```

只對 `NtQueryDirectoryObject` 標 `__attribute__((optnone))`；預設套用於 CX26 建置；marker `cyder QDO optnone`。  
實測可消掉離場 grap／wineserver busy-loop；**不是** HID／`\??` 目錄物件保真度修正。

Cyder008 teardown soft-guard 仍保留（防強制結束時 wineserver SEGV），與本 livelock **正交**。

### 18.2 仍開放

1. **語意根因**：虛擬 HID symlink 列舉為何在 stock `-O2` 卡住。
2. **產品 session 清理**：主程式結束後追蹤／逾時清理 grap／NGS PID（最後手段 UX）。
3. 既有 bottle 若仍殘留舊行為：確認 runtime 已是 Cyder009（或含 optnone marker 的 ntdll）。

### 18.3 證據結論（更新後）

1. MapleStory 本體能正常退出；Game PID 從 Wine/WMI 消失。
2. 殘留的是 `grap-core64.aes`，熱路徑為 **QDO → `get_directory_entries(index=0)`**。
3. 殘留 payload 鎖定 **Wine 虛擬 HID 滑鼠** symlink（`VID_845E`）。
4. 現象與 `-O2` codegen／layout（含 Rosetta）強相關；teardown soft-guard 無法消掉。
5. Cyder009 `optnone` bandage 已驗證可乾淨退出；語意修補與產品 session 清理仍待做。

最精確的問題描述：

> **`grap-core64.aes` 在 MapleStory Classic 結束後進入無法完成的 post-game state，對 Wine 虛擬 HID 裝置介面目錄做高速、無等待、永遠從 index 0 開始的 single-entry `NtQueryDirectoryObject` enumeration，造成 Wine/wineserver 持續高 CPU。Cyder009 以 QDO `optnone` 作為 codegen bandage 緩解；根因仍可能是 ntdll marshalling heisenbug、NGS 外層條件，或 HID 目錄保真度差異。**
