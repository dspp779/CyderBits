# Cities Skylines II 支援可行性與驗收方案

評估日期：2026-10-28。結論：可先整合不修改遊戲檔案的實驗性啟動指引與 DXMT 候選規則；目前不能宣稱 Cyder 已支援 CS2，亦沒有足夠依據自動套用上游的十項修補。

本機基準：CyderBits HEAD `d080fec15b70132fdc79dad08964c37aeea4b803`、engine HEAD `86796814441200b27ed9d11ab39f293ab66cb7db`，兩者均已有未提交工作。本次評估以工作樹為準，未建置或替換 engine。

## 證據與範圍

[Issue #10](https://github.com/dspp779/CyderBits/issues/10) 由 mingtsay 於 2026-09-08 提出；本次 GitHub 查詢仍為 open、comments 0。以 Cities 關鍵字搜尋該 repository 的 PR 未命中；這不是所有分支都沒有工作的證明。

[上游 README](https://github.com/macgameport/cities-skylines-2-macos/blob/main/README.md) 的 2026-10-16 狀態報告涵蓋遊玩、存檔、模組下載與載入，推薦自行編譯 Wine 11.16 + DXMT。這些是上游環境的結果，不能移植為 Cyder 的驗收紀錄。

必須連同 [build-engine-1116.sh](https://github.com/macgameport/cities-skylines-2-macos/blob/main/scripts/build-engine-1116.sh) 閱讀「stock」：腳本仍套用 `wineandaqua-dxmt.patch`，另加入 win32u visible-rect 修正，複用 wrapper 的 DXMT 與相依 dylib，並調整 rpath。README 還描述自行修改的 Wine／DXMT remote-layer 配對。因此比較單位是完整 engine、graphics payload、相依庫與啟動流程，不是 11.0 對 11.16 的單一版本比較。

## 責任分層

| 問題 | 現有能力與限制 | 支援方式 |
|---|---|---|
| Cities2.exe 選 DXMT | CompatDB 可 process-local 選 graphics_backend；不能驗證登入或遊戲完整性 | 停用候選規則，實機驗收後再啟用 |
| Paradox Launcher | compiler 能編碼 replacement，但現行 standalone runtime 不執行它 | App 匯入及直接選 Cities2.exe；不攔截其他 bootstrapper-v2.exe |
| Steam 授權與保持登入 | CompatDB 不啟動或管理另一程序 | 使用同一 bottle、同一 engine 的 Steam，先正常登入，再直接啟動遊戲 |
| 視窗切換與 DXMT 初始化 | Wine mac driver、DXMT PE/unix ABI、presentation 路徑共同影響 | engine 小型重現程式與遊戲 A/B；先採 Fullscreen Window |
| 遊戲 IO 與 Mods | 規則不能改 managed IL 或 native DLL | 先測原檔；逐項重現後決定 engine 修復或獨立遊戲修補 |
| cohtml COM release | 跳過 Release 會洩漏參照；DXMT 需要性未確認 | 預設不套，長時間測試原檔 |

現行實作依據：`compatdb/FORMAT.md`、engine `runtime/cxcompatdb/cxcompatdb.c`。後者對 SET_ENV、UNSET_ENV、REPLACE_EXECUTABLE、WINED3D_RENDERER 只略過；不要把 schema 能力當成 shipped runtime 能力。v1 沒有 shell hook 或遊戲 DLL 修改 action。

## Cyder 與上游的差異

Cyder 工作樹 metadata 為 CX26.3.0／Wine 11.0、Cyder012。已包含 A6 backing 同步與其他專案修補，但這不能證明包含上游 11.16 的所有 presentation 行為，更不能由 MapleStory 專屬 fullscreen 修補推論 CS2 正常。

Cyder 的 engine 與 graphics 分包：`ensure-graphics` 連接 engine `lib/dxmt` 到 runtime `current-dxmt`，把同版 32/64 位元 winemetal.dll 放入 prefix，unix winemetal.so 留在 payload。CompatDB 以 builtin + prepend 選 DLL，不應將上游 wrapper 的 DLL 直接覆蓋進 Cyder。本評估以 Apple Silicon 為目標；App 的 DXMT gate 檢查 macOS 15+ 與完整 payload；engine 的一般 10.15 floor 不等於 DXMT 能在 10.15 使用。

上游 README 的 PE 是 Porting Kit `v0.80-17-g79f6279`，unix 半邊為 v0.80 加 remote-layer 修正。Cyder 同樣標示 v0.80 仍不足以證明二進位與 ABI 等價。先記錄兩側 payload SHA-256、來源 revision、winemac exports、engine manifest 與實際載入路徑，再測最小 D3D11 device/swapchain、resize、destroy/recreate 與多次 Cmd-Tab。CX 的 `d3dmetal.c` 已輸出 `macdrv_functions`；單有此符號不能證明 remote-layer 路徑相同。

上游將 exclusive fullscreen 凍結描述為新舊 swapchain 呈現問題，新組合實測消失。Cyder A6 改的是 backing 同步，尚未證明兩者有相同因果。優先使用 Fullscreen Window；exclusive fullscreen 保留為比較項。只有最小重現確認差異後才考慮 backport，且須回歸其他遊戲、Steam 與 minOS，不升級整個產品 engine 來試運氣。

Steam UI 和登入要分開驗收：上游 stock 11.16 曾有黑色 storefront，但 tray 模式仍能登入、授權與下載 Mods；修復可見 UI 需要 Wine 和 DXMT 配對工作。Cyder 已對 steam.exe 加 `-system-composer -no-cef-sandbox`，WebHelper 有既有 CompatDB 參數；不全域改動這些設定，也不引入 CEF shim 或登入自動化。上游曾把缺少相依 dylib 誤認為 DXMT 登入缺陷，應先檢查 fonts、TLS、rpath 與依賴載入。

## 先測不修改遊戲檔案的流程

1. 備份存檔，使用獨立測試 bottle；確認 Steam 合法安裝的遊戲可正常驗證，記錄遊戲版本、Steam build ID、原始 DLL 雜湊。
2. 用 Cyder 現有流程啟動該 bottle 的 Windows Steam。正常登入並等待授權同步；`-silent` 僅為已登入後的選項，不能代替登入確認。保持它在背景，避免切換 engine 或終止該 bottle 的 wineserver。
3. 匯入同一 bottle 內的 `Cities2.exe`，使用包含空格的完整路徑，工作目錄設遊戲安裝目錄，手動選 DXMT。直接執行遊戲避開 Paradox Launcher，不改名、不替換 launcher 或 steam_api DLL，不偽造授權資訊。
4. 遊戲選 Fullscreen Window。若啟動前無法設定，可單獨試 Unity `-screen-fullscreen 0` 作視窗模式診斷；它不等同 borderless，尚未在 Cyder CS2 驗證，不加入自動規則。不要用 explorer virtual desktop 作預設。
5. Steam 與遊戲要有分開的生命週期；若 App 結束一個遊戲會清掉整個 bottle，先解決執行擁有權問題再提供一鍵雙程序啟動。不可用固定 sleep 宣稱已登入；需逾時、可取消、失敗提示，沿用既有 Steam 程序，不儲存憑證。

候選規則 `game.cities-skylines-2.dxmt` 保持 `enabled: false`，只有 graphics_backend，不強加 Unity 參數。名稱匹配不足以作 DLL 修補授權；即使名稱被偽裝，也不能進入任何寫入流程。

## 遊戲修補判斷與前置條件

以 [2026-10 修補清單](https://github.com/macgameport/cities-skylines-2-macos/blob/main/docs/patch-inventory.md) 為準，1.6.2f1／Steam build 25127643 的十項為 cohtml、colossal_io、longfile、asset_database、fshandle，以及 PDX.SDK 的 mkparent、lockbypass、longdelete、createfile、lockleak。它們跨 native plugin、Colossal.IO、AssetDatabase、mscorlib 與 PDX.SDK；不能沿用 Issue 中「4 個核心 DLL」的簡化描述或舊偏移量。

[Wine 11 更正紀錄](https://github.com/macgameport/cities-skylines-2-macos/blob/main/docs/wine-bugs/FINDING-wine11-fixes-it.md) 已撤回早期把 garbage errno 歸因於原生 Win32 API 的說法，轉為 Mono P/Invoke capture。Wine 11 上六項 errno 修補退役；handle 問題仍有修補與殘餘錯誤。不要因為都叫 Wine 11 就宣稱 Cyder 已驗證相同結果，也不要根據清單尾端較舊的建議再提同一個已撤回 Wine bug。

處理順序：原檔測試 → 精準重現 → 比較兩個 engine → 單項修補消融。cohtml 不是 allocator 修復，而是跳過捕捉 pipeline state 後的 COM Release；可能長期洩漏，DXMT 是否需要未充分驗證。PDX lockleak 的 catch 缺少 dispose 是遊戲 managed-code 缺陷，Wine 版本本身無法替遊戲加 finally；lockbypass 強制忽略失敗則可能掩蓋同步問題，不建議自動化。檔案 metadata 與 handle 問題須用 pristine Unity Mono 加不存在／存在檔案及並行下載重現，不能只看主選單或 IOException 計數。

目前不提供 writer，也不下載或執行社群 repatch.sh。未取得可審核的原始完整 SHA-256 與 Cyder 實測前，沒有任何可自動套用的版本。若未來導入獨立工具，以下是不可省略的契約：

- 發行者維護的版本化 allowlist，同時精確匹配遊戲版本、Steam build ID、每個 DLL 的完整原始 SHA-256、預期輸出 SHA-256、PE/IL 位置及原始位元組；不能讓使用者任意指定雜湊就升格成可信修補。
- 顯示修補原因、檔案、已知風險與還原方式，逐次明確同意；排除所有授權驗證繞過。
- 遊戲及相關寫入程序完全停止；鎖定交易，拒絕 symlink、路徑逃逸、不可信檔案與權限不足。備份以版本及原始雜湊命名並驗證，不覆蓋舊備份。
- 全部 preflight 成功後在同卷暫存輸出，驗證輸出與 PE/IL 結構，保留可復原 journal，再逐檔 atomic rename。多檔交易本身並非一次 atomic，任一步失敗或斷電下次啟動須先回復整筆，不能啟動混合狀態。
- 已是精確預期輸出且 journal／備份一致時為 no-op；原檔和已修補檔混合、未知輸出、備份缺失都拒絕。重新檢查寫入前雜湊以防更新競態。
- Steam 更新、驗證檔案或版本改變後拒絕套用。還原時也驗證現存輸出，絕不拿舊備份覆蓋新遊戲；提供 Steam 驗證復原路徑。

未來 writer 的離線必要測試：未知版本、單一 hash 不符、更新前後 race、拒絕同意、備份毀損、磁碟不足、第二檔寫入失敗、斷電 journal recovery、重跑 no-op、混合狀態、更新後拒絕還原、symlink／逃逸，以及 IL branch/EH/stack 與 PE section 映射。這些交易測試目前尚未實作，因為本次沒有 writer。

## 驗收與 Issue 10 推進

| 分類 | 具體項目與完成門檻 |
|---|---|
| 可直接整合 | 停用 DXMT 規則、直接匯入遊戲指引、CompatDB runtime 限制更正、離線匹配與參數隔離測試；compiled CDB 必須保持相同 |
| 額外 engine 工作 | D3D11／swapchain 最小 probe、Mono IO 與 bcrypt 正常有效簽章 probe、remote-layer ABI 對照。確認重現才提出 narrow patch；維持 host minOS 10.15、DXMT 例外 15.0 |
| 實機遊戲驗證 | 原檔到主選單、建城、存檔重載、設定與快捷鍵持久化、Steam 重啟後仍登入、Paradox Mods 新下載／刪除重下載／載入；borderless 和 exclusive 各多次 Cmd-Tab，長時間觀察 COM／GPU 記憶體 |
| 不建議自動化 | cohtml Release 跳過、lockbypass、舊偏移量、遠端 shell、一鍵登入、launcher 全域替換、任何授權繞過 |

A/B 使用相同硬體、macOS、遊戲版本與 pristine DLL，記錄完整 engine 和 graphics hash；先固定 payload 比較 engine，若 ABI 不相容則標為不同完整 stack，不能歸因於單一 Wine 變動。再逐項比較補丁與 presentation。上游成功組合作獨立對照，不混用正在執行的 prefix／wineserver。每次記錄有效 backend、載入路徑、登入結果、視窗模式、錯誤原文、正常退出與存檔結果；不能由 HUD 或主選單推出 Mods 成功。

Issue #10 建議維持 open，先標記為待 Cyder 實測的實驗性支援。第一階段交付安全指引與停用規則；第二階段完成無遊戲 probe 及原檔實測；第三階段只有必要時才開獨立修補工具工作，通過上述交易測試後才談使用者 opt-in。啟用規則和宣稱可玩是不同門檻；未通過遊戲與 Mods 驗收前不發布相容性認證。

本次離線測試位於 `tests/test-cyder-compatdb-data.sh`：驗證候選規則、啟用副本的 DXMT 編碼、排除其他 EXE、拒絕 shell_hook／binary_patch，並檢查直接遊戲參數與 Steam 參數隔離。它們不能驗證登入、Metal 初始化、視窗切換或 DLL 交易安全。

本次驗證結果：`test-cyder-compatdb-data.sh`、`test-cyder-ensure-graphics.sh` 通過；前者包含兩次編譯決定性、bundled golden 與 compiled CDB 的逐位元比較。`git diff --check` 通過。未跑全套或實機測試。測試依賴安裝於臨時 venv，未變更專案依賴檔。
