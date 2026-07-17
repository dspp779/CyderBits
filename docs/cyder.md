# Cyder 使用指南

**Cyder** 是 Windows `.exe` 一鍵啟動器：裝一次，直接執行任何 `.exe`。目前所有遊戲共用預設 bottle `bottles/shared`；路徑結構已預留未來加入多個 bottle。若要包成獨立的 macOS 遊戲 `.app`，請改用 [CyderBits 打包器](cyderbits.md)。

## 安裝 Cyder.app

需先在本機建好 Wine：

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

`create-cyder-app.sh` 會：

- 從 `dist/artifacts/engine-<CX26-winever>.tar.zst` 複製進 app（由 `pack-engine-artifact.sh` 預先建立；`create-cyder-app.sh` 缺檔時會自動打包）
- 首次啟動將 engine 實體解壓至無空白路徑 `~/.cyder/runtime/Engines/wine-x86_64/`（archive 內含 `wine-x86_64/` 目錄）
- 使用 `logo/cyder-logo.png` 產生 app 圖示
- 內含 Universal Swift launcher（arm64 + x86_64）、shell worker（`cyder_launcher.sh`）與 bootstrap helper（mono、tar、locale、hi-res）
- 在 `Info.plist` 宣告可開啟 `.exe`（`LSHandlerRank: Alternate`；不強制設為預設）

## 開啟 .exe

單獨開啟 `Cyder.app`、確認設定後，會以進度列依序顯示：**正在儲存設定…** → **正在準備遊戲執行元件…** → **正在準備遊戲環境…** → **正在套用新設定…**。之後從 Finder 開啟 `.exe` 會直接啟動，不顯示設定或準備視窗。

| 方式 | 操作 |
|------|------|
| **雙擊 Cyder** | 無參數時跳出檔案選擇器，選 `.exe` 後啟動 |
| **拖放** | 將 `.exe` 拖到 Cyder.app 圖示上 |
| **打開方式** | Finder 對 `.exe` 右鍵 → **打開方式** → Cyder；若要設為預設請按 **全部更改…** |

首次執行某 `.exe` 時會自動 bootstrap 共用 prefix（見下節），之後再開其他 `.exe` 不會重複安裝。

Cyder **不會**自動將自己設為 `.exe` 預設程式；`Info.plist` 僅向系統宣告可開啟 Windows 執行檔（`LSHandlerRank: Alternate`），是否設為預設由使用者在 Finder 自行決定。從 Finder **雙擊 `.exe`**（已設為預設）或拖放到 Cyder 時會直接啟動該檔（`Cyder.app` 內建 Swift 啟動器接收 open-document 事件）。

開發／除錯時可用 `scripts/cyder-exe-association.swift handlers` 查詢 Launch Services 狀態；若先前誤將 `public.executable` 設為 Cyder，可用 `cleanup` 還原（見 `docs/scripts.md`）。

### CLI（開發 / 除錯）

```bash
bash scripts/cyder_launcher.sh --engine-src install/wine-x86_64 /path/to/game.exe

# 只印出路徑，不裝引擎、不啟動
bash scripts/cyder_launcher.sh /path/to/game.exe --dry-run

# 只跑 bootstrap（mono、tar、高解析度）
bash scripts/cyder_launcher.sh --bootstrap-only --engine-src install/wine-x86_64
```

（`python3 scripts/cyder_launcher.py` 仍可用，會轉呼叫上述 shell 腳本。）

## Shared bottle 與 bootstrap

Cyder 目前使用一個預設 Wine bottle，所有 `.exe` 共用同一套 Windows 環境：

```text
~/.cyder/runtime/
  Engines/wine-x86_64/       # 無空白實體路徑的共用 Wine runtime

~/Library/Application Support/Cyder/
  bottles/shared/            # 預設 WINEPREFIX
    drive_c/windows/mono/    # wine-mono（.NET）
    drive_c/windows/syswow64/tar.exe   # GnuWin bsdtar（大 zip 解壓）
    system.reg / user.reg
    .cyder-bootstrap-v1      # bootstrap 完成 marker
  Addons/
    libarchive-2.4.12/       # tar 安裝來源（LGPL）
```

