# Wine Engine 瘦身設計（CrossOver configure 與發行產物）

> **原始日期**：2026-07-06
>
> **修訂日期**：2026-07-15
>
> **狀態**：方向已修訂，待量測式實作
>
> **Phase 1 計畫**：[2026-07-06-wine-engine-slim-phase1.md](../plans/2026-07-06-wine-engine-slim-phase1.md)
>
> **相關**：[configure 選項參考](../../wine-configure-options.md)、[Cyder 分流設計](2026-07-05-cyder-cyderbits-split-design.md)

## 1. 修訂結論

不再以 Sikarugir 的 PE 檔名、解壓大小或約 295 MB PE 作為 Cyder 的瘦身目標。Sikarugir 加上 dylib `Frameworks` 後同樣超過 1 GB，而目前 Cyder 完整引擎的 tar.xz 已只有約 162 MB；兩者解壓目錄的局部比較無法代表使用者下載成本，也不能證明 Sikarugir 刪除了哪些功能仍適合 Cyder。

新方向是：

1. 以 Cyder 自己的功能矩陣定義 CrossOver configure profiles。
2. 使用 Wine 官方 `install-lib` target，只安裝執行程式需要的檔案。
3. 優先調查 PE 內嵌 debug sections 的 strip／split，因為它們是解壓體積大的主要原因之一。
4. 同時量測「安裝大小」與「壓縮 artifact 大小」，以壓縮後下載大小為主要產品指標。
5. 不使用外部引擎 allowlist，也不預設刪除整類 Windows DLL；只有通過實際遊戲矩陣的能力才可停用。

Sikarugir 仍可作遊戲相容性或圖形行為對照，但不再是瘦身 golden image。

> **最新實測結果 (2026-07-24 / Cyder004)**：
> PE debug sections strip (`scripts/strip-wine-install.sh`) 已落地並納入打包流程，最新引擎 artifact `engine-wine-x86_64-CX26-3-0-W11-Cyder004.tar.xz` 壓縮包僅約 **55 MB**，解壓後的 runtime 目錄縮減至約 **423.3 MB**，最終產出的 App 打包僅約 **61 MB**。詳見 [cyder-runtime-size-study.md](../../cyder-runtime-size-study.md)。

## 2. 現況量測

### 2.1 本機 CX26 引擎（2026-07-15）

| 指標 | 現況 |
|---|---:|
| `install/wine-cx26-x86_64` | 約 1.1 GB |
| `lib/wine/i386-windows` | 約 469 MB |
| `lib/wine/x86_64-windows` | 約 530 MB |
| `include/` | 約 62 MB |
| `bin/` | 約 3 MB |
| `share/` | 約 11 MB |
| 完整 artifact 原始 bytes | 1,054,883,840 |
| `engine-wine-x86_64-CX26-11.0.tar.xz` | 162,637,668 bytes（約 155–162 MB，依顯示單位） |
| xz 比率 | 0.154 |

這表示「解壓超過 1 GB」與「下載只有約 162 MB」可以同時成立。未來報告不可只列 `du -sh`，必須同時列 archive bytes。

### 2.2 PE debug sections

目前 PE 含 DWARF debug sections。以 x86_64 `wined3d.dll` 為例，可看到：

- `.debug_info`
- `.debug_line`
- `.debug_loc`
- `.debug_ranges`
- `.debug_str`

這些 section 占未壓縮檔案的大部分，但重複性高、xz 壓縮率也高。因此 strip 很可能大幅降低安裝大小，卻只中度降低 archive；兩種收益必須分開量測。正式操作需使用能正確處理 MinGW PE/COFF 的 LLVM-MinGW `llvm-strip`／`llvm-objcopy`，macOS `/usr/bin/strip` 不支援這些 PE 檔。

### 2.3 可直接避免的開發檔

Wine 產生的 Makefile 已區分：

- `install-lib`：執行 Windows 程式需要的 runtime。
- `install-dev`：開發環境。
- `install`：全部安裝。

目前 `build-wine.sh` 使用 `make install`，因此把約 62 MB headers 與開發工具一起裝入。比起安裝後再用刪除腳本猜測，改用 `make install-lib` 更接近 CrossOver/Wine 的正式安裝模型，也較不容易誤刪 runtime。

## 3. 對 configure-first 方向的判定

方向合理，但不能假設每個 `--without-*` 都會移除對應 Windows DLL。

Wine configure 大多控制 host integration 或外部 library：例如 CUPS、GStreamer、GnuTLS、USB、Vulkan。停用後可能出現三種結果：

1. 整個 module 不建置，安裝與壓縮大小都下降。
2. Windows DLL 仍存在，但相關 backend／Unix library 不建置。
3. 只改變程式能力，檔案大小幾乎不變。

因此 configure flag 是「能力與依賴管理介面」，不是可靠的 per-DLL prune 介面。每個候選 flag 都要以 build/install/archive diff 證明收益。

已從 CX26 configure 確認較明確的例子：

