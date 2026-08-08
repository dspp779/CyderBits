# MapleStory Classic NGS-X / GRAP 反作弊架構分析

最後更新：2026-08-08

> 本文件整理目前透過 PE 靜態分析、PDB 路徑、Imports/Strings 與 Wine/CrossOver runtime log 所得到的 NGS-X / GRAP 架構。分析目的為相容性研究與系統行為理解，不涉及停用、繞過或偽造反作弊機制。

相關文件：

- 離場殘留／QDO livelock：[`grap-core64-residual-process-analysis.md`](grap-core64-residual-process-analysis.md)
- 插件目錄速覽：[`classic-grap-ngs-x.md`](classic-grap-ngs-x.md)
- wineserver／離場總覽：[`../../maplestory-classic-wineserver-hang.md`](../../maplestory-classic-wineserver-hang.md)
- 引擎 QDO A/B：`cyder-wine-engine/docs/grap-core-qdo-ab-findings.md`

## 1. 已知識別資訊

遊戲啟動參數：

```text
game=2982@2141
```

目前已知：

- `2982`：Game Code
- `2141`：obdTag

GRAP runtime 會直接使用 `2982` 作為本機 IPC / singleton namespace 的一部分，例如：

```text
\\pipe\\grap-core64\\2982
Local\\grap-core-mutex-2982
```

## 2. 整體架構

目前最符合靜態與動態證據的架構如下：

```text
Maplestory_Classic.exe
  │
  ├─ grap64.dll
  │    └─ 固定整合介面 / bootstrap
  │
  └─ grap-communicator64.aes
       └─ 遊戲內長駐的 communication/runtime DLL
               │
               │ Named Pipe / Event / Mapping 等 IPC
               ▼
        grap-core64.aes
        └─ 獨立 x64 user-mode anti-cheat engine
               │
               ├─ Process / Module inspection
               ├─ Driver / Device inspection
               ├─ Remote PE / memory inspection
               ├─ DetectLog building
               └─ 可能的 backend communication

NGS Windows Service / Broker
  │
  └─ NGService.exe
       ├─ WinVerifyTrust
       ├─ 啟動 grap-updater.aes
       └─ 啟動 grap-core64.aes

grap-updater.aes
  └─ GRAP bundle 更新 / 準備

BlackCat64.sys
  └─ 可選 / 條件式 kernel extension path
     （目前 CrossOver runtime 未觀察到載入）
```

## 3. `grap64.dll`

### 3.1 基本資訊

- x64 DLL
- PDB：

```text
D:\GST\NGS\grap-client-pc-release-1.5.0.0\_Build\grap-interface\x64\Output\Release\grap64.pdb
```

因此 project 名稱可確認為：

```text
grap-interface
```

### 3.2 角色

`grap64.dll` 直接由 `Maplestory_Classic.exe` 載入。

它比較像穩定的 game-facing ABI / bootstrap interface，而不是主要掃描引擎。

Strings 可看到：

```text
NGS-X Init is not Called!!!
NGS-X Run is not Called!!!
NGS-X reset failed...
```

因此 GRAP 對遊戲提供的 lifecycle 很可能包含：

```text
Init
Run
Reset
```

### 3.3 Service / privilege 能力

Imports 包含：

```text
OpenSCManagerW
OpenServiceW
CreateServiceW
DeleteService
QueryServiceConfigW
QueryServiceStatus
ChangeServiceConfig2W
StartServiceW
ControlService
```

另有：

```text
OpenProcessToken
AdjustTokenPrivileges
WinVerifyTrust
```

因此 `grap64.dll` 具有：

- NGS Windows Service bootstrap
- service 安裝 / 啟動 / 狀態確認
- 權限調整
- Authenticode 驗證
- updater / core 啟動協調

### 3.4 GRAP bundle

Strings：

```text
%ws\grap\grap-updater.aes
grap-updater.aes file not found.
Disconnected from grap-update.aes.
Failed to launch NGService.exe
```

因此 `grap64.dll` 會協調 updater 與 NGService。

## 4. `grap-communicator64.aes`

### 4.1 基本資訊

- x64 DLL
- PDB：