首次啟動（或 marker 不存在）時，`cyder_launcher.sh` 會依序：

1. 從 app 內 `engine-<version>.tar.zst` 解壓引擎至 `Engines/`（若尚未安裝或版本不同）
2. 若 `bottles/shared/system.reg` 不存在 → `wineboot -u` 建立 bottle
3. 安裝 **wine-mono**、**syswow64/tar.exe**（含 libarchive DLL）
4. 寫入 **Mac 高解析度** registry（RetinaMode + LogPixels=192）
5. 套用進階設定，並為遊戲畫面主程式 `bluecg.exe` 寫入專屬的 `ddraw=n,b` DLL override
6. 寫入 `.cyder-bootstrap-v1`；之後啟動跳過上述步驟

執行時環境：

- `WINEPREFIX` = `~/Library/Application Support/Cyder/bottles/shared`
- `cwd` = `.exe` 所在目錄
- `LANG` / `LC_ALL` = macOS `AppleLocale` → fallback `zh_TW.UTF-8`
- `WINEMSYNC=1`（僅在 MSync 開啟時）
- `WINEESYNC=1`（僅在 ESync 開啟時；與 MSync 互斥）

遊戲檔**不會**被複製或移動，仍留在原路徑。

## 進階設定（Phase 1）

Cyder 的 `設定…`（`⌘,`）、Dock 右鍵或執行檔選擇器的「進階設定…」可調整：

- MSync（預設關閉）
- ESync（預設關閉；開啟時會自動關閉 MSync）
- Retina Mode（預設開啟）
- DPI（預設 192 / 200%；非整數縮放可能讓部分老遊戲出現鋸齒或模糊）
- 字體平滑（預設 ClearType RGB，可選關閉或灰階；與 Retina Mode 獨立）
- Windows 字體方案：宋體 Songti TC（預設）或細明體 MingLiU
- 每遊戲能源模式：標準不套用 `taskpolicy`；省電使用 `taskpolicy -c background`。省電模式會降低 CPU 使用率，但可能造成畫面卡頓。Apple 晶片通常會優先使用節能核心；BlueCG 測試中 Wine CPU 能耗約為標準模式的 1/10，可能大幅延長續航。M1 Pro／Max 僅有 2 個節能核心，可能極度卡頓，不建議使用。

選擇細明體前，必須先在 macOS「字體簿」或 Wine prefix 中安裝合法取得的 MingLiU 字型。Cyder 只設定字體替代規則，不會散布或自動安裝該字型。

設定儲存在 `~/Library/Application Support/Cyder/settings.json`。全域顯示與字體設定會在控制項變更時，以原生 `sed` 直接更新未執行中的 Wine prefix；遊戲庫的個別設定則在遊戲設定頁按「套用」後保存，並在之後開啟該 EXE 時載入。

遊戲庫以 EXE 的 canonical path 計算穩定 ID，個別選項存放於 `perProfile`；這不代表一定建立獨立 bottle。遊戲設定頁直接開放 MSync、ESync、Retina、DPI、字體、能源模式、環境變數與命令列參數，命令列參數以單行文字直接接在 EXE 後，空白分隔；含空白的單一參數可用引號保留。提供「測試」以套用目前草稿後開啟遊戲，或按「套用」保存供之後從遊戲庫、Finder／直接 EXE 開啟時使用。每個 EXE 的能源模式使用 `powerMode=standard|energySaving`；啟動契約環境變數為 `CYDER_POWER_MODE=normal|background`。

當共用 prefix 沒有執行中的 wineserver，啟動 EXE 前會以快速路徑直接修改 `user.reg`，不會為了套用設定先啟動 Wine。若 prefix 已在執行，EXE 啟動流程會略過 registry 套用並直接開啟遊戲；設定仍保存在 `settings.json`，等 prefix 停止後的下一次啟動再套用。`wine reg` 不會用於一般 EXE 啟動，只保留給「偏好設定 → 進階 → 套用所有設定」。

