# 新楓之谷經典版：CX26 登入卡住與 x86_64 frame walk 修補紀錄

更新日期：2026-07-30  
最終版本：Cyder 0.8.3 / `CX26.3.0-W11-Cyder006`

## 1. 摘要

《新楓之谷：經典版》在 CrossOver 26.3.0 / Wine 11.0 衍生的
`CX26.3.0-W11-Cyder005` 引擎上可以完成 DirectX 11 初始化並顯示登入畫面，
但會長時間停在「登入中，請稍候」。

問題不是單純的伺服器、圖形後端或視窗刷新失敗。診斷結果顯示，遊戲／安全模組在
x86_64 例外處理期間呼叫 `RtlWalkFrameChain()`；舊版實作把
`RtlLookupFunctionEntry()` 回傳的 unwind metadata 直接交給
`RtlVirtualUnwind2()`。當 metadata 無效或在執行期間發生變動時，
`RtlVirtualUnwind2()` 會觸發 page fault。該 fault 逃回應用程式的例外 handler，
handler 再次要求 stack walk，最後形成遞迴例外與 Wine stack overflow。

Wine 11.1–11.14 的 upstream 實作相較 Wine 11.0，會先以 `if (!func) break` 阻止
NULL `RUNTIME_FUNCTION` 進入 `RtlVirtualUnwind2()`。這項差異最初是在 Wine 11.8
對照測試中發現。Cyder 在 CrossOver 26 分支採用更防禦性的延伸：以 Wine SEH 捕捉
stack walk 內的 page fault，將其轉成 `STATUS_ACCESS_VIOLATION`，並沿用既有的
「非零狀態即停止目前 stack walk」行為。

修補後已實測通過：

- DirectX 11 初始化；
- 登入；
- 選擇伺服器、頻道與角色；
- GRAP 安全模組；
- 進入遊戲地圖；
- 使用遊戲內「結束遊戲」正常離開。

## 2. 測試環境

| 項目 | 值 |
|------|----|
| 主機 | macOS，Apple Silicon，以 Rosetta 2 執行 x86_64 Wine |
| 原始 Cyder runtime | `/Users/jjc/.cyder/runtime/Engines/wine-x86_64` |
| 原始引擎標籤 | `CX26.3.0-W11-Cyder005` |
| Wine 基底 | CrossOver 26.3.0 source / Wine 11.0 |
| Prefix | `/Users/jjc/Library/Application Support/Cyder/bottles/shared` |
| 遊戲 | `/Users/jjc/games/tms_cw/Maplestory_Classic.exe` |
| CX26 原始壓縮檔 | `tools/archives/crossover-sources-26.3.0.tar.gz` |
| CX26 Wine 原始碼 | `build/cx26/sources/wine` |
| 既有 build tree | `build/cx26/sources/wine/build64` |
| 安裝目錄 | `install/wine-cx26-x86_64` |
| LLVM-MinGW | `build/llvm-mingw-20260616-ucrt-macos-universal` |
| 最終引擎 | `CX26.3.0-W11-Cyder006` |

登入命令需要四個由啟動服務提供的參數。這些值包含短效 session／登入資料，
不得寫入文件、Git、shell script 或永久 log。本文一律以
`<arg1> <session-token> <arg3> <arg4>` 表示。

## 3. 症狀與容易混淆的問題

這次調查同時遇到三個不同層級的問題。若只看到最後一個畫面，很容易把它們混為
同一個圖形 bug。

| 階段 | 現象 | 判讀 |
|------|------|------|
| CrossOver 26 / Cyder005 | 停在「登入中，請稍候」 | 最終確認為 NTDLL frame walk／例外遞迴 |
| WineD3D 測試 | 登入畫面後關閉，或剩下空白視窗 | 圖形後端／視窗呈現路徑問題，不能單獨解釋登入卡住 |
| 部分新 Wine 測試 | `Failed to initialize graphics`、`InitializeEngineGraphics failed` | 該 runtime 的 D3D11/DXVK/MoltenVK 組合未正確成立 |
| 通用 Wine 11.14 | 能推進到選角附近，但顯示「安全模組運作中／客戶端強制關閉(0)」 | upstream Wine 可用來做 A/B，但不能取代 CrossOver runtime 通過 GRAP |
| 修補後 CX26 | 通過登入、GRAP 並進入地圖 | 保留 CrossOver 相容性，同時修正 frame walk |

Wine 視窗不是原生 macOS App 視窗，當時的自動化工具無法可靠擷取其內容，因此畫面
狀態由人工截圖確認。判斷程式是否仍在執行，則搭配 process、Wine log 與 CPU sample，
不能只用「視窗還在」作為依據。

## 4. Debug 方法

### 4.1 固定 runtime、prefix 與輸入

第一步不是立刻更換所有元件，而是固定：

- 同一份遊戲檔案；
- 同一個 Cyder shared prefix；
- 同一組當次登入參數；
- 一次只替換 Wine runtime、圖形後端或單一 DLL。

專案提供不保存登入資料的啟動器：

```bash
scripts/run-maplestory-classic-debug.sh \
  <arg1> <session-token> <arg3> <arg4>
```