- `--disable-win16` 會停用一批 `*.dll16`、`*.exe16`、VxD 與 WineVDM target；目前安裝約占 8.5 MB。
- `--without-vulkan` 會停用 winevulkan，並可避免打包 MoltenVK；目前 Vulkan 名稱相關 PE 約 3.3 MB，`libMoltenVK.dylib` 約 5.3 MB。
- `--disable-tests` 主要減少 build 時間與 build tree，不應先宣稱會縮小 `install-lib` artifact。
- Linux／周邊 backend 的 `--without-*` 在 macOS 上可能原本就未啟用，顯式關閉的主要價值是固定 capability contract，不保證省空間。

## 4. 目標與非目標

### 4.1 主要目標

- 讓發布引擎只包含 Cyder 遊戲範圍需要的 capability。
- 降低下載 archive、安裝後磁碟占用與不必要 dylib closure。
- 讓 configure 組合可版本化、可重現、可 A/B、可回退。
- 保留 PE32、DirectDraw/GDI、CoreAudio、字體、網路與已知遊戲元件需求。

### 4.2 非目標

- 不追求 Sikarugir 的檔名集合或解壓大小。
- 不以單一遊戲啟動成功取代多遊戲回歸。
- 不刪除整棵 `i386-windows`；現有遊戲含 PE32。
- 不關閉 OpenGL、CoreAudio、FreeType、pthread 或 unwind。
- 不刪 `mscoree.dll`；BlueLauncher／Wine Mono 路徑需要它。
- 不因 `mshtml=` 是目前預設，就直接從通用 engine 刪除所有 HTML／XML／script DLL。
- 不把 `--disable-tests` 的 build-time 改善計為發行 artifact 瘦身成果。

## 5. Configure profiles

### 5.1 `compat`（基準）

用途：完整相容性對照，接近目前發布 engine。

固定必要參數：

```text
--enable-win64
--enable-archs=i386,x86_64
--with-mingw=llvm-mingw
```

圖形可依 artifact 需求選擇 Vulkan；此 profile 不主動關閉媒體、TLS、USB 或 SDL。

### 5.2 `classic-safe`（建議候選）

用途：Cyder 已知 Win95～XP、PE32、DirectDraw/GDI 遊戲的保守精簡 profile。

第一批候選：

```text
--disable-tests
--disable-win16
--without-vulkan
--without-capi
--without-cups
--without-gphoto
--without-gssapi
--without-krb5
--without-opencl
--without-pcap
--without-pcsclite
--without-sane
--without-v4l2
--without-wayland
```

在 macOS 上原本就不可用或不會被偵測的 Linux backend，可為了 reproducibility 顯式關閉，但應另列為「預期零大小差異」，不可灌水計入成果。

預設保留：

- OpenGL／wined3d
- CoreAudio
- FreeType／字型路徑
- pthread／unwind
- GnuTLS（網路／TLS）
- FFmpeg／GStreamer（影片、Quartz、WMP 類遊戲）
- USB／SDL（控制器與周邊相容性）
- inotify（啟動器／檔案監看）
- NetAPI（舊遊戲區網功能尚未完整盤點）

`--without-vulkan` 是否成為正式預設，必須與「未來 D3D9+／DXVK」產品範圍一起決定；若 Cyder 要同時支援現代 3D，應發布另一個 engine flavor，而不是讓所有使用者共用矛盾的單一 profile。

### 5.3 `classic-minimal`（實驗）

只有在 `classic-safe` 完成後才建立。可逐項實驗停用媒體、TLS、USB、SDL、NetAPI 或 inotify，但每一項都要獨立 A/B；不可一次關閉後只測 BlueCG。

由於 LF2 計畫需要 `wmp9`、`quartz`、`devenum`，媒體路徑目前不適合放入 safe profile 的刪除項目。

## 6. 建議實作順序

### Phase 0 — 建立可信基準

- 每次 build 記錄 configure command、CrossOver source version、compiler version。
- 記錄 install bytes、PE/Unix/dylib 分項、archive bytes、壓縮比與檔案數。
- 輸出 embedded dylib closure 與最大檔案／section 報告。
- 保存 `compat` artifact 作 A/B 對照。

### Phase 1 — Runtime-only install 與 debug symbols

1. 將發布產物從 `make install` 改為 `make install-lib`。
2. 使用 LLVM-MinGW 工具在 staging copy 實驗：
   - strip debug sections；或
   - 將 debug symbols split 到不隨 app 發布的 symbols artifact。
3. 對 strip 前後做 codesign、wineboot、崩潰診斷可用性與 archive 比較。
4. 不修改開發用 install tree；正式 artifact 與 symbols 使用同一 engine ID/build ID 對應。

### Phase 2 — Configure profile 矩陣

- `compat`
- `compat + disable-tests`
- `compat + disable-win16`
- `compat + without-vulkan`
- `classic-safe`

每組都從 clean build 開始。比較 configure summary、產生 target、`install-lib` tree、dylib closure、archive 與測試矩陣，避免 config.cache 污染 A/B。