Wine 的 macOS RetinaMode、DPI 與字體 registry 是整個 Wine session／bottle 的狀態，不能透過 `AppDefaults` 真正隔離到單一 EXE。Cyder 允許同一共用 prefix 同時開啟多個遊戲，不再以 session guard 阻擋；但執行中無法切換這些 registry 設定，因此同時執行的遊戲會沿用目前 wineserver 已載入的值。MSync、ESync、能源模式、環境變數與命令列參數仍會依各次啟動傳入，但最終相容性仍受 Wine 共用 wineserver 限制。

個別遊戲可能需要不同的同步設定；例如皮卡丘打排球目前應關閉 MSync／ESync，並使用無空白的 Wine runtime。請參考 [依遊戲問題文件](games/pikachu-volleyball/README.md)。

單獨開啟 `Cyder.app` 時會直接顯示進階設定。控制項一經變更就立即寫入 `settings.json`；未執行中的 prefix 會同步呼叫並等待原生 `sed` 修改 `user.reg`，不啟動 Wine 或 Rosetta。

進階頁的 **套用所有設定** 會使用 Wine `reg` 完整重寫所有受管理設定，供疑難排解使用。若偵測到執行中的遊戲，必須先確認關閉所有遊戲；強制關閉可能造成尚未儲存的遊戲進度遺失。

強制關閉可能造成尚未儲存的遊戲進度遺失，因此執行前會顯示警告。

直接由 Finder 打開 `.exe` 時，Cyder **不會**安裝、升級或重建環境。若 engine 不存在、版本不同或預設 bottle 尚未完成 bootstrap，只顯示提示，要求使用者先單獨開啟 `Cyder.app` 完成設定與環境建置。

直接啟動 EXE 時不再顯示 loading 或執行額外的初始化流程；Universal Cyder 只在 Swift 內檢查 engine、版本與 bootstrap marker，然後直接以 `/usr/bin/arch -x86_64 wine` 啟動。Rosetta 也不在此路徑預先檢查，由 `arch -x86_64` 交給 macOS 處理。

正式啟動路徑不設定 `WINEDLLOVERRIDES`。DLL 相容性設定存放在 prefix Registry；目前僅為 `bluecg.exe` 設定 `HKCU\Software\Wine\AppDefaults\bluecg.exe\DllOverrides` 的 `ddraw=native,builtin`，不影響 BlueLauncher 或其他 EXE。

Finder 啟動時，Cyder 會在呼叫 `/usr/bin/arch` 前監聽 CrossOver Wine 的 `WineAppWillActivateNotification`。收到與 `bottles/shared` 相同、且 `ActivatingAppPID` 已登記為 `regular/Foreground` 的通知後，macOS 14 以上會由 Cyder 先讓出焦點，再透過 cooperative activation 將所有 Wine 視窗帶到前方；macOS 12、13 則使用舊版 activation API 作為相容 fallback。送出一次 activation 後 Cyder 隨即退出；wrapper PID 不參與 activation，也不搜尋 process tree 或視窗 owner。若 Wine 未發出通知，隱藏 launcher最多等待 30 秒；Wine 仍在執行時只記錄 warning，不誤判為失敗。若 Wine 在顯示視窗前退出或被 signal 終止，Cyder 會顯示錯誤代碼、結束狀態與記錄內容。Wine stdout／stderr 會保存到每次 session 的獨立記錄，`Logs/last-launch.log` 指向最近一次啟動記錄。

命令列直接呼叫 `cyder_launcher.sh` 時仍以前景模式執行，方便腳本等待遊戲結束；只有 Universal Cyder 的 Finder EXE 入口會使用 Swift 直接啟動的分離模式。

EXE 模式會將 Cyder activation policy 設為 `prohibited`，所以 Dock 不會留下 Cyder 圖示。CX26 的 Wine Mac driver 會嘗試從 EXE 資源讀取應用程式圖示；若遊戲沒有可用的 Windows 圖示，Dock 可能顯示 Wine 的預設圖示。