可用環境變數替換測試目標：

```bash
MAPLE_WINE_RUNTIME=/path/to/wine-runtime \
MAPLE_WINEPREFIX="$HOME/Library/Application Support/Cyder/bottles/shared" \
MAPLE_GAME_EXE="$HOME/games/tms_cw/Maplestory_Classic.exe" \
MAPLE_SYNC_MODE=none \
scripts/run-maplestory-classic-debug.sh \
  <arg1> <session-token> <arg3> <arg4>
```

啟動器預設：

```text
MAPLE_SYNC_MODE=none
WINEDLLOVERRIDES=d3d11,dxgi=n,b
WINEDEBUG=-all
```

`MAPLE_SYNC_MODE` 可設為 `none`、`msync` 或 `esync`；啟動器會讓
`WINEMSYNC`／`WINEESYNC` 保持互斥，並把 `WINESERVER` 明確綁定到同一份候選
runtime。要保留低負擔錯誤 log：

```bash
mkdir -p tools/debug-logs

MAPLE_WINEDEBUG='-all,err+all,+timestamp,+pid,+tid' \
MAPLE_LOG_FILE="$PWD/tools/debug-logs/maplestory-low-overhead.log" \
MAPLE_SYNC_MODE=none \
scripts/run-maplestory-classic-debug.sh \
  <arg1> <session-token> <arg3> <arg4>
```

只有在已縮小到例外處理窗口時，才暫時使用
`+timestamp,+pid,+tid,+seh,+unwind`。完整 SEH／unwind trace 會在 GRAP 初始化時
快速產生數十萬行資料，足以改變執行緒時序；它適合擷取短窗口，不適合拿來判定商城、
切換頻道或正常退出是否穩定。

若要分享 log，必須先確認命令列參數沒有被印出，並移除 session token、帳號識別碼、
本機路徑及其他敏感資料。

### 4.2 先排除圖形初始化

`Failed to initialize graphics` 本身只表示 D3D11 device／swapchain 沒有建立成功，
不能推論登入流程的根因。調查時分別確認：

1. `d3d11.dll`／`dxgi.dll` 的載入順序；
2. DXVK log 是否由主遊戲程序產生；
3. MoltenVK 是否來自預期 runtime；
4. WineD3D 是否能至少顯示登入 UI；
5. 切換後端後，卡住的位置是否改變。

當畫面已能到「登入中」且 DXVK log 顯示 D3D11 正常建立，後續不再把注意力放在
DirectX 初始化，而改查主執行緒與例外處理。

### 4.3 使用新版 upstream Wine 做 A/B

本機使用 `tools/archives/wine-11.14.tar.xz` 作為 Wine 11.14 source archive。
新版 upstream Wine 能讓遊戲推進得更遠，顯示問題與 CrossOver 26 所基於的 Wine
11.0 程式碼差異很可能有關。

但 Wine 11.14 不是最終解：

- 部分圖形組合仍會發生 D3D11 初始化失敗；
- 即使到達選角，GRAP 仍可能以「客戶端強制關閉(0)」終止遊戲；
- 直接升級整個 Wine 會丟失或改變 CrossOver 的 macOS、圖形與相容性修補。

因此新版 Wine 只作為縮小範圍的對照組，最終仍回到 CX26 source 做最小 backport。

### 4.4 從例外遞迴定位 NTDLL

關鍵觀察是：

1. 遊戲停在登入畫面時不是單純 idle；
2. page fault 出現在 x86_64 unwind／frame walk 路徑；
3. `RtlWalkFrameChain()` 呼叫 `RtlVirtualUnwind2()`；
4. fault 逃到 GameAssembly／安全模組的應用程式例外 handler；
5. handler 再次要求 stack walk；
6. 相同路徑重複進入，最後形成 Wine stack overflow。

CrossOver 26.3 source 中的原始程式碼為：

```c
func = RtlLookupFunctionEntry( context.Rip, &base, &table );
if (RtlVirtualUnwind2( UNW_FLAG_NHANDLER, base, context.Rip, func, &context, NULL,
                       &data, &frame, NULL, NULL, NULL, &handler, 0 ))
    break;
```

這裡假設 lookup 回傳值與它指向的 unwind metadata 在整個 unwind 操作期間都有效。
對一般 PE 程式通常成立，但對含保護、動態產生或執行期修改程式碼的遊戲／安全模組
並不夠安全。

## 5. Wine 11.1–11.14 upstream guard