### Phase 3 — 證據式能力精簡

只合併有可量測收益且通過回歸的 flags。若 configure 後 Windows PE 仍接近原大小，接受這是 Wine 的架構結果；不要回頭使用 Sikarugir allowlist。

若仍需要更大幅精簡，下一步應是：

- 由 Cyder 自己的 capability manifest 控制 Wine module build/install；或
- 維護 `classic`／`modern` 多 engine flavors；或
- 只在 artifact staging 做由 dependency trace 與遊戲矩陣支持的 exclusion。

這些都屬高維護成本工作，需先證明壓縮後收益值得。

## 7. 改進方向

### 7.1 把「瘦身」拆成四種指標

| 指標 | 目的 |
|---|---|
| compressed bytes | 下載、app／release artifact 大小；主要產品指標 |
| installed bytes | 使用者磁碟占用；受 debug sections 影響大 |
| dylib closure | 啟動可靠性、簽章、依賴與攻擊面 |
| build time/cache | 開發效率；不可混算成使用者端節省 |

### 7.2 Symbols artifact

若 strip 可顯著降低 installed bytes，建議發布：

```text
engine-<id>.tar.xz
engine-<id>.symbols.tar.xz   # 不隨一般版本下載
```

crash report 保留 engine ID 與 build ID，需要深入分析時再取得對應 symbols。這比永久保留 1 GB debug PE 或完全丟失符號更平衡。

### 7.3 多 engine flavor

若產品同時要支援老 2D 與 Vulkan/DXVK，建議：

- `classic`：OpenGL、DirectDraw/GDI、媒體、TLS，無 Vulkan／Win16。
- `modern`：保留 Vulkan/MoltenVK 與新 3D 路徑。

不要為了單一通用 engine 保留所有功能後又宣稱 configure 瘦身；也不要為了 classic 使用者刪除 modern 使用者必要能力。

### 7.4 Capability report

artifact 應附 machine-readable manifest：

```json
{
  "profile": "classic-safe",
  "configure": ["--disable-win16", "--without-vulkan"],
  "engineBytes": 0,
  "archiveBytes": 0,
  "symbols": "split",
  "capabilities": {
    "pe32": true,
    "opengl": true,
    "coreaudio": true,
    "media": true,
    "tls": true,
    "vulkan": false,
    "win16": false
  }
}
```

Cyder UI 或 recipe 可依 capability 判斷，不必等遊戲啟動失敗才知道 engine 不支援。

## 8. 測試矩陣

### 8.1 自動化 gate

- clean configure／make／`install-lib`
- artifact manifest 與 configure command 一致
- dylib closure 不含 build machine 絕對路徑
- codesign 驗證
- wineboot fresh prefix
- `tests/test-cyder-bootstrap.sh`
- `scripts/verify-bluecg.sh`
- archive checksum 與解壓驗證

### 8.2 遊戲 gate

至少涵蓋：

- BlueCG：.NET／Mono、DirectDraw、CoreAudio、Retina。
- 皮卡丘排球：PE32、MSync／ESync 關閉。
- 大富翁 4：cnc-ddraw 路徑。
- LF2：vcrun2005、wmp9、quartz、devenum、vb6run 與影片／音訊。
- 一個 TLS／網路連線案例。
- 一個控制器／輸入案例；若目前沒有，USB／SDL 不得進 safe 移除清單。

### 8.3 合併門檻

- 所有必要 gate 通過。
- 沒有新增 runtime missing dylib／builtin DLL 錯誤。
- 每個 flag 都有獨立 size/capability diff。
- 若 configure profile 對 compressed artifact 的改善小於 5% 或 10 MB，且沒有明確降低依賴／攻擊面／build time 的其他價值，預設不增加發布 profile 複雜度。
- installed size 的大幅改善若主要來自 strip，需同時交付 symbols 對應策略。

## 9. 風險

1. configure 關閉 host library 不代表 PE DLL 消失，實際節省可能很小。
2. `config.cache` 可能污染 profile A/B；正式矩陣必須 clean build 或分開 build directory/cache。
3. strip 工具若選錯會破壞 PE；macOS `/usr/bin/strip` 不可用於這批 MinGW PE。
4. 關閉媒體／TLS 很容易在 launcher 正常、進遊戲或播放影片時才失敗。
5. 解壓大小下降不一定等比例改善 tar.xz；必須以 archive bytes 驗收。
6. 多 engine flavor 會增加下載、測試與 migration 成本，只有產品範圍真的分裂時才採用。

## 10. 決策記錄

- [x] Sikarugir 不再作瘦身 golden allowlist／尺寸目標。
- [x] 主要策略改為 CrossOver configure profiles + runtime-only install。
- [x] 同時評估 split/strip debug symbols。
- [x] 壓縮 artifact bytes 為主要產品指標。
- [ ] `classic-safe` 是否正式關閉 Vulkan。
- [ ] 是否需要 `classic`／`modern` 兩種 engine flavor。
- [ ] symbols artifact 的儲存與 crash report 對應方式。