```text
D:\GST\NGS\grap-client-pc-release-1.5.0.0\_Build\grap-communicator\x64\Output\Release\grap-communicator64.pdb
```

### 4.2 Runtime 載入位置

Wine runtime log 已確認 `Maplestory_Classic.exe` PID `0x20` 會載入 `grap-communicator64.aes`。

在目前觀察的 session 中，`grap-core64.aes` 並沒有再載入 communicator。

因此 communicator 是 **game-side runtime DLL**。

### 4.3 IPC 能力

Imports 包含：

```text
CreateEventW
OpenEventW
CreateMutexW
OpenMutexW
CreateFileMappingW
MapViewOfFile
DuplicateHandle
PeekNamedPipe
ReadFile
WriteFile
CreateIoCompletionPort
```

這表示 communicator 支援：

- Named Pipe
- Event
- Mutex
- Shared Memory / Mapping
- overlapped / IOCP 類型的非同步 IPC

### 4.4 與 core 的 Named Pipe

第三輪 Wine `+server` log 已直接確認 game side 先嘗試：

```text
\??\pipe\grap-core64\2982
```

在 core 尚未建立時得到：

```text
OBJECT_NAME_NOT_FOUND
```

之後 `grap-core64.aes` 建立：

```text
\Device\NamedPipe\grap-core64\2982
```

因此目前可確認：

```text
grap-communicator64.aes
        │
        │ client
        ▼
\\.\pipe\grap-core64\2982
        ▲
        │ server
grap-core64.aes
```

## 5. `grap-core64.aes`

### 5.1 基本資訊

- PE32+ x64 GUI EXE
- build date：約 2026-04-24
- PDB：

```text
D:\GST\NGS\grap-client-pc-release-1.5.0.0\_Build\grap-core\x64\Output\Release\grap-core64.pdb
```

- manifest：

```text
requireAdministrator
```

### 5.2 Runtime 啟動參數

NGService runtime log 已觀察到：

```text
grap-core64.aes 2982 32 <EventHandle>
```

已確認：

```text
2982 = Game Code
32   = Maplestory_Classic.exe PID（decimal）
```

因此可視為：

```text
grap-core64.aes <GameCode> <GamePid> <EventHandle>
```

例如某次 session：

```text
GameCode    = 2982
GamePid     = 32
EventHandle = 0x5DC
```

### 5.3 Singleton / session object

Runtime log 可看到：

```text
Local\grap-core-mutex-2982
```

非常像：

```text
Local\grap-core-mutex-<GameCode>
```

用途應為防止同一 Game Code 同時啟動多個 core instance。

另有：

```text
Local\grap-core-32
```

其中 `32 = GamePid`，因此此 object 是 per-game-process session synchronization object。

### 5.4 內部 subsystem

RTTI / type strings 可看到：

```text
ProcessManager
ProcessInfo
ProcessKeyGenerator
ModuleInformation
ModuleKeyGenerator
DriverManager
DriverInformation
DriverKeyGenerator
MemorySharedPageHandler@Core@GRAP
PeRemote
DetectLogBuilder
SecureType<bool, XorStreamEncryptor<...>>
```

可推定 core 包含：

- process inventory / state tracking
- module inventory
- driver / device inventory
- remote PE parsing
- process memory inspection
- detection log construction
- protected internal state

### 5.5 Process / thread / memory 能力

Imports：

```text
EnumProcesses
OpenProcess
ReadProcessMemory
GetProcessId
GetProcessTimes
OpenThread
GetThreadContext
SuspendThread
TerminateProcess
```

因此 core 是主要的 user-mode environment inspection engine。

### 5.6 Device / driver inspection

Imports：

```text
SetupDiGetClassDevsW
SetupDiEnumDeviceInfo
SetupDiEnumDeviceInterfaces
SetupDiGetDeviceInstanceIdW
SetupDiGetDeviceInterfaceDetailW
```

Runtime 也已看到：

```text
NtQueryDirectoryObject
→ HID#VID_845E...
```

因此 GRAP 確實會檢查 Windows device / HID namespace。

### 5.7 System handle inventory

Wine server log 可看到 core thread 呼叫：

```text
get_system_handles()
```

這與 Windows：