[Wine 11.8](https://www.winehq.org/news/2026050101)（[官方 source
archive](https://dl.winehq.org/wine/source/11.x/wine-11.8.tar.xz)）的
`dlls/ntdll/signal_x86_64.c` 相較官方 Wine 11.0，多了 lookup 失敗檢查：

```diff
 func = RtlLookupFunctionEntry( context.Rip, &base, &table );
+if (!func) break;
 if (RtlVirtualUnwind2( UNW_FLAG_NHANDLER, base, context.Rip, func, &context, NULL,
```

這項差異直接涵蓋「找不到 `RUNTIME_FUNCTION` 卻仍呼叫 unwind」的情況，也是新版
Wine A/B 測試能推進流程的重要線索。

進一步追查 Wine 公開 mirror 後，精確提交為
[`02831b283ec70b5a4f92b33f49a6860f70697ce6`](https://github.com/wine-mirror/wine/commit/02831b283ec70b5a4f92b33f49a6860f70697ce6)，
提交訊息是 `ntdll: Stop walk in RtlWalkFrameChain() if there is no function
entry on x64.`。該提交的 runtime 變更只有 `signal_x86_64.c` 這一行，另外把既有
exception test 的四行預期從 TODO 改為正式通過。

版本考證：

- 官方 Wine 11.0 source 沒有這個 guard；
- Wine 11.1 是第一個包含該 guard 的正式版本；
- Wine 11.2–11.14 都保留相同行為；
- Wine 11.8 是本次調查最初採用的參考版本，不是首次引入版本。

本次核對下載檔的 SHA-256：

```text
Wine 11.0  c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701
Wine 11.7  b01ab21c79fede6c7bd531d469d99afd9dcdf53eb29af88adac6a332eb435f9f
Wine 11.8  53aa85995d4b97f0116a1c56b8a6a1417730ef59a277819d2d3d31364ea556b0
```

`if (!func) break` 只能處理 NULL。實際 CX26 trace 還可能遇到：

- `func` 非 NULL，但指向不可讀或過期的 metadata；
- metadata 在 lookup 後、unwind 前被保護模組改變；
- `RtlVirtualUnwind2()` 讀取 chained unwind data 時才發生 page fault。

所以 Cyder 沒有直接換成完整 Wine 11.8/11.14，也沒有只停在 NULL guard，而是保留
CX26 行為並擴大失敗邊界的保護。

## 6. 最終修補

正式 patch 依序為：

```text
patches/wine-11.1-rtlwalkframechain-null-function.patch
patches/cyder-ntdll-frame-walk-page-fault-guard.patch
```

第一段是 Wine upstream
`02831b283ec70b5a4f92b33f49a6860f70697ce6` 的精確 x64 runtime 修正：

```c
func = RtlLookupFunctionEntry( context.Rip, &base, &table );
if (!func) break;
```

第二段是 Cyder 對非 NULL、但 metadata 不可讀情況的額外保護：

```c
status = STATUS_SUCCESS;
__TRY
{
    status = RtlVirtualUnwind2( UNW_FLAG_NHANDLER, base, context.Rip, func,
                                &context, NULL, &data, &frame, NULL, NULL,
                                NULL, &handler, 0 );
}
__EXCEPT_PAGE_FAULT
{
    status = STATUS_ACCESS_VIOLATION;
}
__ENDTRY
if (status) break;
```

設計理由：

- 正常 unwind 的回傳值與控制流程不變；
- `RtlVirtualUnwind2()` 原本回傳非零時就會停止 stack walk；
- page fault 被轉成同類型的「無法繼續 unwind」，不再逃進應用程式 handler；
- 已收集到的 frame 仍可回傳；
- 不修改遊戲、GRAP、DXVK 或 prefix；
- 修補範圍只在 x86_64 `RtlWalkFrameChain()`。

這不是把所有 access violation 吞掉。保護區只包住 `RtlVirtualUnwind2()`，發生 fault
後立即終止目前 stack walk；其他遊戲邏輯的 access violation 仍維持原本處理方式。

### 套用範圍

`scripts/build-wine.sh` 只在 CX26 套用：

```bash
if [[ "$CX_VERSION" == "26" ]]; then
  remove_obsolete_cyder_patch \
    "$OGOM/patches/obsolete/cyder-ntdll-frame-walk-guard.patch"
  apply_cyder_patch \
    "$OGOM/patches/wine-11.1-rtlwalkframechain-null-function.patch"
  apply_cyder_patch \
    "$OGOM/patches/cyder-ntdll-frame-walk-page-fault-guard.patch"
fi
```

CX25 基於 Wine 10，跨越 Wine major version，且未用同一個失敗案例驗證，因此預設
不套用。需要支援 CX25 時，應重新比對該分支的 unwind ABI 與例外處理實作，不能直接
假設 patch 安全。

`patches/obsolete/cyder-ntdll-frame-walk-guard.patch` 只用於把既有 Cyder006
incremental source tree 回復到未套用狀態；乾淨 source 不會套用它。

### 6.1 「套用 Wine 11.14 修復」的三種範圍

這句話可能代表三種完全不同的修改，風險不能混在一起評估：

| 方案 | 實際修改 | 完整度 | 風險 |
|------|----------|--------|------|
| A. 回植 x64 NULL guard | 在 `RtlWalkFrameChain()` 加 `if (!func) break` | 補齊 upstream 11.1–11.14 行為 | 低 |
| B. NULL guard + Cyder page-fault guard | 先拒絕 NULL，再捕捉非 NULL metadata 的 fault | 對本案涵蓋最完整 | 低至中 |
| C. 搬移整份 11.14 NTDLL／整套 Wine | 同時引入 unwind、header、server、loader 等版本變更 | 功能面最廣，但不是本案的最小修復 | 高 |

採用 **方案 B**。Cyder006 已有 page-fault guard；Cyder007 候選再加入 upstream 的
`if (!func) break`，並把兩個來源拆成可獨立稽核的 patch。兩者處理不同失敗邊界：

```c
func = RtlLookupFunctionEntry( context.Rip, &base, &table );
if (!func) break;  /* Wine 11.1–11.14 */

status = STATUS_SUCCESS;
__TRY
{
    status = RtlVirtualUnwind2( ... );  /* Cyder：保護非 NULL 但無效的 metadata */
}
__EXCEPT_PAGE_FAULT
{
    status = STATUS_ACCESS_VIOLATION;
}
__ENDTRY
if (status) break;
```

這個順序的優點是：

1. 找不到 function entry 時不再把 stack 當成 leaf frame 繼續猜測；
2. 不需要先製造 page fault 再由 SEH 收斂；
3. function entry 非 NULL、但 unwind data 不可讀時仍有 Cyder guard；
4. 正常、有合法 unwind metadata 的路徑不變；
5. 與 Wine upstream 的 x64 `RtlWalkFrameChain()` 行為更接近。

### 6.2 是否需要修改其他 runtime 模組

若採方案 A 或 B，**不需要修改其他 runtime 模組**。必要變更只有：

```text
dlls/ntdll/signal_x86_64.c
```

並重新建置、安裝：

```text
dlls/ntdll/x86_64-windows/ntdll.dll
```

不需要為這一行修改：

- `wineserver`；
- Unix `ntdll.so`；
- `kernel32`／`kernelbase`；
- `win32u`；
- DXVK／WineD3D／MoltenVK；
- prefix 或 registry；
- GRAP／遊戲檔案。

建議但非 runtime 必要的測試變更：

```text
dlls/ntdll/tests/exception.c
```

Wine 11.14 的測試會建立沒有 runtime function entry 的 x64 動態程式碼，確認
`RtlCaptureStackBackTrace()` 與 `RtlWalkFrameChain()` 在該邊界停止。CX26 的 Wine
11.0 test tree 尚未包含完整測試基礎；不應整份複製 Wine 11.14
`tests/exception.c`，因為兩版相差數百行無關測試。較安全的方式是：

1. 只回植該 test helper 及其必要初始化；或
2. 在 Cyder 建立一個小型 x64 PE regression harness。

若要執行 Wine test，需使用 `scripts/build-wine.sh --with-tests` 產生另一個測試
build；正式 runtime 預設 `--disable-tests`，不應為了測試而改變發佈引擎內容。

### 6.3 不應直接搬入的 Wine 11.14 變更

Wine 11.0 到 11.14 的相關檔案差異並不只一個 bug fix：

| 檔案 | 11.0→11.14 差異量 | 與本案的關係 |
|------|-------------------|--------------|
| `signal_x86_64.c` | 約 6 行新增、5 行刪除 | 只有 NULL guard 直接相關；另有 `RtlUnwindEx()` 修正 |
| `unwind.c` | 約 43 行新增、23 行刪除 | 多為 ARM64 與 output pointer 行為，不是 x64 frame-walk guard |
| `tests/exception.c` | 約 421 行新增、40 行刪除 | 包含大量無關 exception tests |
| `include/winnt.h` | 約 550 行新增、34 行刪除 | 大型 header 演進，不是本案依賴 |

Wine 11.14 `unwind.c` 內確實有 `__EXCEPT_PAGE_FAULT`，但它位於 **ARM64**
`RtlVirtualUnwind2()` 實作。x64 `RtlVirtualUnwind2()` 並沒有同等的 11.14
page-fault wrapper。直接把 ARM64 寫法移到 x64 callee 會把影響範圍從
`RtlWalkFrameChain()` 擴張到所有 x64 unwind caller，包括：

- 例外 dispatcher；
- C/C++ exception runtime；
- `RtlVirtualUnwind()`；
- MSVCRT exception handling；
- 其他直接呼叫 `RtlVirtualUnwind2()` 的程式。

這可能在 context 已部分更新後把 fault 改成 status return，讓 caller 繼續使用不一致
的 register／stack state。Wine upstream 沒有對 x64 做這項變更，因此不建議把它
當成「11.14 x64 修復」回植。

同樣地，不能只把 Wine 11.14 的完整 `signal_x86_64.c` 或 `unwind.c` 覆蓋到 CX26：

- CrossOver 26.3 在 `signal_x86_64.c` 有自己的 TEB／PEB 修補；
- 11.14 同檔還包含無 TEB frame 的 exit unwind 修正；
- 11.14 移除了部分 `WIN32_NO_STATUS`，依賴同步演進的 headers；
- 整份覆蓋會靜默丟失 CrossOver patches 或引入未配對的 header／ABI 假設。

### 6.4 預期功效

採方案 B 後，預期結果如下：

| 情況 | 目前 Cyder006 | 加入 11.14 NULL guard 後 |
|------|---------------|--------------------------|
| `func == NULL`、stack 可讀 | 把它視為 leaf frame，從 stack 猜下一個 RIP | 立即停止 frame walk |
| `func == NULL`、stack 不可讀 | page fault 被 Cyder guard 捕捉 | 不讀 stack，直接停止 |
| `func != NULL`、metadata 有效 | 正常 unwind | 不變 |
| `func != NULL`、metadata 無效／被修改 | page fault 被 Cyder guard 捕捉 | 不變，仍由 Cyder guard 捕捉 |
| 正常遊戲 render／D3D11 | 不受 NTDLL patch 直接影響 | 不變 |
| GRAP stack inspection | 已可通過 | 更接近 upstream／Windows 的停止邊界，但仍須實測 |

可預期的實際效益：

- 更早、更確定地終止不可靠的 stack walk；
- 減少無意義的 leaf unwind 與 SEH fault 成本；
- 降低從 stack data 誤判 return address、走入假 frame 的機率；
- 改善 profiler、crash reporter、安全模組在缺失 unwind metadata 時的穩定性；
- 保留目前已驗證能進入遊戲的非 NULL metadata 防護。

它不會直接改善：

- DX11 device 建立；
- WineD3D／DXVK 效能；
- MoltenVK 相容性；
- 網路登入或伺服器延遲；
- 通用 Wine 11.14 被 GRAP 關閉的 runtime 身分／行為差異。

### 6.5 可能副作用

最主要的行為變化是 **backtrace 可能變短**。x64 leaf function 可以沒有
`.pdata`／unwind entry；`RtlVirtualUnwind2(NULL)` 原本能嘗試從 stack pop return
address，但 Wine upstream 的 `RtlWalkFrameChain()` 選擇在這裡停止。

可能影響：

- JIT、手寫 assembly 或動態產生程式碼的 crash stack 少掉後續 frames；
- profiler／telemetry 的 stack fingerprint 改變；
- 依賴「猜測 leaf frame」的除錯工具看到較短 call chain；
- 安全模組取得的 frame 數量改變。

不過這正是 Wine 11.1–11.14 的既定行為，且 upstream exception test 明確要求在沒有
runtime function entry 時停止。因此它更像 Windows 相容性修正，而不是任意截斷。
對 GRAP 而言，較短但可信的 stack 通常比包含假 return address 的 stack 安全；仍不能
只靠推論，必須重跑登入、選角、進地圖及正常退出。

目前 Cyder page-fault guard 本身也有一項取捨：它把 frame-walk 內的 access
violation 收斂成「停止 stack walk」，因此 crash reporter 可能看不到原本會逃出的
fault。但保護範圍只包 `RtlVirtualUnwind2()`，不會吞掉遊戲其他位置的 access
violation。加入 NULL guard 不會擴大這個 SEH 範圍，反而讓 NULL 情況不必進入它。

### 6.6 驗證矩陣

方案 B 的 Cyder007 候選至少應比較 Cyder006 與下列項目：

1. upstream no-function-entry regression test；
2. Cyder non-NULL invalid unwind metadata regression test；
3. `tests/test-build-wine.sh` 的 CX26／CX25 patch 邊界；
4. NTDLL 既有 unwind／exception tests；
5. MapleStory Classic：DX11、登入、選服、選角、GRAP、進地圖、正常退出；
6. BlueCG 等既有 x86_64／PE32 遊戲煙霧測試；
7. crash log／diagnostics 是否仍能取得足夠 stack frames；
8. 與 Cyder006 相同 prefix 做 A/B，避免 bottle 差異干擾。

目前第 1–3 項已由 standalone x64 PE harness、build-script test 與乾淨 source
round-trip 通過；第 5 項也已由 Cyder007 候選完成登入、進地圖、切換頻道、商城與
正常退出。若只做一行 NULL guard 而不保留 Cyder page-fault guard，會失去本次已
實際驗證的「非 NULL 但 metadata 無效」保護，不建議取代 Cyder006。

## 7. 編譯

### 7.1 準備 source 與工具鏈

完整建置流程由專案腳本管理：

```bash
bash scripts/prepare-build-deps.sh --cx 26
```

它會使用：

```text
tools/archives/crossover-sources-26.3.0.tar.gz
tools/archives/llvm-mingw-20260616-ucrt-macos-universal.tar.xz
```

並準備：

```text
build/cx26/sources/wine
build/llvm-mingw-20260616-ucrt-macos-universal
```

若工具鏈已在其他受支援位置，`scripts/env-x86_64.sh` 會依序尋找，不需要複製到系統
Homebrew。

### 7.2 驗證 patch 可套用

```bash
patch --forward --batch --dry-run -s \
  -d build/cx26/sources/wine -p1 \
  < patches/wine-11.1-rtlwalkframechain-null-function.patch

patch --forward --batch --dry-run -s \
  -d build/cx26/sources/wine -p1 \
  < patches/cyder-ntdll-frame-walk-page-fault-guard.patch
```

若 source 已套用，應以相反順序做反向 dry-run：

```bash
patch --reverse --batch --dry-run -s \
  -d build/cx26/sources/wine -p1 \
  < patches/cyder-ntdll-frame-walk-page-fault-guard.patch

patch --reverse --batch --dry-run -s \
  -d build/cx26/sources/wine -p1 \
  < patches/wine-11.1-rtlwalkframechain-null-function.patch
```

`scripts/build-wine.sh` 已把這兩種情況處理成「套用」或「Already applied」，無法判定
時會 fail closed。它也會先移除既有 source tree 上的 Cyder006 合併修補，再依上述
順序套用兩個新 patch。

### 7.3 完整重建

正式的可重現方式：

```bash
bash scripts/build-graphics-stack.sh --cx 26 --install-deps
bash scripts/build-graphics-stack.sh --cx 26

bash scripts/build-wine.sh \
  --cx 26 \
  --with-vulkan \
  --vulkan-source crossover
```

首次建置需要依專案環境安裝 x86_64 dependencies 時：

```bash
bash scripts/build-wine.sh \
  --cx 26 \
  --install-deps \
  --with-vulkan \
  --vulkan-source crossover
```

若已經有經過驗證的 MoltenVK install tree，可省略 graphics stack 重建；若不需要
Vulkan，則明確改用 `--without-vulkan`，不要讓 configure 偶然偵測主機上的 library。

腳本會：

1. 準備 CX26 source 與 LLVM-MinGW；
2. 套用 Cyder patches；
3. 使用 Rosetta x86_64、`--enable-win64` 與 i386/x86_64 PE；
4. 建置到既有 `build64`；
5. 安裝到 `install/wine-cx26-x86_64`；
6. 收集 relocatable runtime dylibs。

### 7.4 本次採用的 incremental build

完整 Wine 重建耗時很長，而這次只修改
`dlls/ntdll/signal_x86_64.c`。專案已有相同 configure 狀態的
`build/cx26/sources/wine/build64`，因此先做 incremental build：

```bash
source scripts/env-x86_64.sh
cd build/cx26/sources/wine/build64

arch -x86_64 env \
  PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
  MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  make -j"$(sysctl -n hw.ncpu)" \
  dlls/ntdll/x86_64-windows/ntdll.dll
```

這會沿用既有 `build64` 的 configure 結果；如果 source、編譯器、configure options
或依賴版本已改變，應改做完整重建。

只安裝本次變更的 PE DLL。為避免覆蓋 Cyder006，本次先建立獨立候選 runtime：

```bash
cp -a \
  install/wine-cx26-x86_64 \
  tools/runtime/wine-cx26-maple-cyder007-candidate

cp \
  build/cx26/sources/wine/build64/dlls/ntdll/x86_64-windows/ntdll.dll \
  tools/runtime/wine-cx26-maple-cyder007-candidate/lib/wine/x86_64-windows/ntdll.dll
```

Cyder006 與 Cyder007 候選的未 strip NTDLL SHA-256：

```text
Cyder006
ef802ef474f15fb7e71a39d97f3fc3ea21f28356575b1e923f3d0064b1623c53

Cyder007 candidate
9a32d01eead59c22bf25fd32142b335dec25f8b08a2f30757d800980c3cd40fa
```

驗證命令：

```bash
shasum -a 256 \
  build/cx26/sources/wine/build64/dlls/ntdll/x86_64-windows/ntdll.dll \
  tools/runtime/wine-cx26-maple-cyder007-candidate/lib/wine/x86_64-windows/ntdll.dll
```

注意：incremental copy 不會更新 install tree 根目錄的 `version` 檔。正式引擎版本以
打包時的 `CYDER_ENGINE_VERSION_LABEL` 與 tarball 內的 `wine-x86_64/version` 為準，
不要用舊 install tree 的版本字串判斷新 DLL 是否已安裝。

## 8. 測試

### 8.1 自動測試

建置流程測試：

```bash
bash tests/test-build-wine.sh
```

它會確認：

- CX26 dry-run 先移除 obsolete Cyder006 patch，再依序包含 upstream 與 Cyder patch；
- CX25 dry-run 不包含任何一個 frame-walk patch；
- CX26 source、LLVM-MinGW、Rosetta、PE architectures 與 install path 正確；
- 完整 build 仍包含 `make`、`make install` 與 dylib bundling。

x64 NTDLL 行為回歸測試：

```bash
FRAME_WALK_WINE_RUNTIME="$PWD/tools/runtime/wine-cx26-maple-cyder007-candidate" \
  bash tests/test-ntdll-frame-walk-guard.sh
```

它用 LLVM-MinGW 建立真正的 x86_64 PE，並在一次執行中驗證：

1. 動態程式碼沒有 runtime function entry 時，frame walk 在可信邊界停止；
2. function entry 非 NULL、但 unwind metadata 是 `PAGE_NOACCESS` 時，不讓
   page fault 逃出或造成遞迴崩潰。

Cyder006 對第一個案例會安全返回但得到 12 個 frame，而正確 upstream 邊界是 2；
Cyder007 候選兩個案例均得到預期結果並通過。

其他基本檢查：

```bash
bash -n scripts/build-wine.sh
zsh -n scripts/run-maplestory-classic-debug.sh
git diff --check
```

### 8.2 Patch round-trip

應在全新解出的 CrossOver 26.3 source 上確認：

1. forward dry-run 成功；
2. 正式套用成功；
3. reverse dry-run 成功；
4. reverse 後檔案回到原始內容；
5. 再次 forward 套用成功。

這可以避免 patch 只因工作目錄已被手動修改而「看似成功」。

專案已把這個流程及 Cyder006 舊修補遷移做成測試：

```bash
bash tests/test-ntdll-frame-walk-patches.sh
```

### 8.3 DLL 與 artifact 驗證

正式引擎打包：

```bash
CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder006' \
CYDER_ENGINE_ARTIFACTS_DIR="$PWD/dist/artifacts/cx26.3-a6" \
VULKAN_MODE=with \
VULKAN_SOURCE=existing \
bash scripts/pack-engine-artifact.sh --force --xz
```

正式發佈時另設定 Developer ID：

```bash
SIGN_IDENTITY='Developer ID Application: <identity>' \
CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder006' \
CYDER_ENGINE_ARTIFACTS_DIR="$PWD/dist/artifacts/cx26.3-a6" \
VULKAN_MODE=with \
VULKAN_SOURCE=existing \
bash scripts/pack-engine-artifact.sh --force --xz
```

打包流程會在最終 archive 解壓後逐一驗證所有 Mach-O 簽章。本次正式封包驗證了
56 個 Mach-O，並保留 MoltenVK、不包含不可轉散布的 Apple GPTK。

最終 artifact：

```text
dist/artifacts/cx26.3-a6/
  engine-wine-x86_64-CX26-3-0-W11-Cyder006.tar.xz
```

SHA-256：

```text
431119089fb0b8659bd1b67823bdab2f37dce32d1bb2fc2b797cb929ff36ca00
```

### 8.4 遊戲煙霧測試

測試順序不可只停在「看到登入畫面」：

1. 啟動遊戲；
2. 確認沒有 `InitializeEngineGraphics failed`；
3. 等待「登入中，請稍候」消失；
4. 選擇伺服器與頻道；
5. 通過角色選擇；
6. 確認沒有「安全模組運作中／客戶端強制關閉(0)」；
7. 進入實際遊戲地圖；
8. 操作角色或開啟新手 UI，確認 render loop 仍持續；
9. 使用遊戲內「結束遊戲」；
10. 確認 Wine 與遊戲子程序正常結束。

本次 Cyder006 已完整通過上述流程。僅到選角不算通過，因為通用 Wine 11.14 曾在該
階段被 GRAP 強制關閉。

### 8.5 商城、同步模式與退出補充測試

Cyder 0.8.3／Cyder006 的人工 A/B 顯示：

| 同步模式 | 進入遊戲 | 商城 | 退出 |
|----------|----------|------|------|
| None | 通過 | 通過 | 卡住 |
| MSync | 本次在進入遊戲時卡住；較早測試曾偶爾通過 | 未測到 | 未測到 |
| ESync | 通過 | 通過 | 卡住 |

Cyder007 候選在 None 模式、開啟完整 `seh/unwind` trace 時，登入、進地圖及切換頻道
通過，但開商城後完全凍結。凍結期間沒有新的 stack overflow、未處理例外或 DXVK
device-lost；Wine 記錄到多個執行緒等待同一個 critical section。完整 trace 在 GRAP
初始化期間產生約 20 MB／22 萬行資料，因此這個商城結果不能直接當成候選引擎回歸。

改用低負擔 log 後，同一份 Cyder007 候選與 None 模式已通過登入、進地圖、商城及
遊戲內正常退出；沒有 frame-walk、DX11 或 DXVK 錯誤。這證明前一次商城凍結是重度
trace 改變時序，並非新增 NULL guard 的功能回歸。

主遊戲正常退出後，Nexon Game Security／GRAP helper 仍會常駐，這是該安全模組的
既有生命週期。實際清理方式是點擊 macOS 右上角的 Nexon 系統圖示，讓 NGS 圖示顯示
在 Dock，再對 Dock 圖示按右鍵結束；除錯時也可停止該 prefix 的 wineserver。不能
只因 GRAP helper 仍存在，就把遊戲內退出判定為失敗；應分別記錄「遊戲視窗／前端
正常退出」與「NGS 背景程序仍常駐」。Cyder 不應在一般退出時無條件強制停止 shared
prefix 的 wineserver，否則可能連帶終止同一 bottle 中仍在執行的其他程式。

目前較合理的基線是 None；MSync 暫時不應作為此遊戲的預設。NGS 常駐應視為獨立的
程序清理問題，不要為此擴大 NTDLL frame-walk patch。

### 8.6 診斷層級、記錄識別與 OEM 25 前景處理

Cyder 偏好設定的「除錯 → Wine 診斷記錄」提供三種全域層級：

| 層級 | `WINEDEBUG` | 用途 |
|------|-------------|------|
| 安靜（預設） | `-all` | 正常遊玩；避免 trace 改變 NGS、商城與退出時序 |
| 只記錄錯誤 | `-all,err+all,+timestamp,+pid,+tid` | 一般排障；自動保留本次 Wine launch log |
| 完整堆疊追蹤 | `-all,+timestamp,+pid,+tid,+seh,+unwind` | 短時間重現 exception／unwind；資料量大且可能造成假性凍結 |

`errors` 與 `unwind` 會自動開啟 Wine stdout/stderr 擷取；`quiet` 的一般啟動不建立
大量 Wine log。測試啟動仍會保留一份低輸出 launch preamble，方便確認設定。

每份 launch log 會記錄實際解析 symlink 後的 runtime 與 prefix、engine `version`、
`x86_64-windows/ntdll.dll` SHA-256、圖形後端、MSync／ESync、電源模式及診斷層級。
遊戲 argv 一律只寫入參數數量，額外環境變數也只寫 key；ServiceAccountID、OTP 或
其他登入值不會進入記錄。

OEM 25 的 `maplestory-cx26-blackxchg-foreground.patch` 是另一類修補：
`BlackXchg.aes` 啟動時不呼叫 macOS 的 foreground transform，避免短暫的防作弊 helper
搶走 MapleStory renderer 視窗焦點；OEM 對 `DwarfWebBrowserClass` 也使用
`SWP_NOACTIVATE`。這些是前景啟用／UX 處理，不是 `taskpolicy background`，也不會清理
退出後仍常駐的 GRAP／NGS。Classic 目前沒有觀察到 BlackXchg 搶焦點，因此不把該 patch
併入 NTDLL 穩定性修補；若日後出現可重現的焦點跳轉，再以獨立 patch 與 A/B 測試評估。

## 9. 為什麼不採用其他方案

### 直接換 Wine 11.14

新版 upstream Wine 對 frame lookup 較安全，但會改變 CrossOver patch set、圖形
runtime 與安全模組可見的執行環境。實測仍可能被 GRAP 終止，因此只適合 A/B。

### 只切換 WineD3D

WineD3D 會改變顯示、效能與視窗行為，但不能修正 NTDLL 例外遞迴；部分測試還會在
登入後關閉或留下空白視窗。

### 只補 DirectX 11

DX11 初始化失敗是另一條路徑。當遊戲已成功建立 D3D11 並顯示登入畫面後，繼續安裝
DirectX 元件不會處理 `RtlWalkFrameChain()`。

### 套用到 CX25

CX25 使用 Wine 10 基線。未做 source／ABI 比對與同等遊戲驗收前，不應跨 major
version 預設套用。

## 10. 維護與回歸注意事項

- 升級 CrossOver／Wine 時，先檢查 upstream `RtlWalkFrameChain()` 是否已有等價或更
  完整的保護；若 patch 已被 upstream 取代，讓 `apply_cyder_patch` 明確失敗並重新
  評估，不要模糊套用。
- 保留 CX26-only 自動測試，避免未來 refactor 意外把 patch 套到 CX25。
- 遊戲更新或 GRAP 更新後，至少重跑完整登入到地圖的 smoke test。
- Debug runtime、DXVK log 與 Wine trace 放在 `tools/runtime/`、
  `tools/debug-logs/` 或 `debug/`；前兩者已由 `.gitignore` 排除。
- 永遠不要提交登入 session token。
- 若再次看到「登入中」卡住，先確認使用中的引擎版本與實際載入的
  `x86_64-windows/ntdll.dll`，不要只看 App 顯示的版本名稱。

## 11. 相關檔案

| 檔案 | 用途 |
|------|------|
| `patches/wine-11.1-rtlwalkframechain-null-function.patch` | Wine upstream NULL function guard |
| `patches/cyder-ntdll-frame-walk-page-fault-guard.patch` | Cyder 非 NULL metadata page-fault guard |
| `patches/obsolete/cyder-ntdll-frame-walk-guard.patch` | 僅供既有 Cyder006 source tree 遷移 |
| `patches/README.md` | Patch 摘要與套用範圍 |
| `scripts/build-wine.sh` | CX26 自動套用與完整建置 |
| `scripts/run-maplestory-classic-debug.sh` | 不保存 token 的四參數測試啟動器 |
| `tests/test-build-wine.sh` | CX26 套用／CX25 排除測試 |
| `tests/test-ntdll-frame-walk-patches.sh` | 乾淨 source round-trip 與 Cyder006 遷移 |
| `tests/test-ntdll-frame-walk-guard.sh` | x64 PE frame-walk 行為回歸測試 |
| `tests/fixtures/ntdll-frame-walk-guard.c` | NULL entry 與不可讀 metadata 測試程式 |
| `scripts/pack-engine-artifact.sh` | 引擎 strip、簽署、封裝與解壓後驗證 |
| `docs/releases/v0.8.3.md` | Cyder 0.8.3 發佈摘要 |

## 12. 結論

本案的關鍵不是把「登入中」視為網路 timeout，也不是持續替換 DirectX 元件，而是把
圖形初始化、GRAP 相容性與 NTDLL 例外遞迴分成三層調查。

Wine 11.1–11.14 upstream guard 提供了相對 Wine 11.0 的重要線索：frame lookup
失敗後不應繼續 virtual unwind。Cyder 在 CrossOver 26.3 的 Wine 11.0 patch set
上先套用 upstream NULL guard，再加入受限的 page-fault guard，同時涵蓋「沒有
function entry」與「entry 存在但 metadata 無效」兩種邊界。這保留
CrossOver／GRAP 相容性，也不需要搬移整份 Wine 11.14 NTDLL；Cyder007 候選已通過
兩個自動回歸案例，以及實際遊戲的登入、進地圖、切換頻道、商城與正常退出測試。
