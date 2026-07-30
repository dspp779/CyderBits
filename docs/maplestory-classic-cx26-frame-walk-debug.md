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

Wine 11.8 的參考實作相較 Wine 11.0，會先以 `if (!func) break` 阻止 NULL
`RUNTIME_FUNCTION` 進入 `RtlVirtualUnwind2()`。Cyder 在 CrossOver 26 分支採用更
防禦性的延伸：以 Wine SEH 捕捉 stack walk 內的 page fault，將其轉成
`STATUS_ACCESS_VIOLATION`，並沿用既有的「非零狀態即停止目前 stack walk」行為。

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
scripts/run-maplestory-classic-debug.sh \
  <arg1> <session-token> <arg3> <arg4>
```

啟動器預設：

```text
WINEDLLOVERRIDES=d3d11,dxgi=n,b
WINEDEBUG=-all
```

這適合重複功能測試。要診斷例外時，應直接啟動 Wine 並暫時開啟精簡 trace：

```bash
mkdir -p tools/debug-logs

WINEPREFIX="$HOME/Library/Application Support/Cyder/bottles/shared" \
WINEDLLOVERRIDES='d3d11,dxgi=n,b' \
WINEDEBUG='+timestamp,+seh,+unwind' \
arch -x86_64 \
  /path/to/runtime/bin/wine \
  "$HOME/games/tms_cw/Maplestory_Classic.exe" \
  <arg1> <session-token> <arg3> <arg4> \
  >tools/debug-logs/maplestory-classic-seh.log 2>&1
```

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

本機的 `tools/archives/wine-11.14.tar.tar` 實際上是 xz 壓縮的 Wine 11.14 source
archive。新版 upstream Wine 能讓遊戲推進得更遠，顯示問題與 CrossOver 26 所基於的
Wine 11.0 程式碼差異很可能有關。

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

## 5. Wine 11.8 參考修正

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

版本考證注意事項：

- 官方 Wine 11.0 source 沒有這個 guard；
- Wine 11.8 source 有這個 guard；
- 額外核對 Wine 11.7 source 時也已看到相同行為。

本次核對下載檔的 SHA-256：

```text
Wine 11.0  c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701
Wine 11.7  b01ab21c79fede6c7bd531d469d99afd9dcdf53eb29af88adac6a332eb435f9f
Wine 11.8  53aa85995d4b97f0116a1c56b8a6a1417730ef59a277819d2d3d31364ea556b0
```

因此本文稱它為「Wine 11.8 參考實作中相對 Wine 11.0 的修正」，不主張該行一定在
11.8 才首次進入 upstream。

`if (!func) break` 只能處理 NULL。實際 CX26 trace 還可能遇到：

- `func` 非 NULL，但指向不可讀或過期的 metadata；
- metadata 在 lookup 後、unwind 前被保護模組改變；
- `RtlVirtualUnwind2()` 讀取 chained unwind data 時才發生 page fault。

所以 Cyder 沒有直接換成完整 Wine 11.8/11.14，也沒有只停在 NULL guard，而是保留
CX26 行為並擴大失敗邊界的保護。

## 6. 最終修補

正式 patch：

```text
patches/cyder-ntdll-frame-walk-guard.patch
```

核心變更：

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
  apply_cyder_patch "$OGOM/patches/cyder-ntdll-frame-walk-guard.patch"
fi
```

CX25 基於 Wine 10，跨越 Wine major version，且未用同一個失敗案例驗證，因此預設
不套用。需要支援 CX25 時，應重新比對該分支的 unwind ABI 與例外處理實作，不能直接
假設 patch 安全。

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
  < patches/cyder-ntdll-frame-walk-guard.patch
```

若 source 已套用，反向 dry-run 應成功：

```bash
patch --reverse --batch --dry-run -s \
  -d build/cx26/sources/wine -p1 \
  < patches/cyder-ntdll-frame-walk-guard.patch
```

`scripts/build-wine.sh` 已把這兩種情況處理成「套用」或「Already applied」，無法判定
時會 fail closed。

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

只安裝本次變更的 PE DLL：

```bash
cp \
  build/cx26/sources/wine/build64/dlls/ntdll/x86_64-windows/ntdll.dll \
  install/wine-cx26-x86_64/lib/wine/x86_64-windows/ntdll.dll
```

本次未 strip 的 build／install DLL SHA-256 相同：

```text
ef802ef474f15fb7e71a39d97f3fc3ea21f28356575b1e923f3d0064b1623c53
```

驗證命令：

```bash
shasum -a 256 \
  build/cx26/sources/wine/build64/dlls/ntdll/x86_64-windows/ntdll.dll \
  install/wine-cx26-x86_64/lib/wine/x86_64-windows/ntdll.dll
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

- CX26 dry-run 包含 `cyder-ntdll-frame-walk-guard.patch`；
- CX25 dry-run 不包含該 patch；
- CX26 source、LLVM-MinGW、Rosetta、PE architectures 與 install path 正確；
- 完整 build 仍包含 `make`、`make install` 與 dylib bundling。

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
| `patches/cyder-ntdll-frame-walk-guard.patch` | 正式 CX26 NTDLL 修補 |
| `patches/README.md` | Patch 摘要與套用範圍 |
| `scripts/build-wine.sh` | CX26 自動套用與完整建置 |
| `scripts/run-maplestory-classic-debug.sh` | 不保存 token 的四參數測試啟動器 |
| `tests/test-build-wine.sh` | CX26 套用／CX25 排除測試 |
| `scripts/pack-engine-artifact.sh` | 引擎 strip、簽署、封裝與解壓後驗證 |
| `docs/releases/v0.8.3.md` | Cyder 0.8.3 發佈摘要 |

## 12. 結論

本案的關鍵不是把「登入中」視為網路 timeout，也不是持續替換 DirectX 元件，而是把
圖形初始化、GRAP 相容性與 NTDLL 例外遞迴分成三層調查。

Wine 11.8 參考碼提供了相對 Wine 11.0 的重要線索：frame lookup 失敗後不應繼續
virtual unwind。Cyder 最終在 CrossOver 26.3 的 Wine 11.0 patch set 上加入受限的
page-fault guard，保留 CrossOver／GRAP 相容性，同時阻止無效 unwind metadata 導致
遞迴例外。這個最小修改比整體升級 Wine 更容易驗證，也已在實際遊戲流程中通過。