```text
NtQuerySystemInformation(SystemHandleInformation / SystemExtendedHandleInformation)
```

類型的功能相符。

因此 core 會做全系統 handle inventory，而非只監控遊戲 PID。

## 6. `NGService.exe`

### 6.1 基本資訊

- x86 EXE
- PDB：

```text
D:\Work_NGS\NGS_04\_Build\NGService\x86\Output\Release\NGService.pdb
```

- protected sections：

```text
.vm_sec
.winlice
.loadcon
.boot
.init
```

### 6.2 Service

已觀察到 Windows service：

```text
Service name: NGS
Image: C:\ProgramData\Nexon\NGS\NGService.exe -service
Display name: Nexon Game Security Service
```

### 6.3 Broker / trusted launcher

Runtime log 已確認 NGService 會：

```text
WinVerifyTrust(grap-updater.aes)
CreateProcess(grap-updater.aes)
WinVerifyTrust(grap-core64.aes)
CreateProcess(grap-core64.aes)
```

因此它不是主掃描引擎，而是 trusted privileged broker / launcher。

其 protocol strings：

```text
Command
CurrentDirectory
EventHandle
GamePid
Version
ServiceWork_Version01
ServiceWork_Version02
```

與 runtime 觀察一致。

## 7. `grap-updater.aes`

### 7.1 基本資訊

- x86 PE32 GUI EXE
- PDB：

```text
D:\GST\NGS\grap-client-pc-release-1.5.0.0\_Build\grap-updater\x86\Output\Release\grap-updater.pdb
```

### 7.2 Runtime

曾觀察到：

```text
grap-updater.aes "2982" "32" "3a8" "3ac"
```

因此 updater 也取得 Game Code 與 Game PID。

### 7.3 功能

Strings 可看到整個 bundle：

```text
grap.dll
grap64.dll
grap-communicator.aes
grap-communicator64.aes
```

Imports 具備：

```text
CopyFile
MoveFile
DeleteFile
FindFirstFile / FindNextFile
Registry APIs
CreateProcess
```

因此主要角色是：

- 更新 GRAP components
- 檢查 / 準備 bundle
- 管理版本與檔案

## 8. `BlackCat64.sys`

### 8.1 基本資訊

- Windows x64 kernel driver
- NT Native subsystem
- PDB：

```text
D:\source\Nexon\NGS-X\ngs-x-client-pc\grap-common\Kernel\kernel-driver\_Build\BlackCat\x64\Output\Release_Publish\BlackCat64.pdb
```

Metadata：

```text
NGS Driver
Nexon Korea
```

### 8.2 Kernel capabilities

Imports：

```text
PsSetCreateProcessNotifyRoutine
PsLookupProcessByProcessId
PsGetProcessPeb
PsGetProcessId
KeStackAttachProcess
KeUnstackDetachProcess
MmCopyMemory
MmIsAddressValid
MmGetSystemRoutineAddress
ProbeForRead
ProbeForWrite
IoCreateDevice
IoCreateSymbolicLink
PsCreateSystemThread
```

因此 BlackCat 具備：

- process creation monitoring
- kernel-side process lookup
- PEB / memory inspection
- user/kernel communication device
- kernel worker threads

### 8.3 是否為必要元件？

目前答案是：**至少在已觀察的 CrossOver session 中不是。**

雖然 `grap-core64.aes` 靜態分析可找到：

```text
CreateServiceW(SERVICE_KERNEL_DRIVER, SERVICE_DEMAND_START, ...)
```

這表示 core 內有 kernel-driver management path。

但 runtime 中：

```text
CreateService for BlackCat: 未觀察到
BlackCat64.sys load: 未觀察到
ZwLoadDriver: 未觀察到
```

而 MapleStory Classic 可長時間正常遊玩。

因此目前較合理的模型是：

```text
BlackCat64.sys = conditional / optional / enhanced kernel path
```

不是所有環境都必須啟用。

目前也沒有證據能確認 GRAP 有明確 `IsWine()` 分支。

## 9. GRAP 本機 IPC

### Named Pipe

```text
\\.\pipe\grap-core64\2982
```

角色：

```text
grap-communicator64.aes = client
grap-core64.aes         = server
```