若要比較 Wine 的 ShellExecute 啟動路徑，可暫時設定
`CYDER_WINE_START_MODE=start`；此時會執行 `wine start /wait /unix <exe>`。預設仍是直接執行
`wine <exe>`，因為 `start.exe` 的 Windows 顯示狀態不保證 macOS application 會切到 frontmost。

## BlueCG 注意事項

BlueCG（魔力寶貝）可透過 Cyder 直接開 `BlueLauncher.exe`；遊戲目錄（如 `BlueCrossgateNew/`）維持原位，Wine 環境來自 `bottles/shared`。

- 大客戶端 zip（`BlueCG_client.zip`）需要 prefix 內的 `syswow64/tar.exe`；bootstrap 會自動安裝。
- **共用 prefix 風險**：不同遊戲的 registry、已安裝元件可能互相影響。若某遊戲在 Cyder 下異常，可改用 [CyderBits](cyderbits.md) 建立**獨立 bottle** 的 game `.app`。
- 開發測試路徑 `bash scripts/run-bluecg.sh`（獨立 `WINEPREFIX`）**不受 Cyder 影響**，仍建議用於建置驗證。

詳見 [bluecg.md](bluecg.md)。

## 疑難排解

| 現象 | 建議 |
|------|------|
| 中文輸入變 `??` | 確認系統語言為繁中；Cyder 會讀 `AppleLocale` |
| 畫面糊 / 視窗太小 | bootstrap 已啟用高解析度；可對 `bottles/shared` 執行 `bash scripts/enable-mac-retina-hires.sh` |
| 大 zip 解壓失敗 / 找不到 tar | 確認 `bottles/shared/drive_c/windows/syswow64/tar.exe` 存在；刪除 `.cyder-bootstrap-v1` 後重開 Cyder 觸發 reinstall，或執行 `--bootstrap-only` |
| 找不到 Wine | 重新開啟 Cyder.app 以安裝共用引擎到 `Engines/` |
| Gecko 安裝提示 | Cyder 不修改 MSHTML；若遊戲確實不需要內嵌網頁，可對 `bottles/shared` 執行 `bash scripts/configure-mshtml.sh --disable` |
| 多遊戲衝突 / registry 混亂 | 改用 [CyderBits](cyderbits.md) 為該遊戲建立獨立 bottle 的 game `.app` |
| Dock 圖示 | Cyder 啟動 Wine 程序後即結束；Dock 上顯示的是 Wine / 遊戲視窗 |

## 錯誤記錄與診斷

Cyder 每次啟動都會建立獨立 session，記錄目前階段、shell worker 輸出、Wine stdout／stderr 與結束原因：

```text
~/Library/Application Support/Cyder/Logs/
  sessions/                 # 每次啟動及各子程序的獨立記錄
  session-state.json        # 目前／上次 session 是否正常完成
  last-error.json           # 最近一次結構化錯誤
  last-launch.log           # 最近一次 Wine 啟動記錄的連結
  bootstrap-error.log       # bootstrap 詳細錯誤（若有）
  engine-install.log        # engine 解壓與安裝記錄
```

除使用者主動取消外，非預期失敗會顯示 `CYD-*` 錯誤代碼、失敗階段、exit status 或 signal，並提供「複製診斷資訊」及「開啟記錄資料夾」。若 native process 來不及顯示對話框便 crash，Cyder 會在下次啟動時偵測未完成的 session 並提示查看上次記錄。

## 相關文件

- [cyderbits.md](cyderbits.md) — 打包 `.exe` 為 game `.app`（CyderBits）
- [bluecg.md](bluecg.md) — BlueCG 開發與驗證
- [scripts.md](scripts.md) — 腳本參考
- [superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md](superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md) — 產品分流設計
- [superpowers/specs/2026-07-06-wine-engine-slim-design.md](superpowers/specs/2026-07-06-wine-engine-slim-design.md) — **未來：** Wine Engine 瘦身（縮小 app 體積）
