# 台灣楓之谷在 macOS 的 CrossOver 相容性研究

最後更新：2026-07-23

**想直接在 Mac 上玩：** 請看 [macOS 玩家教學](macos-player-guide.md)。

本目錄其餘文件記錄台灣版楓之谷在 macOS／CrossOver 上的啟動研究。Beanfun 登入、QR code 與
OTP 取得程式已移至獨立專案 [CitrusGate](https://github.com/dspp779/CitrusGate)，不再由本專案維護；這裡只定義遊戲啟動端所消費的資料與
Wine/OEM runtime 的相容性契約。

**目前調查主線：** CX25 reverse bisect（無 OTP + OTP／進世界）已完成。進世界必要集為
OEM MoltenVK、dbghelp、kernelbase `.msf`、**整包 G**，且自行編譯引擎請用 `C:\MapleTest`。
CX26 對應契約見
[OEM CX25 修補總覽 §11.2](oem-cx25-maplestory-patches.md#112-cx26-forward-port-契約) 與
[MapleStoryPort ↔ CX26](maplestoryport-cx26-port.md)。

## 已完成結果

台灣版 V280 已使用 Nexon 北美官方 macOS 包內的 CrossOver OEM 25.0.1.38865 runtime
成功顯示、完成 Beanfun 登入，並由使用者實際遊玩。後續 fresh-prefix 對照與第二台乾淨
Mac 的實測，已把最小條件縮小為：

- 完整且版本一致的 OEM 25.0.1 engine；
- 由該 engine 自行建立的乾淨 win10_64 prefix；
- process 建立時即繼承 `zh_TW.UTF-8`，Windows code page 為 950；
- `cxbottle.conf` 注入 `RAW_AUDIO_PARSE=1`；
- 正確 working directory；
- 有效 OTP，且 argv 使用與該 OTP 綁定的 `ServiceAccountID`；
- BlackCipher／Nexon Game Security 與 NxOverlay 能在同一 Wine session 中正常建立並持續
  運作；
- WineD3D Vulkan 能建立實際遊戲 swapchain。

北美 Launcher、managed bottle、signed helper、alternate-loader socket、
`MachineGuid` 同步與 `CSMT=disabled` 均已由對照排除為必要條件。**預編譯 OEM binary**
可將遊戲留在 Documents，由 Wine 經 `Z:` 執行。**自行編譯 OEM／CX26 source** 進世界請改用
bottle 內 `C:\MapleTest`（APFS clone）；Documents `Z:` 在 source 上易出現「遊戲檔案損毀」。

## 與《新楓之谷：經典版》CX26 的關係（2026-07-31）

OEM-25（Wine 10／CrossOver OEM runtime）實測對同步機制與圖形後端較不敏感；經典版在
`CX26.3.0-W11-Cyder007` 上則常在商城進出／開始遊戲時因 **wineserver 無聲消失** 而凍結，
目前僅 **MSync + DXVK** 穩定。兩邊不是同一引擎、同一 hang 形狀，**不能**把 OEM「什麼
sync 都能玩」直接外推到經典版。

OEM 文件裡與 wineserver／排程最相關、且曾被明確分類的項目是**效能 workaround**（降低
wineserver 往返或 host `sched_yield`），bisect 已判定對無 OTP 畫面**非必要**；它們也
**不是**已證實的「防止 wineserver 進程死亡」修補。對照分析見
[經典版 wineserver 凍結紀錄](../../maplestory-classic-wineserver-hang.md) §8。

參考用 CX26 forward-port patch（**預設不套用**）在
[`patches/maplestory-cx26-*.patch`](../../../patches/) 與
[`patches/oem25-bisect/`](../../../patches/oem25-bisect/)。

## 文件索引

- [macOS 玩家教學](macos-player-guide.md)：美版 Launcher Wine → 橘子遊戲管理器 →
  CitrusGate／OTP 啟動的逐步操作與指令。
- [成功執行基線](oem25-tw-success-baseline.md)：可重現的 runtime、bottle、路徑、locale、
  argv 與驗收條件。
- [啟動 lifecycle 與防作弊影響](launch-lifecycle-and-anticheat.md)：從外部 OTP 交付、OEM
  helper、Wine、MapleStory、BlackCipher、NGS、renderer、overlay 到正常結束的完整狀態機。
- [CrossOver 25、26 與北美 OEM 觀察](crossover-macos-observations.md)：失敗對照、log
  證據、alternate loader 分析與已排除假設。
- [OEM engine 差異研究](oem-engine-differences.md)：fresh-prefix 最小條件、OEM-only
  `winemac.so`／`dbghelp.dll` 證據、一般版特別分支的封裝契約。
- [OEM CrossOver 25 楓之谷修補總覽](oem-cx25-maplestory-patches.md)：依功能補齊、Bug 修正、
  同步、效能與產品整合分類。**無 OTP + OTP／進世界 bisect 已完成**（進世界必要：MoltenVK、
  dbghelp、kernelbase `.msf`、整包 G；路徑：`C:\MapleTest`）。細節見
  [`patches/oem25-bisect/README.md`](../../../patches/oem25-bisect/README.md)。
- [MapleStoryPort 25.0.1 與 CrossOver 26.2 移植研究](maplestoryport-cx26-port.md)：
  source-level 差異、分層移植策略、建置與 A/B 驗證順序。
- [DXVK vs D3DMetal（本機筆記）](maplestory-dxvk-vs-d3dmetal.md)
- [經典版 CX26 wineserver 凍結](../../maplestory-classic-wineserver-hang.md)
- [經典版 CX26 frame-walk／登入卡住](../../maplestory-classic-cx26-frame-walk-debug.md)

## OTP 專案的介面邊界

本專案不取得、更新或保存 Beanfun Cookie／OTP。獨立 OTP 專案只需把下列兩個值交給
launcher：

```text
ServiceAccountID = T9...   # 必須與 OTP 所選帳號一致
OTP              = 短期一次性 WebStart OTP
```

遊戲命令列契約為：

```text
MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

若 `.exe` 的預設開啟程式是 Cyder，外部 OTP 程式可直接使用標準文件 association：

```sh
/usr/bin/open -n '/path/to/MapleStory.exe' --args \
  tw.login.maplestory.beanfun.com 8484 BeanFun '<ServiceAccountID>' '<OTP>'
```

也可明確指定 Cyder.app：

```sh
/usr/bin/open -n -a '/Applications/Cyder.app' '/path/to/MapleStory.exe' --args \
  tw.login.maplestory.beanfun.com 8484 BeanFun '<ServiceAccountID>' '<OTP>'
```

Cyder 不解析任何公開選項；EXE 由 LaunchServices 的 open-file event 送入，`--args` 後
全部是 MapleStory argv。此介面只負責保持 argv 邊界並轉送參數；楓之谷仍需使用成功
基線指定的 OEM runtime 與 bottle recipe。

本機 OEM 整合測試包可用以下方式建立：

```sh
bash scripts/create-cyder-oem-test-app.sh
```

產生的 `dist/Cyder-test.app` 不內含或重散布 Nexon／CodeWeavers runtime，而是驗證並使用
已安裝的 `/Applications/MapleStory Launcher.app`、OEM managed bottle 與 signed helper。

### OEM engine fresh-prefix 測試包

2026-07-20 的對照已確認完整 OEM bottle 不是必要條件。以下測試包內附 OEM engine，
第一次執行時從 engine 自帶的通用 `cxbottle.conf` 建立全新 private prefix，不讀取
`~/Library/Application Support/MapleStoryNA`：

```sh
bash scripts/create-cyder-oem-engine-test-app.sh
```

輸出為 `dist/Cyder-OEM-Engine-Test.app`。engine 使用 `.tar.xz`，目標 Mac 只需系統內建
`tar`，不依賴 Homebrew `zstd`。此 flavor 固定使用 `zh_TW.UTF-8`，並由
`cxbottle.conf` 的 `[EnvironmentVariables]` 注入 `RAW_AUDIO_PARSE=1`。

測試版直接啟動使用者選取的原始 `MapleStory.exe`。2026-07-20 以 fresh prefix 重測確認，
Documents 中的 macOS 路徑由 Wine 轉成 `Z:` 後，可以建立 MapleStory、BlackCipher、NGS、
Vulkan swapchain 與 NxOverlay；不需要 APFS clone，也不會產生第二份遊戲資料。
它預設指向成功基線的 `drive_c/MapleTest/MapleStory.exe`。測試 bridge 接受
`Cyder-test PATH ARG...`；若省略 PATH，則使用上述預設 EXE。這是 OEM helper 的獨立
測試工具，不是 Cyder.app 的公開 argv 介面。

`ServiceAccountID` 不是顯示名稱，也不是數字 SN。傳入顯示名稱時，遊戲可正常啟動並
顯示畫面，但伺服器會回覆「未登錄的帳號」。

### 一般名稱的 OEM 分支特別版

目前分支可建立仍名為 `Cyder.app` 的特別版：

```sh
bash scripts/create-cyder-maplestory-oem-app.sh
```

它沿用一般版的 `~/.cyder/runtime` 與 `~/Library/Application Support/Cyder`。若偵測到另一
engine 的既有 shared bottle，會先改名保存再建立 OEM fresh prefix；Wine 尚在使用 prefix
時不會切換。完整差異與安裝行為見 [OEM engine 差異研究](oem-engine-differences.md)。

## 版本庫與敏感資料

`debug/` 已由根目錄 `.gitignore` 排除。原始 Wine log、環境快照、截圖與 one-shot
`.ms-launch-args` 可能含 OTP、帳號 ID、socket 路徑或其他短期憑證，不應提交。文件只保留
足以重現判斷的去識別化事件、相對時序與結論。