core 建立時：

```text
maxinstances = PIPE_UNLIMITED_INSTANCES
```

並可由多個 worker thread 建立 pipe instance。

### Mutex

```text
Local\grap-core-mutex-2982
```

可能用途：singleton per Game Code。

### Event

```text
Local\grap-core-32
```

其中 `32` 是 Game PID。

另有由 NGService 傳給 core 的 `EventHandle`，很可能用於 startup / lifecycle synchronization。

### Global object template

各元件可看到：

```text
Global\{6E68F26C-A5CD-4ECD-B553-8CB213433A73-%08X}
```

runtime 曾看到不同 suffix，例如：

```text
37250717
E7E3DB51
```

因此 `%08X` 已可排除是 Game PID。

較可能是：

- generated session key
- shared-page identifier
- hash / random identifier

但目前用途尚未完全確認。

## 10. 目前最可信的啟動流程

```text
Maplestory_Classic.exe
    │
    ▼
load grap64.dll
    │
    ▼
NGS-X Init
    │
    ▼
Open/Start NGS Windows Service
    │
    ▼
NGService.exe
    │
    ├─ WinVerifyTrust
    ├─ launch grap-updater.aes
    └─ launch grap-core64.aes
    │
    ▼
grap-updater
    │
    └─ prepare/update GRAP bundle
    │
    ▼
MapleStory loads grap-communicator64.aes
    │
    ▼
try \\.\pipe\grap-core64\2982
    │
    ├─ core not ready → OBJECT_NAME_NOT_FOUND
    ▼
grap-core64 starts
    │
    ├─ Local\grap-core-mutex-2982
    ├─ Local\grap-core-32
    └─ CreateNamedPipe
          │
          ▼
\\.\pipe\grap-core64\2982
          │
          ▼
communicator connects
          │
          ▼
GRAP session active
```

## 11. Wine / CrossOver 相容性觀察

目前能正常運作的關鍵點：

- `grap64.dll` 可載入
- NGS Windows Service 可在 Wine SCM emulation 下工作
- NGService 可進行 `WinVerifyTrust`
- updater 可啟動
- `grap-core64.aes` 可啟動
- game-side communicator 可載入
- Named Pipe handshake 成功
- 長時間 gameplay 可維持
- server 端接受該 security session
- 未觀察到 BlackCat kernel driver path

因此目前可確認：

> NGS-X / GRAP 的核心 user-mode 架構在 CrossOver/Wine 中具備高度可執行性。

### 11.1 離場殘留（已緩解、根因開放）

最大相容性問題曾集中於 **遊戲退出後的 GRAP teardown / post-game lifecycle**：

- `grap-core64.aes` 殘留 + wineserver 高 CPU
- 熱路徑：`NtQueryDirectoryObject`（QDO）→ `get_directory_entries(index=0)`
- 殘留 payload：Wine 虛擬 HID 滑鼠 symlink（`VID_845E`／`GUID_DEVINTERFACE_HID`）

詳見 [`grap-core64-residual-process-analysis.md`](grap-core64-residual-process-analysis.md)。

| 層級 | 狀態（2026-08-08） |
|------|-------------------|
| Cyder008 teardown soft-guard | 防強制結束 SEGV；**不能**消掉 QDO livelock |
| Cyder009 QDO `optnone` | **已 pin／出貨**（Cyder 0.9.5）；codegen bandage，非 HID 語意修補 |
| 產品 session PID 清理 | 仍建議（最後手段 UX） |
| HID／目錄物件保真度 | 開放 |

### 11.2 元件角色速查

| 元件 | 角色 | 離場相關 |
|------|------|----------|
| `grap64.dll` | 進程內 NGS-X ABI／bootstrap | 低 CPU；非 busy-loop 主體 |
| `grap-communicator64.aes` | game-side IPC client | pipe client → `grap-core64\2982` |
| `grap-core64.aes` | 獨立掃描引擎 | **離場高 CPU 主體** |
| `NGService.exe` | privileged broker／Dock「Nexon Game Security」 | 可隨 session 殘留 |
| `BlackCat64.sys` | 可選 kernel path | macOS／Wine 未觀察到載入 |