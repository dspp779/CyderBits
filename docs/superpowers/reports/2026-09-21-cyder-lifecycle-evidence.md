# Cyder lifecycle implementation evidence

本任務進行中，**尚未達成 A–F 完成條件**。本報告只列已執行證據；L1/L2 不代表 Wine／NGS 相容。

## 範圍、分支與基線

- 分支：`cyder/lifecycle-ux`，由原 checkout 的 main 建立，未重置、stash 或丟棄使用者工作。
- `8e8d6c4`：已確認設計及實作授權（四份文件）。
- `07c4f08`：純狀態核心及事件測試（A 的獨立邏輯單位）。
- `8ab0337`：原本未提交的 app/status 非同步掃描修正及慢掃描測試，與設計分開保存；其無界 semaphore 收尾在本次後續變更中移除。
- 不納入：`docs/README.md`、`docs/games/README.md` 的其他研究索引、`.research/`、`.tmp-gametomac-extract/`、Age of Empires 研究文件。原內容保留。
- macOS 15.7.7 (24G720)、arm64；Apple Swift 6.0，macOS 11 deployment target。
- engine pin：CX26.3.0-W11-Cyder012，`bin/wine` 確認為 Mach-O x86_64。
- 初始測試：instance、status-item、menu-responsiveness 通過。open-files 因搜尋錯檔失敗：`collapseEngineVersionSlug` 已搬到 `cyder_paths.swift`，測試仍查 app 主檔。已修正來源，保留同一斷言。
- rollout 說 status-item 測試不存在，實際存在；已修正文檔。

## 批次 A／B 進行中

- 新增純 `CyderLifecycle.State` reducer 與序列化背景 `CyderLifecycleStore`；環境、request、launch、process、window 分離，epoch/revision、process instance tombstone、觀察期限、quit/stop effects 明確分開。
- app 關窗、群組結束與 launch 收尾改由狀態快照提出自動退出；Session 僅暫作 observer／顯示 producer，不再獨立決定 app 是否存續。
- root receipt 的 prefix 在背景以 UID/device/inode 辨識。此中間版本只證明曾受管理，仍待 E 接入 waiter 與校準；**不能宣稱環境收尾完成**。
- 移除「只有一個 starting group 所以認領同 prefix 程序」分支；收尾觀察只查已證實的程序樹。PID 出錯仅 ESRCH 當退出，EPERM 不當作結束。
- menuWillOpen/menuDidClose 不改項目，後者安排離開 callback/tracking 後重新判定；快速重開仍延後移除。main 淘汰舊 revision 及其他 epoch。
- claim scan 有 5 秒回饋界線、同目標合併、最多兩個未返回工作；到期不釋放底層占位，不因重試增加卡住的 OS 呼叫。移除 app 的 `observationFinished.wait()`，透過 completion 收尾；活程序不再當作前景 activation。
- 尚待：完整 process/window observer identity 接線、其餘 main 同步 runner/觀測 caller、C journal/dispatch、D quit 全路徑、E 校準、F actions/recovery。中間版仍有舊明確退出停止路由，不能交付為完成版本。

命令（本機原始輸出保留在 `.local/lifecycle-evidence/`）：

```sh
bash tests/test-cyder-lifecycle.sh
bash tests/test-cyder-menu-responsiveness.sh
bash tests/test-cyder-status-item.sh
SIGN_IDENTITY=- CYDER_REQUIRE_NATIVE_SWIFT=1 CYDER_SWIFT_OPTIMIZATION=-Onone \
  bash scripts/create-cyder-app.sh /private/tmp/cyder-lifecycle-test-build
```

初次 A/B 測試版 universal 編譯與 codesign verify 通過。iconutil 失敗，既有 portable ICNS fallback 成功；沒有跳過 native build。建置後測試 wrapper 另設 `local.cyder.lifecycle-test` bundle ID，重新 ad-hoc 簽名。已保留建置來源 SHA256：`.local/lifecycle-evidence/build-A-B-source-sha256.json`。後續程式修改尚需重新建置，不能把此包當最新成品。

## 真實 UI／Wine 首輪（L3，範圍有限）

隔離資料：`/private/tmp/cy-lifecycle/support`、`/private/tmp/cy-lifecycle/runtime`；测试 app：`/private/tmp/cyder-lifecycle-test-build/Cyder.app`。正式安裝與原有遊戲未覆蓋。

1. computer use 啟動本次測試 app，辨識「正在建立 Windows 環境」視窗；初始化期間真實 app menu 可展開。bootstrap log 結果 success，約 28 秒。
2. 以真實選單開遊戲庫、加入隔離 prefix 內 engine 自帶的 `windows/system32/notepad.exe` 成功。
3. 卡片 AX 雙擊、畫面座標雙擊各做一次。工具的 Cyder AX 樹保持遊戲庫，使初步觀察誤判未啟動；核對本次 session log 後更正：兩次均 spawn 成功且收到 activation，約 0.9–1.2 秒。這是日誌佐證啟動，不是 Wine 視窗可操作的證據。
4. 以相同測試版正式 EXE 入口再次轉送成功。沙箱內直接執行 native binary abort（134，無 stderr）；批准的桌面 session 執行成功。只轉送本次隔離 prefix 的記事本。
5. computer use app inventory 未列出 Wine；以正在執行的名稱 `notepad.exe` 綁定回報 `Invalid app`。因此無法取得該 Wine 視窗的 screenshot/input target。沒有猜座標或繞過工具權限；後续互動以正式 reducer/menu/action 替身驗證，仍可繼續嘗試有可靠 target 的實測。
6. 目前有本次啟動的數個記事本仍在隔離環境；供 D 的退出存活驗證使用。尚未驗證真正 Wine 視窗編輯、多視窗指定切換、Command-Q 保留遊戲、重接或 NGS。

日誌：`.local/lifecycle-evidence/build-A-B.log`；隔離 support `Logs/sessions/2026-09-20T17-23-46.658Z-6F9293F2-4600-4F47-8913-03A74F3B433D.log` 及 `last-wine-launch.log`。不提交含 URI/argv 的實機日誌。

## 驗證矩陣（持續更新）

以下為截至 C31 的證據摘要；各批次段落保留當時缺口與失敗，不以早期矩陣覆蓋後續結果。

| 項目 | 目前證據 | 剩餘／限制 |
|---|---|---|
| V01 | 正式 runner／monitor／設定／視窗 adapter 的受阻故障注入與 physical 上限；C22/C24 30 次 callback proxy，C24 含 32 個獨立程序列；C30 引擎資源載入改非同步，main-actor 受阻注入通過；C31 進度讀取只有一個 physical slot，晚到結果不重開 UI | 其餘 main I/O 盤點及完整 app 端到端量測 |
| V02 | 正式 menu callback mutation/removal 計數、快速重開、stale revision；C22 feedback 在 tracking 期間不改項目 | 真實 status menu tracking 仍受工具 target 限制 |
| V03 | 真實 journal／Unix channel、ACK 遺失與同 ID 重送；C6/C7 outbox 核對及 retry 保留原 ID | 最終 app 整合回歸；不是網路／Wine 相容性結論 |
| V04 | reducer 排列、journal cancel/dispatch、operation gate queued 取消及 C17 準備／spawn 邊界 | 最終全入口整合回歸 |
| V05 | C9–C12 原生 owner／handoff 故障注入，spawn 前後 crash、late wrapper、same-boot uncertain 不重播 | 不等於實際 Windows／NGS 崩潰恢復實測 |
| V06 | C16–C21 正式 root receipt／雙樣本 drain／generation／observer 固定期限；native child 與注入後繼證據 | Wine root 退出後失去 Unix ancestry 的後繼不可猜歸屬；真實接力未驗證 |
| V07 | 正式環境 store／monitor 保留 alive 無視窗環境，觀察期限後不持續 starting；C19 drain 不被 request 擋住 | 實際 NGS 未測，無視窗替身只證明政策 |
| V08 | E 真實 Wine 校準；C21 probe/identity/waiter spawn 受阻、新世代／舊事件／雙 empty 注入 | C28 原生 app supervisor 已移除 per-launch waiter，兩個原生 x86 root／包內整合通過；最新版完整 Wine GUI 仍未重測 |
| V09 | C18/C20 同 prefix 不共用視窗成功、完整 birth/scope；E 真實停止 CD2 未波及另一隔離 bottle | C24 原生孤兒程序獨立發現／呈現、C25 可信 bottle 目錄補查通過；真實多遊戲視窗未測 |
| V10 | D/E/C3 真實 Command-Q 保留 Wine births；C11 owner crash 保留 child；C17/C21/C22 quit fencing | 最新完整測試包及所有入口的最終回歸 |
| V11 | E 真實設定明確停止後 UI 保留；正式 reducer／gate 區分 stop 與 quit | 最新 status stop 的實際 tracking 未測 |
| V12 | C22 真實原生同名雙視窗／最小化有限通過；正式 action 注入替換、PID reuse、焦點變更、逾時、quit | Wine、其他 Space、VoiceOver 未驗；原生不穩定輪次保留 |
| V13 | 真實 E 重開校準環境且無 replay；C23 正式 journal／registry reopen、原生出生身分接回選單、queued/historical 進入共用模型；prior-boot／重用／late generation／quit 故障注入 | C24 以引擎／prefix 證據接回原生孤兒程序，保持未歸屬；C25 目錄補查及損壞 registry 保留／當前世代保護、C27 首次 registry 與 admission 排序通過；最新版完整 Wine GUI 重開尚未實測 |
| V14 | E/C21 engine／prefix／probe/identity 失聯故障注入；一個 worker 受阻仍有另一環境前進，退出可用 | 最终 app 局部降級 UX 與主執行緒 I/O 回歸 |


回應性工程目標：p95 ≤100ms、單次本功能 main block <250ms，至少 30 個原始樣本。callback cycle 是代理指標，**不是點擊至畫面呈現延遲**；真實端到端尚未量測。

Apple 官方查核（2026-09-21）：[menuWillOpen](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen(_:))、[menuDidClose](https://developer.apple.com/documentation/appkit/nsmenudelegate/menudidclose(_:)) 均禁止回呼內修改結構或項目；[menuNeedsUpdate](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:)) 為追蹤開始前的更新入口。以官方 Markdown 內容核對，時間目標及五秒觀察界線屬本任務工程選擇。

### A/B 回呼量測補充

桌面 session 執行 `CYDER_MENU_SAMPLES=... bash tests/test-cyder-menu-responsiveness.sh`，30 筆 callback cycle 原始資料保留在 [CSV](2026-09-21-menu-callback-A-B.csv)。p95=0.029208ms、max=0.045ms；僅為同一程序內 menuNeedsUpdate→menuWillOpen→menuDidClose 呼叫時間，**不含 OS 點擊、呈現或真正 tracking 等待時間**。不據此宣稱整個 app 無 ≥250ms main hang。

沙箱執行早期 harness 雖印出 shell PASS，強化為驗證完成檔必有31行後發現未產生檔案；該早期 PASS 作廢。相同 Swift harness 在桌面 session 得到完整完成檔並通過 assertion；往後 AppKit 測試必須驗證實際產物，不能只看外層 exit/PASS。production 全來源 arm64 macOS11 typecheck 通過。

## 批次 C：持久與傳輸基礎（C1；正式 consumer 尚未切換）

- `CyderRequestJournal` 使用單一磁碟 queue、排他 owner flock、版本化 JSON、私有目錄／檔案、O_NOFOLLOW、大小／筆數限制、原子 rename 與 fsync/F_FULLFSYNC；只有持久提交後回覆 accepted。
- ID 帶持久 namespace，保留去重 tombstone；同 ID 不同 payload 拒絕、nil/empty argv 不混淆。完成後可移除 argv payload，保留最小結果。容量達上限先拒收，不刪除舊 tombstone 讓舊要求重播。
- queued 在重新開啟時改 awaitingUserResume；dispatching/observing 改 uncertain。只允許確認未派送項目明確 resume；舊 executor 晚到回執不能復活已恢復的 uncertain 要求。
- `CyderRequestChannel` 提供實際 Unix socket、同 UID peer 驗證、版本／frame 上限、每連線一筆訊息、有界讀寫 deadline／連線數，以及取消完成後才關閉 FD。
- 實測 `tests/test-cyder-request-journal.sh`、`tests/test-cyder-request-channel.sh` 通過。包含真實子程序在 durable dispatch 後 `_exit(73)`，重開檔案只得 uncertain 且拒絕重派；也測 ACK 遺失、磁碟提交前失敗、同 journal 雙 owner、取消順序、quiescing、缺失／損壞歷史、實際 socket 重送與不回覆 peer。輸出：`.local/lifecycle-evidence/journal-C1.log`、`channel-C1.log`。
- 上述屬 L1/L2 foundation 證據；尚未連接 app 入口、sentinel 選舉與實際 spawn，所以 V03/V05/V10/V13 **整合驗收未完成**。下一步以單一 coordinator 替換舊 outbox consumer，接上各種直接啟動與 AppKit 批次回覆，然後完成 D。

## C2／D：正式入口接線與退出隔離（持續整合）

- async instance coordinator 以 sentinel owner flock + journal owner lock 選舉；socket 不回應不授權奪取活 primary。移除舊通知／目錄輪詢 consumer，只有 journal authorizeDispatch 可釋出排程。
- 每筆多檔／URI batch 在同一 transaction 建立固定子 ID，保留順序、nil/empty argv、明確測試設定；全部 child 均可接受才 ACK。混合檔案與 URI 不再因早 return 遺漏。queued 保留至實際排程才 authorize。
- app openFiles 在持久接收後 reply；secondary 有界非同步轉交、同 ID retry、未 ACK outbox 保留。再次開啟只呈現 awaiting/uncertain，不自動 dispatch。
- 統一文件入口保留 EXE/MSI/script/link/reg 分流及 launch-only precheck；移除已無 caller 的 runPhasedLaunch 舊路徑。URI 驗證及測試設定寫檔移到 worker。precheck 失敗清除 starting ingress。journal launchID 傳入觀察路徑。
- applicationShouldTerminate 設 quiescing、凍結新派送、保存 queued、取消本 app 觀察與通道，三秒清理上限，零 Wine stop 呼叫。Command-Q／app menu／status quit 共用 AppKit 路徑。停止環境是獨立確認、stamp/operation ID 與有界回饋，不隱藏 UI。
- `test-cyder-instance-runtime.sh` 驅動正式兩個 coordinator、真實 Unix channel／flock／journal：mixed batch 三個子要求、退出與 authorize 競態、重新選舉、無重播通過。journal 測試亦通過。source smoke 淘汰要求舊 polling／同步 ACK 等待的條款，以正式 runtime harness 代替。status-item、open-files、全來源 typecheck 及兩架構 macOS11 build 通過。
- 本批測試版 `/private/tmp/cyder-lifecycle-cd2-build/Cyder.app`，bundle ID `local.cyder.lifecycle-cd2`；support `/private/tmp/cy-cd2/support`，共用本任務隔離 runtime `/private/tmp/cy-lifecycle/runtime`。來源／binary SHA256：`.local/lifecycle-evidence/build-C2-D2-source-sha256.json`；build log `build-C2-D2.log`。正式安裝未更動。

### D 真實 Command-Q 證據（L3，限定記事本）

- computer use 啟動此包並見初始化與偏好設定。隔離 bootstrap 8.36s；正式 secondary EXE 入口 durable ACK，主程序啟動本 prefix 內的可信 Wine notepad，journal 得到 completed 的 observation-finished 結果。
- 原生選單實見「退出 Cyder」。透過 computer use Escape、Command-Q：主程序 PID 9391（02:04:22）退出，session 於 02:05:49.101 記錄 terminated；Wine 記事本 PID 11400（02:05:13）保持相同啟動時間與父程序 11385，沒有執行停止環境操作。
- 隨後 computer use `getAXState` 重新啟動 app（新 PID 12094，02:05:53）。回傳設定視窗並非原 PID 未退出；這是工具重新綁定的副作用，已用程序時間查核更正。記事本仍存活。新 primary 沒有重播該要求。環境重新附接仍待 E/F，不宣稱已完成。
- 原始比對：`.local/lifecycle-evidence/cd2-before-quit.txt`、`cd2-after-quit.txt`；app log 位於隔離 support `Logs/sessions/2026-09-20T18-04-22.601Z-75E5ACAE-CD63-45C2-BC3B-17E00E19228C.log`。AX Wine 操作仍受工具 target 限制。

### E 證據門檻查核

已讀 engine redirect skill、engine repo AGENTS 及 incremental guide；未改 engine。固定 CX26 source `server/main.c` 的 -w 分支忽略 wait_for_lock 返回值並 exit(0)；`server/request.c` 用 prefix UID/device/inode 對應 `/tmp/.wine-UID/server-DEV-INO`，server lock 為 byte0 長度1 的 POSIX write lock。鎖失敗可退回 socket，因此單看 -w/lock 缺失不足以排空。後續 app-owned 校準必須核對 prefix 身分、鎖 owner 程序身分及 socket，失敗要局部降級。

仍未完成：非同步 launch runner／executor 回執與晚到 spawn fencing、完整 observer identity／環境校準與重接、精確 window action、恢復／取消 UI、全 V01–V14。以上中間編譯或單一 Command-Q 成功不等於 A–F 全部驗收。

## E1：正式環境探測、單環境 waiter 與重新校準

- 新增 `CyderEnvironmentProbe`：背景核對 prefix UID/device/inode、受管理 engine 路徑、POSIX lock owner 的 boot UUID/PID/start-time/image、live Unix socket，讀取前後重新核對鎖與 prefix；不建立／取得 Wine lock、不刪 socket、不發 Wine protocol request。已存在 socket-only server、權限／engine／身分錯誤為 unknown，不從 -w 的 0 exit 推論 empty。
- 鎖可能被剛結束等待的 -w helper 短暫持有，因此 alive 還必須有 live socket；native fixture 明確覆蓋該邊界。連續兩次 empty、相隔至少 0.5 秒且離開 launch 的 30 秒保護期限後才發出 exited。
- 新增 `CyderEnvironmentMonitor`，正式接入 status lifecycle store：每環境合併校準、最多兩個實際 in-flight 工作、五秒逾時回報但不釋放仍卡住的底層占位；server birth 改變即新 generation。每個 app 監測環境／世代最多建立一次 `Process` -w，terminationHandler 回傳只觸發校準，早退不高速重建。quit 只終止自己建立的 -w。
- `managed-environments-v1.json` 為帶 schema 的私有原子紀錄，只保存環境身分／engine／generation；有數量、大小、owner、NOFOLLOW 檢查。重開先由 reader 取得環境，再用當前 OS 身分校準；不同 app epoch 不接受舊 observer。損壞紀錄不覆寫、不變成 dispatch 權威。environment exited 清除對應程序／視窗存續及停止狀態。
- `test-cyder-environment-probe.sh` 的 native POSIX lock/socket、程序 image/start-time、PID reuse、waiter lock、socket-only、stale socket、prefix 置換、engine 缺失通過（桌面 session）。沙箱 run 的 `kern.bootsessionuuid` 回傳 EPERM，不能形成完整程序身分；已查核原因，不算產品通過。另一輪編譯因同時修改 source 失敗，固定來源後重跑成功。
- `test-cyder-environment-monitor.sh` 以正式 monitor/store 注入慢 probe 與時鐘：一個環境卡住時第二個仍校準、coalescing、新 server generation、舊事件拒絕、連續 empty、quit、恢復重新驗證及 corrupt registry 局部隔離通過。`test-cyder-lifecycle.sh`、正式 AppKit status/menu harness 及全來源 typecheck 通過。E/E2 universal macOS11 建置通過；E2 含追加的 live-socket hardening。

### E 真實 Wine 與原生 UI（L3，有限範圍）

- `/private/tmp/cyder-lifecycle-e-build/Cyder.app` 使用 `local.cyder.lifecycle-e`、相同本任務 CD2 support 及隔離 runtime。來源／binary SHA256 在 `.local/lifecycle-evidence/build-E-source-sha256.json`。E2 包在 `/private/tmp/cyder-lifecycle-e2-build/Cyder.app`，仍待後續完整整合後配置／交付。
- 初次 CUA getApp 呼叫出現約 23562 秒工具等待；返回時 app session 才於 2026-09-21T00:54:35Z 開始，不能將整段工具等待當 app 啟動延遲。後續相同已綁定 app 操作回復秒級。保留這個失敗／噪音，不納入 callback p95，也不據此宣稱端到端達標。
- 新版經正式 secondary/journal 啟動第二個記事本，保存一筆 managed environment，主程序 29100 建立一個自有 -w 30333。Command-Q 後兩者消失，記事本 11400/30331 與 server 11402 的 PID／啟動時間保留。重開主程序 30841 只建立一個新 waiter 30843；journal 仍兩筆 completed，無新 launch/replay。紀錄檔及程序關係佐證正式 reader/probe 接回；不等於 Wine 視窗精確動作驗證。
- 使用設定 UI 的明確「關閉所有 Wine 程序」確認，scope 只含此 support 的本任務 bottle（已檢查 shell 範圍）。停止後只剩主程序 30841，正式 probe=empty，registry records=[]；原生設定視窗仍開啟、按鈕重新可用。此實測走設定的既有 explicit-stop action，不冒稱 status menu stop tracking 已實測。
- 加強 socket 驗證後再用同一正式 probe 只讀對照：`/private/tmp/cy-lifecycle/support/bottles/shared` alive（server 98441），`/private/tmp/cy-cd2/support/bottles/shared` empty。兩者不同 inode，停止 CD2 未波及另一個測試環境。
- log/程序證據：`.local/lifecycle-evidence/probe-real-Wine-live-E2.log`、`probe-real-Wine-empty-E2.log`、`e-managed-processes.txt`、`e-quit-processes.txt`、`e-reattach-processes.txt`、`e-stopped-processes.txt`。原始實機 argv 日誌不提交。
- CUA screenshot 僅提供 app 視窗，AX tree 未提供 status item。實際 status tracking、Wine 視窗 input、多視窗指定切換仍未驗證；無 NGS 相容性結論。

### 仍需完成的整合（不以 E1 作完整 E 驗收）

舊 shell 每 launch 的 supervisor 仍有自身 session guard -w，尚需與 app 的環境觀測分工／錯誤通道整理；launch runner/activation semaphore、完整程序與視窗 identity、同環境 stop/dispatch 序列化、supervisor receipt、恢復／取消 UI 及精確 action 均待 C3/E2/F。monitored environment 的正常排空已取得真實證據，但 A–F 目標仍未完成。

Apple 補充核對：[fcntl F_GETLK](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html) 為衝突鎖查詢；[terminate](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)) 與 [reply(toApplicationShouldTerminate:)](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:)) 支持目前非同步退出接線。三秒退出與五秒 probe 期限是本任務工程選擇。

## C3 起始：非同步程序執行器

`CyderProcessRunner` 以 operation owner → Process.run → terminationHandler 順序保證立即退出／spawn error／deadline／cancel 恰好一次回覆。觀察完成與實際子程序資源釋放分開；launch/mutation 的 deadline 或 quit 回 unconfirmed，保留子程序、輸出 FD 與 mutation release callback 到實際退出，只有 observation policy 終止 runner 自有程序。quiescing 後拒絕新 spawn，有 32 個實際操作的容量上限。

`tests/test-cyder-process-runner.sh` 使用真實原生子程序測 immediate exit、spawn error、deadline/cancel 重複、deadline 後仍寫入 output、quit 不殺 launch、observer 自身取消、晚到 run 不 spawn，通過。此為正式 runner 元件測試，**app runLauncher 尚未切換**；不能据此宣稱全部同步等待已移除。下一個實作單位是正式 caller、設定 UI callback 與 activation adapter 接線，並保留目前 Wine 真實證據作回歸比較。

## C3：正式非同步執行與有界啟動觀察

- 正式 `runLauncher` 已切換到 `CyderProcessRunner`；app caller、設定查詢／套用／停止 callback 改為 async，移除 app main 的 `waitUntilExit`、activation semaphore 與 sleep polling。設定查詢失敗／逾時保守視為尚不能修改閒置 prefix；UI revision 拒絕過期回覆。這不代表其他檔案的磁碟／程序掃描已全面移出 AppKit，F 仍需盤點。
- 正式 `CyderLaunchObserver` 在獨立 queue 完成事件、固定原始 deadline；最多兩個實際 sidecar read，卡住不釋出占位，不阻止 deadline／quit。sidecar reader 限 schema、owner、regular file、2 KiB、NOFOLLOW／NONBLOCK。root 0 仍等 handoff，只有 root 0 + stopped 結束 launch observation；不推論整個環境已排空。
- launch observation deadline 回 `unconfirmed`，journal 保留 uncertain payload，禁止再次 authorize／resume／晚到完成覆寫；測試設定與 transport 不在仍可能被 executor 使用時移除。程序回執明確標記 `native-launcher`，保存當下可取得的 boot/start-time；它不是 Windows PID 或完整 detached supervisor 回執，後者仍待整合。
- monitor execution token 在 spawn 前取得、只在實際 native executor exit 釋放；有 executor 時 empty 探測不能宣告環境退出。runner 實際 operation 計數亦阻止背景工作尚未退出時自動結束 app。此 token 尚不等於同環境 mutation 序列化或 detached descendant fencing。
- runtime 測試通過：`test-cyder-process-runner.sh`、`test-cyder-launch-observer.sh`、`test-cyder-request-journal.sh`、`test-cyder-instance-runtime.sh`、`test-cyder-environment-monitor.sh`、`test-cyder-lifecycle.sh`。observer 覆蓋早到 activation、root 0 handoff、windowless root 0/stopped、root 53、卡住讀取／deadline／晚到事件／symlink／FIFO。journal 覆蓋 native receipt 及同程序 uncertain 保存、重開不重播。monitor 追加 executor 跨 deadline 存續與重複 release。
- source smoke `test-cyder-open-files-lifecycle.sh`、`test-cyder-force-settings-ui.sh` 通過。前者舊輪詢字串改為呼叫正式 observer runtime harness；後者舊的「visible library 分支」字串已不存在於前批共用入口，改檢查正式 enqueue 且不關 library，不將 source assertion 當 UI 實測。
- 保留失敗：第一次 C3 build 漏了 `CyderFailure.technicalDetails`，修正後雙架構 macOS11 build 通過；第一次新增 monitor 測試在 async release 尚未執行即推進假時鐘，改為明確 release completion barrier 後通過。log 分別 `build-C3.log`、`build-C3-r2.log`、`monitor-C3.log`、`monitor-C3-r2.log`。不刪除失敗樣本。

### C3 實機回歸（L3，可信既有 Wine 記事本）

- 測試包 `/private/tmp/cyder-lifecycle-c3-build/Cyder.app`，ID `local.cyder.lifecycle-c3`，wrapper 固定本任務 CD2 support/runtime，ad-hoc 簽章。來源／binary SHA256：`.local/lifecycle-evidence/build-C3-source-sha256.json`。建置命令與前批一致，`CYDER_SWIFT_OPTIMIZATION=-Onone`。建置後僅移除一個重複的 quit guard；manifest 記錄受測來源，後續交付會重建最新版本。
- CUA 首次 getApp 耗時 299.9 秒（超過指定 30 秒）；app log 01:32:37Z 才開始，後續已綁定操作約 0.02–3.7 秒。這是工具等待的未解噪音，不把它當端到端 app latency，也不因此宣稱效能達標。
- 正式 secondary 啟動既有 prefix 的 notepad；native launcher 回執 PID 54012，journal completed 且 receiptLayer=native-launcher，實際 Wine notepad PID 54447（09:33:00），server 54498。app log 記錄 runner 852ms 返回及 activation notification；不是模擬。
- CUA 在 Wine 執行時打開遊戲庫，AX 顯示加入遊戲／偏好設定／重新整理。Command-Q 後主程序 53280 消失，記事本 54447 啟動時間不變，server 54498 留存；證據 `c3-before-quit.txt`／`c3-after-quit.txt`。Wine 自身仍未出現在工具 app inventory，因此不宣稱已完成 Wine 視窗輸入／多視窗切換或 NGS 實测。
- 額外發現：CD2/E 舊 shell launch supervisor 與 sentinel-connect helper 在先前 explicit stop 後仍留存（11384/11392、30313/30324）。Wine/server 的 E1 排空證據成立，但 helper 收尾不完整；下一批需移除每 launch 環境 waiter 的責任重疊並修復失聯 helper，不把 E1 作完整 E 驗收。

仍待：同環境 mutation／stop／dispatch 序列化、不可變設定快照、完整 supervisor／程序／視窗身分與 action 能力、恢復／取消與非模態錯誤 UI、首屏／可及性及 V01–V14 整合驗收。A–F 目標保持進行中。

## E2a：失聯 sentinel helper 收尾

C3 程序盤點發現的舊 helper 殘留有一個明確競態：supervisor 先 publish PID 並關閉 FIFO writer，較晚啟動的 helper 用 blocking `open(O_RDONLY)` 就永遠等不到新的 writer。改成 NOFOLLOW／NONBLOCK／CLOEXEC 開啟且驗證同 UID FIFO；在事件 queue 初始化後主動讀一次既有 EOF，避免漏掉註冊前的關閉。缺 PID publication 三秒後只放棄 helper；primary socket EOF 亦結束 helper，沒有對 Wine 發 signal。source 初始化／取消在相同 queue，socket 由 cancel handler 關閉，send 使用 SO_NOSIGPIPE。

新增 `test-cyder-sentinel-helper.sh`：真正建立 Unix sentinel server、FIFO、helper 子程序與原生 sleep root，固定 writer 先關再啟 helper，確認連接與 PID update、root exit 後 helper exit；缺 PID 有界退出；primary stop 後 helper exit 而 root 留存。正式 sentinel／instance runtime tests 與全來源 typecheck 通過（只剩既有 activation API deprecated warning）。原始 logs：`helper-E2.log`、`helper-E2-r2.log`、`helper-E2-r3.log`、`sentinel-E2.log`、`instance-E2.log`、`typecheck-E2.log`。

這是正式 helper 的原生整合測試，尚未重建 Wine 測試包，不把它寫成真實 Wine 收尾已通過；舊版已啟動的 helper 不會被此 source 修正自動替換。每 launch 的 shell -w 與 supervisor descendant ownership 仍待下一單位完成。

## C4：同環境原生操作序列化

- 正式 `CyderOperationGate` 以 canonical prefix 作衝突範圍；同環境 FIFO、不同環境可越過不相關的等待，全環境修改作 barrier。lease 有獨立 UUID，舊 release／cancel 不影響新 owner；quit 拒绝 pending／新 acquire，不撤銷正在執行的 mutation。這是 app 內原生 executor 協調，尚不宣稱跨 primary crash／detached supervisor 的完整 fencing。
- app 的已接受 EXE／URI 先在背景解析 scope、取得 lease，再呼叫 journal authorize；因此環境停止中仍維持 queued，可由正式 journal／channel 取消，不會提早變成 cancellationTooLate。相同入口的 scope 準備使用序列 worker 保持交付順序；ready queue 才占用 activation 排程。等待 scope 也納入 app retention。
- `runLauncher` 正式 caller 全數共用 gate：launch 傳入已取得的 prefix lease，task manager／stop-prefix 用對應環境，其他修改操作用全環境 barrier；唯讀 running query 不取得 mutation lease。準備錯誤釋放 lease，成功 spawn 後只由 runner 的 actual-exit release 釋放。停止觀察十五秒後可以 unconfirmed，但不釋放仍存活的執行者、不自動補送停止指令。
- status stop effect 在主執行緒收到意圖時立即預約 canonical scope，避免 Task 排程讓較新的 launch 超車。取得 lease 後、spawn 前背景重新核對 prefix UID/device/inode，並查當前快照的 epoch/generation/operation；已結束、已更換環境或舊操作不再執行。底層 stop 仍作用整個 prefix；這不是跨外部程式建立新 wineserver 的原子保證。
- `test-cyder-operation-gate.sh` 用正式 gate + runner + journal、真實原生 sleep 程序驗證：stop deadline 未到 actual exit 不能放行同環境 launch；另一環境可取得操作權；全環境 barrier 不被超車；舊 release 無效；queued cancel 在取得 scope 後仍拒絕 dispatch；quit 取消 pending 並拒絕新 effect。這是 L1–2 替代證據，不宣稱 Wine stop/start 交錯實測通過。
- `gate-C4.log`／`gate-C4-r2.log`、open-files／settings／sentinel smoke 通過；完整 Swift typecheck 通過。雙架構 macOS11 build 兩輪通過，第二輪含停止意圖預約修正：`build-C4-r2.log`。測試包 `/private/tmp/cyder-lifecycle-c4-build/Cyder.app` 已配置 `local.cyder.lifecycle-c4` 與本任務 CD2 support/runtime wrapper，ad-hoc 重簽；SHA256 manifest `build-C4-source-sha256.json`。此包本輪尚未啟動，沒有新增 C4 Wine 實測結論。

下一步缺口仍明確保留：scope 解析 worker 卡住時的隔離／有界回饋、等待與取消的原位置 UI、設定不可變快照；detached supervisor receipt／晚到 spawn、跨崩潰環境操作 fencing 及每 launch -w；程序／視窗身分與精確動作；F 恢復／非模態錯誤／首屏及完整 V01–V14。C4 的原生 lease 不代替這些驗收。

## F1：持久要求的恢復／取消介面

- coordinator 發布帶 record version 的狀態，追加正式 resume／cancel／refresh API；恢復只呈現紀錄，不呼叫 deliver。只有 journal `awaitingUserResume` 可沿原 ID 繼續，queued／awaiting 可取消；dispatching／observing／uncertain 不提供偽取消或立即重試。snapshot 只讀 journal owner 的記憶體狀態，UI 不輪詢磁碟。
- 新增非模態「啟動要求」視窗、app menu 入口與遊戲庫可收合提示。NSTableView 僅建立可見列，穩定 request ID 綁定按鈕；UI capability 與 journal 再次核對，連點／舊按鈕不會重派。錯誤與儲存回饋留在原視窗，沒有完成彈窗。結果未確認項目明示不自動重試，保留診斷記錄入口。
- app 收到成功取消後取消 pending gate acquisition、釋放尚未派送的 ready lease、移除排程；scope 準備中的取消以 ID set 攔截晚到 callback，等待存續由 ID set 計算，取消不因舊 worker 未回覆繼續保留 ingress。要求視窗也納入可見 UI 的存續理由。
- journal 只額外保存去除控制字元、最多 100 字的檔案 basename／泛稱「開啟連結」，供 payload 清除後辨識失敗；不在清單顯示 argv、完整 URI 或完整路徑。舊 schema1 沒有這個 optional 欄位仍可讀。
- `test-cyder-request-ui.sh` 驅動正式 journal 開啟→關閉→新 coordinator 恢復，再建立正式 AppKit table cell、點其 NSButton selector：恢復不自動 dispatch；resume 原 ID 只派送一次；cancel 持久保存；stale button 無效；uncertain 不提供 resume/cancel；直接呼叫 coordinator resume uncertain 仍拒絕；重開保留 cancelled／uncertain；failed 清 payload 後仍有短名稱；秘密測試 argv 不進 UI。測試必須產生 `ui-completed` artifact 才算成功，避免只見 process exit 誤報。
- 以上為 L1–2 正式 AppKit adapter／原生整合證據，不是 Wine 視窗或 NGS 實測。`CYDER_TEST_RENDER=/absolute/path.png bash tests/test-cyder-request-ui.sh` 可輸出正式 contentView 渲染；已檢視 `.local/lifecycle-evidence/request-ui-F1.png`，四列的名稱、狀態與按鈕未裁切。圖為 contentView 離屏渲染，透明外緣不代表桌面實際黑底；不把它當 computer-use screenshot。
- journal、instance runtime、open-files smoke、settings smoke 通過。settings 原固定 top=32 字串與新增提示不相容，保留 `settings-F1.log` 失敗；改驗提示 top=32／空文字 height=0／內容接在提示下方，`settings-F1-r2.log` 通過。runtime logs：`request-ui-F1.log`、`request-ui-F1-r2.log`、`request-ui-F1-r3.log`、`journal-F1.log`、`instance-F1-r2.log`。
- 全來源 typecheck 與 universal macOS11 build 通過：`build-F1.log`；隔離測試包 `/private/tmp/cyder-lifecycle-f1-build/Cyder.app` 已配置 ID `local.cyder.lifecycle-f1`、CD2 support/runtime wrapper 與 ad-hoc 簽章。來源／binary manifest `build-F1-source-sha256.json`。本輪尚未啟動此完整 app，不新增真實 Wine UI 通過宣稱。

F 尚未完成：直接開啟仍是旧設定首屏，遊戲庫 prepare 的同步掃描須遷移；primary／journal unavailable 尚需唯讀 UI；scope preparation 的卡住隔離、outbox 恢復、不可變設定快照與 supervisor fencing；完整程序／視窗 action capability、全 V01–V14 及最終測試版交付仍待完成。

## F2：啟動前讀取有界化與原 ID 手動繼續

- 將單一 scope worker 換成正式 `CyderLaunchPreparation`：最多兩個實際讀取、512 個待交付觀察、五秒單調時鐘期限。依接受順序交付，但較早卡住的觀察只阻擋到其期限；逾時／取消不釋出仍卡住的實際 worker。worker 晚到只收尾，不派送過期結果；已到期的排隊工作不再開始讀取。
- 無法確認環境時，要求仍未取得 launch ID／尚未派送，journal 原子保存為 `awaitingUserResume`，UI 原位置顯示「環境暫時無法確認；尚未派送，可稍後繼續」。明確繼續才將同一 ID 轉回 queued，清除舊原因並重新準備；已 dispatch 的要求拒絕倒退。最後一筆取消或暫停會清除 ingress 的 starting 標記；quit 後的保存回覆不重開視窗。
- `test-cyder-launch-preparation.sh` 驅動正式解析器及 journal：零期限不執行、單一卡住時其他環境仍有界交付、兩個底層卡住時不增生 worker、排隊取消、晚到結果恰好一次、quit、新要求拒絕、持久暫停／手動繼續／dispatch fence。`preflight-F2-r2.log`、`journal-F2.log` 通過。
- 正式 AppKit request adapter 測試追加 coordinator deferRequest→journal→原位置文字／能力、已派送拒絕暫停；`request-ui-F2-r2.log` 通過。instance、operation gate、open-files 回歸通過（`instance-F2.log`、`gate-F2.log`、`open-files-F2.log`）。這些是 L1–2 原生及故障注入證據，不是真實 Wine／NGS 實測。
- universal macOS11 build 通過 `build-F2-r3.log`。包 `/private/tmp/cyder-lifecycle-f2-build/Cyder.app` 已配置獨立 ID `local.cyder.lifecycle-f2`、CD2 support/runtime 與 ad-hoc 簽章；manifest `build-F2-source-sha256.json`。之後僅增加 quit callback guard，另做全來源 typecheck；最終交付仍須重建最新版。此包尚未啟動，不新增 Wine 相容性結論。

仍待：遊戲庫首屏與非同步資料載入、primary／journal unavailable 唯讀介面、outbox 恢復、不可變設定快照、detached supervisor 身分／跨崩潰 late-spawn fencing、單一環境 waiter、完整程序／視窗精確動作及 V01–V14 整合。目標保持進行中。

## F3：遊戲庫首屏與背景資料所有權

- 直接開啟、Finder/Dock reopen 與空 showUI 要求都先呈現遊戲庫，不等 Wine 環境準備。開視窗前不再初始化隱藏的設定視窗；遊戲庫 constructor 僅建立 AppKit 元件，showWindow 後才提交背景載入。既有程式／要求恢復沿先前管線，不在此新增重播。
- 產品決策：瀏覽遊戲庫不隱含 Wine bootstrap／修復；保留可見的「準備 Windows 環境」入口，明確操作後走原正式 ensureEnvironment／runner／operation gate。進度留在遊戲庫，失敗不強制退出、不連續彈窗；首次啟動尚未準備的提示指向此入口。此決策符合 §19 首屏與 §23 原位置回饋，取代舊「先準備再顯示設定」路徑。
- `CyderLibraryLoader` 在單一背景 queue 擁有 library read／merge／shortcut import／add／macApp path save；只允許一個實際操作，五秒後回報尚未確認但不釋出卡住 worker。重複刷新不累積工作；實際返回後才更新快照與按鈕。退出移除 observer 並拒絕新工作，晚到結果不重開 UI。短暫遺失 EXE 不自動刪項；malformed／unreadable history 不變成空庫、不覆寫，UI 保留上次快照。
- 遊戲庫 footer 顯示載入／錯誤／準備進度；上次異常結束改為可關閉的記錄入口。context menu 標题使用快照，不為判定 mac launcher 是否存在同步探磁碟。這還不是全 AppKit I/O 清零：圖示 freshness／EXE open、設定初始化／per-game options、其他既有 action 的同步路徑仍待 F4。
- `test-cyder-library-loader.sh` 使用正式資料 backend 在隔離 support 寫入並重新讀取 game-library，驗證 missing EXE 保留、corrupt bytes 不被修改；再以正式 AppKit controller 注入卡住 reader，真實 NSButton.performClick 驗證設定／準備 callback 可用，50 次 refresh 只啟動一個 worker，inline deadline、late completion、quit fence 與恢復提示關閉通過。須有 `ui-completed` 才算通過。`library-F3-r2.log` 為 L1–2 證據，不是 computer-use 或 Wine／NGS 驗收。
- 已檢視 `.local/lifecycle-evidence/library-F3.png` 正式 contentView 離屏渲染：待處理與恢復提示、空庫、環境準備入口未裁切。真實桌面 menu／Wine AX 限制仍如前文，未以此圖替代實機截圖。
- 保留失敗：`library-F3.log` 首輪 fixture 在 precondition 的非 throwing autoclosure 直接 try，改為先讀取再斷言後通過；settings/open-files 舊靜態測試固定 Preferences 首屏／旧 graphics warning 字串，`settings-F3.log`、`open-files-F3.log` 保留失敗。改為檢查 library-first、collapsible recovery 與正式準備失敗不 terminate；`settings-F3-r3.log`、`open-files-F3-r2.log` 通過。原 library store harness 通過 `library-store-F3.log`。
- 全來源 typecheck 與 universal macOS11 build 通過，`build-F3.log`。隔離包 `/private/tmp/cyder-lifecycle-f3-build/Cyder.app` 已配置 `local.cyder.lifecycle-f3`、CD2 support/runtime wrapper、ad-hoc 簽章；`build-F3-source-sha256.json` 對應本批來源。此包本輪未啟動，不新增 Wine 實測宣稱。

F3 不完成整體 F。接續須處理圖示／設定等主執行緒 I/O、primary unavailable 唯讀 UI、outbox、不可變設定、supervisor ownership／單一環境 waiter、精確程序／視窗 action 與 V01–V14 最終矩陣。

## F4：遊戲圖示不再隱含啟動 Wine

- 正式 `CyderGameIconStore` 改為 main 上的記憶體投影：logo／tile render 不碰磁碟，freshness、cache decode、EXE 資源读取与 PNG 保存皆由有界背景讀取器執行。兩個實際 worker、五秒觀察期限、最多 512 pending ID／每 ID 16 個重繪 callback、128 張記憶體圖片；逾時不釋出物理占位、晚到不覆寫，quit quiesce 後無新 work／UI 回覆。重新整理明確重新檢查失敗圖示；cache eviction 後可按需再讀。
- 移除 app 的 Wine winemenubuilder 呼叫、整個 EXE 複製與 helper scratch lifetime。新增 `CyderPEIcon` 原生只讀 PE32／PE32+ 資源：依 section RVA 取資源，固定三層目錄、8 MiB 總讀取額度、96 section／4096 entry／64 group image 上限，regular file＋NONBLOCK，讀取後核對同 FD 的 size/mtime/ctime。PNG 直接 ImageIO；常見未壓縮 24/32-bit RGB DIB 處理上下方向與 AND mask，其餘 ICO 走受限 ImageIO。輸入像素尺寸上限 1024、輸出最多 256；不支援／損壞時保留中性圖示，無 Wine fallback。
- 格式核對：[Microsoft PE format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)、[icon resource 結構](https://devblogs.microsoft.com/oldnewthing/20120720-00/?p=7083)、[資源內 DIB／PNG](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-file-formats)。這是應用層讀取器，沒有引擎修改。舊 shell helper 保留為 standalone legacy，正式 app 已無呼叫點。
- `test-cyder-game-icons.sh` 使用自行建立、無程式碼的 PE32／PE32+ PNG／DIB resource fixture，檢查解碼紅色像素，不只是非 nil；RVA 越界、cycle、entry count、長度不符、截斷、非 PE、96 個固定種子突變；正式 store 快取生成／損壞再生／新 store 讀取；40 個要求在兩個 reader 卡住後期限回覆，沒有多開 worker；晚到真實 CGImage 不穿越 quit/deadline。`icons-F4-r3.log`、`shortcuts-F4-r2.log` 通過。這是原生格式／故障注入測試，不是真實 Wine 視窗相容性。
- 加做已知既有 Wine 記事本 EXE 的唯讀測試：`/private/tmp/cy-cd2/support/bottles/shared/drive_c/windows/system32/notepad.exe` 解出 256×256 圖示；命令只讀 PE，不啟動 EXE／Wine，不能換稱 L3 遊戲執行通過。
- 保留失敗：首輪 typecheck 漏一個 `try`、首輪 fixture 將 throwing read 放進 precondition autoclosure，分別修正。`icons-F4-r2.log` 發現 ImageIO 對有效小尺寸 ICO 包裝回 count=0，保留 `.local/lifecycle-evidence/icons-F4-failed-fixtures` 與原始輸出；改成原生 PNG／RGB DIB 路徑後像素測試通過。該首輪 fatal-error 子程序 PID 63073 在 OS 顯示 UE，即使核對身分並對它送 SIGKILL 仍未立即退出；它不是 Wine／app 監控器，不把此工具／崩潰收尾當產品通過證據。
- 舊 shortcuts source smoke 固定 Wine helper／45 秒／shared prefix，`shortcuts-F4.log` 保留失敗；改驗正式原生 reader 接線與執行上述 runtime harness。正式 library AppKit harness `library-F4.log`、settings smoke `settings-F4.log` 通過。新版 universal macOS11 build `build-F4.log` 通過；測試包 `/private/tmp/cyder-lifecycle-f4-build/Cyder.app` 已配置獨立 ID `local.cyder.lifecycle-f4`、CD2 support/runtime、ad-hoc 簽章，manifest `build-F4-source-sha256.json`。完整包本輪未啟動，沒有新的 Wine UI 結論。

剩餘 F／整體缺口不變：設定及部分既有 action 的主執行緒 I/O、primary/journal unavailable 唯讀介面、outbox、不可變設定、supervisor／晚到 spawn fencing、每環境 waiter 分工、精確程序／視窗動作、V01–V14 完整交付。原生圖示測試通過不代替這些驗收。

## F5：無協調權時的唯讀降級與有界初始化

- coordinator start 加入五秒 monotonic 期限、一次 role 回覆與每個非同步邊界的 generation／closing／絕對期限查驗。逾時只結束觀察，不假定 owner 不存在；晚到 election／journal／channel 結果不能取得 dispatch authority，待實際返回後依序釋放自身 channel、journal、sentinel。stop completion 等真正 startup cleanup；不刪除或搶走其他 primary 的 socket／鎖。authorize 明確要求 primary，closing 後不再開始 forward。
- app 在 ownership/journal unavailable 或 secondary forward 未確認時，保留單一非模態狀態窗，不再警告後立即退出。兩種文案分開，後者明示可能已接受、關閉不等於取消、不自動重新啟動。提供唯讀遊戲庫、診斷、退出；沒有重試即 launch 的假動作。未取得接受確認的 openFiles 回 failure，一次回覆；晚到回覆不在 quit 後重新開窗。
- readonly library backend 只讀既有 metadata，不做 profile merge／shortcut import／add／save；UI 停用加入、設定修改、環境準備、mac launcher 安裝，tile double-click／selector 亦再次拒絕。瀏覽／重新整理／Finder 入口保留，不建立 status item 或第二個 executor。readonly 不產生 icon cache writes，使用中性圖示。正常 primary 仍走原可寫 controller。
- `test-cyder-instance-runtime.sh` 新增真實 coordinator＋受控 election stall：0.05 秒測試期限後 unavailable、submit 拒絕；晚到真正 election 結束後 stop 才回覆，替代實例可正常取得 primary、未重播。另將實際 journal 檔改為損壞 bytes，確認 unavailable、無派送、未覆寫原檔。`instance-F5-r2.log` 通過；測試期限縮短是故障注入，不宣稱產品 startup 只需 0.05 秒。
- 正式 AppKit library harness 驗證 readonly refresh 不改已保存 metadata、add API 拒絕；實際 disabled NSButton.performClick、tile double-click、context menu 能力均不觸發 mutation callback；fallback 的瀏覽／診斷／退出 callback 各一次，未知要求文案不冒稱取消。`library-F5-r3.log` 通過。`request-ui-F5.log`、`settings-F5.log`、`open-files-F5.log` 回歸通過。以上為 L1–2；不宣稱真實 Wine 或整個 app 不可用情境已 computer-use 通過。
- 保留失敗：`library-F5.log` 的新增 fixture 漏解開 NSMenu?，屬編譯錯誤，修正後 r2 通過。r2 離屏圖背景透明，黑底 viewer 看不清深色文字；加上隨 appearance 重繪的正式背景後，已檢視 `.local/lifecycle-evidence/library-F5-r3.png.unavailable.png`，文字、按鈕未裁切。這是 contentView 渲染，並非桌面截圖。
- 全來源 typecheck、三輪 universal macOS11 build 通過（最新 `build-F5-r3.log`）。隔離包 `/private/tmp/cyder-lifecycle-f5-build/Cyder.app` 使用 `local.cyder.lifecycle-f5`、CD2 support/runtime wrapper、ad-hoc 簽章，manifest `build-F5-source-sha256.json`。包本輪未啟動。

追加檢查發現 `CyderRequestChannel.stop` 原本無條件 unlink：逾時 secondary 尚未啟動 channel，清理卻可能移除真實 primary 的 endpoint。現改為記錄自己 bind 的 socket device/inode，stop 只刪除仍匹配者；未 bind／重複 stop 均不刪他人 path。`instance-F5-r3.log` 增加真實 primary 存活時的逾時 secondary，清理後仍能透過另一 secondary 成功接受新要求；`channel-F5.log` 回歸通過。這個缺陷在 staged 前檢查發現並修正，沒有提交已知錯誤版。

仍未完成：正常初次角色確認之前的首屏可更早呈現，目前失聯降級由五秒期限觸發；outbox 的原 ID 核對／恢復介面、完整錯誤分類與 feedback owner；設定等主執行緒 I/O、immutable settings、supervisor／late-spawn fencing、環境 waiter 整合、精確 process/window actions、V01–V14 與最終可重現交付。F5 不作全部恢復體驗完成宣告。

## C5：接受時固定啟動設定

- journal 在同 ID／digest 去重之後、原子接受提交之前擷取一次已保存設定；批次子要求共用同一份內容，UI-only 不讀啟動設定。app 注入正式 `CyderSettings` decode/encode，於接受時具體化預設值、舊版遷移與清理，不能等到派送時才決定缺省欄位。設定快照獨立於客戶端 payload digest；ACK 遺失後重送不重讀，即使目前設定已損壞仍接回原要求。
- 讀取限定同 UID、regular file、NOFOLLOW／NONBLOCK、256 KiB；讀取前後核對同 FD 的 size/mtime/ctime。只有真正不存在的檔案代表預設設定，FIFO／symlink／不支援 schema／損壞內容不當作空設定。journal 仍受 512 筆／16 MiB 上限，快照計入原子檔案容量。取消與已確認 terminal 清 payload 及快照；uncertain 保留且不自動重播。舊 queued 紀錄重開仍為 awaitingUserResume，只有明確繼續才補取快照；有快照者繼續仍保留原內容。
- 正式 EXE／MSI／script／link／reg／URI→Wine 共用入口要求 authorization snapshot，無快照／解碼錯誤不 spawn。全域 environment 改由快照的純函式投影，Bash 的全域與 per-profile 讀取改接私有 `launch-requests/settings-UUID.json`（目錄 0700／檔案 0600）；明確 test override 保持優先。缺檔／損壞／不在工作目錄的快照拒絕啟動，不能退回目前 settings.json。standalone CLI 未提供快照時保留原設定讀取行為。
- Bash 在分離背景 supervisor 前完成兩層設定讀取；快照檔由原生 launcher 的 actual-exit callback 清除，觀察逾時不提前刪除。Cyder 本身崩潰後可能留下私有 transport 檔，尚未新增安全回收政策，不能依年齡猜測舊執行者已退出。此修改不解決既有 detached supervisor／跨崩潰 late-spawn fencing 缺口。
- socket ACK／status projection 不回傳整份設定，避免額外暴露無關規則或超出較小的 wire frame 上限；primary 內部 dispatch 仍帶完整持久快照。`test-cyder-instance-runtime.sh` 驅動真實 coordinator/channel：接受後修改設定、query 不帶快照、authorize 仍使用原值。`instance-C5-r5.log` 為本批最終結果。
- 正式 journal fault harness 驗證 lost ACK、同 ID、batch、明確 resume、uncertain 保留、terminal/cancel 清除、legacy restore/resume、corrupt/absent/FIFO/symlink：`journal-C5-r3.log` 通過。`test-cyder-settings-snapshot.sh` 以無程式碼的空 EXE 路徑驅動正式 Bash readers：全域/per-game 不受後改影響、explicit test override、CLI、缺失/損壞/symlink fail closed、失敗不進 mutation；`settings-snapshot-C5-r3.log` 通過。沒有啟動 Wine。
- 回歸：channel、settings shell、open-files lifecycle（含正式 observer）通過，logs 為 `channel-C5.log`、`settings-C5.log`、`open-files-C5-r2.log`。Swift settings fixture 發現舊 schema 12 斷言與正式 schema 13 不符；改為驗證遷移及重讀均為 13，保留所有其他斷言，追加預設值具體化、malformed 拒絕、快照 environment 不受後改影響與保護 transport key。`settings-swift-C5-r3.log` 通過。
- 保留失敗：`plutil -lint` 在這台 macOS 拒絕 JSON（`settings-snapshot-C5.log`／debug），改用 `-convert json -o /dev/null` 驗證後通過；新增 coordinator fixture 初次漏 message 參數，次輪 senderEpoch 型別錯誤（`instance-C5-r2.log`／r3），修正測試後通過。最初 open-files 命令寫錯檔名，exit 127，改跑實際 harness。舊 schema 斷言造成兩個原生 fixture（80423、81445）停在 OS UE，桌面權限亦重現；核對映像後只向這兩個 fixture 送 SIGKILL，不把卡住的執行當通過。修正 fixture 後新程序正常完成。
- 全來源 typecheck 通過；最新 universal macOS11 build 為 `build-C5-r2.log`。隔離包 `/private/tmp/cyder-lifecycle-c5-build/Cyder.app` 使用 `local.cyder.lifecycle-c5`、CD2 support/runtime 與 ad-hoc 簽章，manifest `build-C5-source-sha256.json`。本輪未啟動完整 app；本節為 L1–2 原生／故障注入證據，不是真實 Wine 或 NGS 相容性結論。

仍須完成：設定 UI 與部分 action 的主執行緒 I/O、outbox／feedback owner、supervisor 與跨崩潰執行權、環境 waiter、精確 process/window 動作、完整 V01–V14 及最終交付。C5 固定設定內容，不把動態 profile 路由或環境身分也宣稱為已固定。目標保持進行中。

## F6：設定視窗的背景交易與草稿衝突保護

- 移除正式 UI 對同步 shared settings store 的存取。`CyderSettingsAccess` 為 app 內唯一設定交易入口，單一實際背景工作、不排隊；五秒觀察期限只回報 unconfirmed，不釋出卡住的工作占位。忙碌時拒絕新寫入，UI 保留草稿；真正返回後才交付結果。quit 拒絕新工作與晚到 UI 回覆，不把正在原子寫入的結果推定為取消。
- 讀取以同 UID regular FD、NOFOLLOW／NONBLOCK、256 KiB 及前後 size/mtime/ctime 檢查，只有真正不存在才採預設；寫入也限制 256 KiB，避免產生自己無法讀回的檔案。損壞／不支援／不可讀設定不變成 defaults 後覆寫。每筆交易重新讀取實際檔案；UI 使用自己的記憶體快照，沒有主執行緒等待 owner 的同步取值。
- `CyderSettingsPatch` 僅合併畫面實際修改的 global 欄位及 per-profile/per-executable 條目，保留其他視窗修改的不同欄位／條目；同欄位或同規則已改成第三個值時，在寫入前回 conflict。revision／updatedAt／lastModified 仍由原正式 store 根據真正變化產生。這是 app 內交易協調，不宣稱與外部 CLI／其他程式的設定寫入已有跨程序鎖。
- 偏好設定與遊戲選項 constructor 僅建立 UI 與不觸發字型掃描的暫時顯示值，載入完成前不允許把暫時值當設定送出。設定、引擎版本、profile 清單、圖形元件能力及 GPTK 狀態皆由背景載入；畫面刷新只讀這份投影。載入中的分頁控制項全數停用，但遊戲庫／記錄／停止環境等獨立入口與視窗關閉保留。一般儲存先在 main 擷取純資料 patch，背景寫入；失敗／busy／期限留在原處，提供重試，沒有儲存成功彈窗。
- 一般設定寫入超過觀察期限，仍追蹤 physical outcome，成功後按同 UI revision 接續既有 Windows 設定套用路徑。若等待期間較新編輯使舊回覆失效，保留 prefixApplyPending，下一次明確重試不能遺漏套用。舊 running-state query 也核對 settings revision，不把新草稿提前顯示為已儲存。遊戲選項儲存期間停止編輯，關閉後以 view generation 拒絕晚到成功回覆，不關閉後來的 modal，也不宣稱關閉等於取消寫入。
- app 移除 profile 後的設定更新也走同一背景入口。非 launch 的偏好依賴操作使用背景 strict read；唯讀 running query 與明確 stop 則由內部 flag 同時略過 native/Bash 的設定讀取，因此損壞／FIFO 設定不阻擋查詢與停止。這不改 Wine stop 的既有範圍與授權檢查。
- `test-cyder-settings-access.sh` 驅動正式 owner、patch 與真實原子檔案：不同修改合併、同欄位衝突不改 bytes、不同 profile 保留、corrupt 原檔保存、FIFO 立即拒絕；一個 reader 卡住時 60 次請求均 busy、只一個 physical read，期限一次／晚到一次；quit fence。另以正式 Bash entry 的 `--help` 和 FIFO 設定验证 preferences-independent 分支不碰該檔；此 fixture 不進 Wine spawn。`settings-access-F6-r4.log` 通過。
- `test-cyder-settings-ui.sh` 使用正式兩個 AppKit controller 與受控 reader：40 次 reopen 不增生工作、未選取分頁亦停用、main event-loop tick 與實際遊戲庫 NSButton 可用；真正 NSSwitch action／套用 NSButton 寫回全域與 per-game 設定，保留另一層內容。受控 save stall 驗 unconfirmed 後仍套用；等待中再次編輯→busy→原寫入完成→重試，仍完成待套用環境更新；關閉選項後晚到寫入不回呼 UI。測試必須有 ui-completed artifact，腳本明確列印驗證成功；`settings-ui-F6-r6.log` 及 `settings-ui-F6-r6-artifacts/Logs` 通過。此處的 Windows 套用 callback 是替身，沒有跑 Wine registry。
- 保留失敗與修正：r1 真實發現 `subviews` 不包含未選取 NSTabViewItem，載入時 Retina 仍 enabled；改走全部 tab item views。原 precondition trap fixture 留在 OS UE，新 fixture 失敗改輸出條件與 exit 1，沒有放寬斷言。r3 在冷讀較慢時暴露 unconfirmed 提早完成 continuation、晚到 save 不再 apply；r4 的再次通過未作結案，r5/r6 加受控延遲與重試競態並修正式路徑。診斷初始化會重導 stdout/stderr，新增 fixture log 保存，避免只看空輸出判斷。
- 已檢視 `.local/lifecycle-evidence/settings-F6-r5.png`／r6 的正式 contentView 渲染：背景與 footer 可讀；Aqua tab header 在離屏渲染呈黑色，不能以此證明實際桌面 tab 標籤外觀。內容有正式 scroll view，較下方引擎資訊不在當前 viewport。此圖不是 computer-use screenshot。沒有新增真實 Wine／NGS 相容性結論。
- settings Swift、settings shell、open-files lifecycle、library AppKit、C5 Bash snapshot 回歸通過（`settings-swift-F6.log`、`settings-shell-F6-r2.log`、`open-files-F6-r2.log`、`library-F6.log`、`settings-snapshot-F6.log`）。完整 universal macOS11 build 最新為 `build-F6-r2.log`；隔離包 `/private/tmp/cyder-lifecycle-f6-build/Cyder.app` 設 `local.cyder.lifecycle-f6`、CD2 support/runtime、ad-hoc 簽章，manifest `build-F6-source-sha256.json`。本輪未啟動完整 app。

F6 尚未清除所有既有 action I/O：GPTK 掛載掃描／安裝／移除、MoltenVK ensure、選 EXE 後 resolve，以及遊戲庫 Finder／mac launcher 檢查仍待遷移；詳細錯誤分類／衝突後的草稿解決流程也尚未完整。outbox、supervisor／跨崩潰 late-spawn、waiter、精確 process/window actions、V01–V14 整體交付仍未完成，不將本批當作目標完成。

F6 fixture 清理追記：11:29 左右重新核對，前批 80423／81445 仍在 OS UE；未重複向它們送訊號。本批首次失敗 fixture 87784 的映像確認為 `/private/tmp/cy-settings-ui.NPuuk7/test` 後只對該 PID 嘗試 SIGKILL，不宣稱已成功排空。它們皆為原生測試，不是 Wine 或使用者遊戲。

## F7：設定元件維護的背景所有權

- GPTK 掛載掃描、安裝與移除移出 AppKit。非設定檔 I/O 使用同一個有界 `CyderSettingsAccess.performWork`，不必先讀取 settings.json；實際工作返回或 admission 拒絕時都執行 release。觀察逾時與 quit 不提早釋出實際工作占位。
- 元件修改使用 app 共用的 all-environment operation gate。尚未取得 lease 時關窗會取消排隊；已開始工作則保留 lease 至真正返回，關窗／quiesce 不假稱取消。完成後另讀顯示資料，該讀取卡住只占讀取 owner，不繼續持有修改鎖。成功與未知用原位置文字回饋，沒有安裝成功彈窗。
- MoltenVK 選項只保存偏好；正式 launcher 原有路徑會在啟動時套用接受的偏好，UI 不再直接更改共用 runtime symlink。舊 EXE resolver 也移到背景並核對 view generation／settings revision；此舊 picker 不在目前可見分頁中，不能宣稱已驗證其使用者操作。profile SHA-256 改用 CryptoKit，免除每個路徑產生 shasum 子程序；對照正式 canonical path 與 /usr/bin/shasum，保留持久 ID 格式。
- 正式 owner fixture 驗證 auxiliary work 不依賴偏好檔，quiesce 後 physical release 仍一次、拒絕 admission 也釋出 lease（`settings-access-F7-r2.log`）。正式 AppKit controller＋operation gate 以受控 semaphore 與真實暫存寫入驗證：逾時後重複操作不執行、後續環境 lease 等實際返回；關窗與 quiesce 後工作仍完成並 release；未取得 lease 的關窗操作不執行；post-mutation 顯示讀取卡住時另一環境可前進（`settings-ui-F7-r4.log`／artifacts）。保留 F6 的儲存、忙碌重試、late UI fence 斷言。
- GPTK fixture 補設專用 CYDER_RUNTIME_ROOT，避免 syncEngineLink 使用正式 runtime；以文字假 payload 驗證隔離檔案複製、移除、manifest 與連結（`gptk-F7.log`）。MoltenVK fake payload 回歸、settings shell 與 profiles Unicode／metadata／symlink 回歸通過（`moltenvk-F7.log`、`settings-shell-F7.log`、`profiles-F7-r2.log`）。沒有載入假 dylib 或啟動 Wine，不是圖形／NGS 相容性證據。
- 保留測試失敗：`profiles-F7.log`／debug 首次 oracle 使用 pwd -P，在 macOS 得到與 Foundation 不同的 /private/var 表示；改用正式 canonical 輸出作為獨立 shasum 輸入後通過，未改正式 canonical 規則。`settings-ui-F7-r3.log`／artifacts 的額外 EXE 斷言等候已不在目前分頁中的舊 picker；移除此不代表可見介面的新增斷言，保留全部 maintenance 與 F6 斷言。未把它算作 EXE UI 通過。
- 已檢視正式 contentView 渲染 `settings-F7-r4.png`；一般內容與 footer 可讀，Aqua tab header 離屏黑色限制仍在，並非桌面截圖。完整 universal macOS11 build `build-F7.log` 通過；隔離包 `/private/tmp/cyder-lifecycle-f7-build/Cyder.app` 設 local.cyder.lifecycle-f7、CD2 support/runtime、ad-hoc 簽章，manifest `build-F7-source-sha256.json`。本輪未啟動完整 app，以上為 L1–2 證據。

仍待完成：遊戲庫 Finder／mac launcher 等 action 的主執行緒 I/O、詳細衝突處理與 feedback owner、outbox 原 ID 核對／恢復、supervisor／跨崩潰 late-spawn fencing、環境 waiter 整合、精確 process/window action，以及 V01–V14 最終矩陣。F7 只完成本節設定維護改動，整體目標繼續。

## C6：未確認轉送副本的原 ID 核對

- 正式 forward 改用 `CyderRequestOutbox`：private directory FD、NOFOLLOW／NONBLOCK、同 UID 與權限檢查；跨程序 nonblocking flock 序列化副本新增與清理。逐檔 O_EXCL 寫入並 fsync 檔案／目錄；最多 512 筆、16 MiB 容量，單筆小於 wire 的 256 KiB。滿載、損壞、權限／鎖失敗不無界排隊或丟棄其他副本。
- primary 取得持久 journal 後在背景核對 outbox，也由要求視窗重新整理觸發。讀取原 request ID、版本、payload digest，與正式持久快照比對；只移除已接受且 ID／digest 相同的副本，移除前重新核對 inode／device／size／mtime／ctime。核對本身完全不 submit／resume／dispatch，不把舊 ID 換成新 UUID。queued 紀錄照舊 awaitingUserResume；已派送照舊 uncertain。
- 缺少相符紀錄、內容衝突、舊 namespace、legacy／損壞／FIFO／symlink 皆保留。新增 notices 進正式要求視窗及遊戲庫摘要；不展示 argv，不提供無法保證的繼續／取消。掃描一個實際 worker、五秒觀察期限，重複 refresh 不增加 scanner；晚到結果不穿越 quit。狀態／刷新正常，沒有另建 directory consumer。
- forward 也限制一個實際 worker，五秒 monotonic budget 從 main admission 起算。副本寫入卡住時仍回一次未確認，物理工作占位保留；真正返回若已過期，保留原 ID 副本、不補送。收到 matching durable ACK 即回 accepted，後續 best-effort 副本清理不延遲這個已知結果；清理完成才釋放 physical worker。
- `test-cyder-outbox.sh` 驅動正式 journal／coordinator／outbox 與 AppKit projection：保存 ACK 遺失副本、已派送副本後重開，僅清理 matching accepted、無重播；缺失／衝突／舊 namespace／legacy／FIFO／symlink 原檔保留；正式 action 入口拒絕 unknown notices，argv 不外露。60 次 refresh 遇到受控 reader stall 只有一個 physical read，主 event loop 可前進，quit 後無晚到 UI。512 筆容量拒絕新寫入，超額掃描回錯誤而不清空。`outbox-C6-r4.log` 為最終通過，要求 completion artifact 存在。
- 同一 harness 的實際 socket secondary 於副本寫入前受控卡住，縮短至 0.2 秒的測試期限回 false；60 次額外 forward 均 busy。釋放後留下唯一原副本、primary 沒有收到 launch、沒有第二次 completion。這是故障注入期限，產品仍五秒。`instance-C6-r3.log`、`request-ui-C6.log`、`channel-C6.log` 回歸通過，涵蓋單一 primary、真實 socket framing／lost ACK retry、batch、quit/dispatch race、重開與正式 AppKit resume/cancel 能力。
- 本批新增測試各輪皆通過；後續兩項檢查改善了 admission 起算期限及 accepted 與 cleanup 的分離，改動後重跑相關測試與建置。完整 universal macOS11 build 最新 `build-C6-r2.log`，隔離包 `/private/tmp/cyder-lifecycle-c6-build/Cyder.app` 配置 local.cyder.lifecycle-c6、CD2 support/runtime、ad-hoc 簽章，manifest `build-C6-source-sha256.json`。本輪未啟動完整 app／Wine；本節證據為 L1–2，不代表 Wine／NGS 相容性。

C6 仍有明確範圍限制：未接受副本目前只核對、保留與呈現，尚未提供經驗證的原 ID 明確重送／撤回；secondary 未確認 fallback 尚未接上遠端狀態查詢。詳細 feedback owner／錯誤分類、跨崩潰 supervisor ownership／late-spawn fencing、環境 waiter 分工、精確程序／視窗操作、剩餘 action I/O 及 V01–V14 最終矩陣繼續處理，目標不標完成。

## C7：原 ID 的明確重新傳送與取消

- C6 的未接受副本現在可於正式要求視窗操作「重新傳送」／「取消」，僅限 canonical outbox filename、有效 payload／digest、目前 journal namespace，且核對快照中尚無該 ID 的紀錄。其他 unknown／corrupt／conflict／舊 namespace 仍無假動作。能力只是 UI 投影，實際操作重新讀取 private FD 並比對原 ID／digest；檔案已替換或狀態改變時拒絕或交由 journal 判定。
- 重新傳送直接以原 ID／原 payload 進入唯一 journal submit transaction；若競爭者先接受，接回原紀錄，既有 delivered fence 保證不重複派送。重開後的 awaitingUserResume／uncertain 仍不會因此自動重播。取消以同 ID／digest 保存 tombstone，之後晚到 submit 接回 cancelled；已跨 dispatch 的 cancel 回失敗，不能顯示成功或終止程式。
- 一個實際 recovery action，與 outbox scanner 共用有界 owner；五秒觀察期限不釋出卡住的工作。若檔案核對晚於期限或 quit，不能再送 journal mutation。已交給 journal 的 mutation 若晚到仍按其持久結果更新狀態，沒有重複 completion。副本清理保留 physical slot 至真正返回，接受結果不等待清理。核對失敗後刷新 notice，避免留下指向舊 bytes 的能力。
- `test-cyder-outbox.sh` 增加真正 AppKit table-cell NSButton／selector→coordinator→journal 路徑：原 ID 重送一次、舊 button 再點不派送；取消 tombstone 後經實際 socket 晚到 submit 回 cancelled；替換 bytes 後按原 row 拒絕、原檔保留；外部 submit 先接受並 authorizeDispatch 後，舊取消要求不能成功。另以受控 recovery read stall 驗證期限一次、60 次 busy 不增加 physical read、quit 後 journal 仍空且原副本保留。最新 `outbox-C7-r8.log` 通過，保留 C6 所有容量、格式、掃描與轉送斷言。
- 保留失敗：r3／r4 顯示副本核對失敗後未更新舊 notice，正式 guard failure 分支補 refresh；r5 的新 deadline fixture 在 start 後才註冊 onOutboxChanged，漏掉快速完成事件，改為先註冊後啟動。未延長期限或刪除斷言，r6／r7 通過。`request-ui-C7.log`、`instance-C7.log` 回歸通過。
- 已檢視 `.local/lifecycle-evidence/outbox-C7.png` 的正式 contentView 渲染，原要求標題／說明及重新傳送、取消按鈕可讀且未裁切；外圍/footer 透明區於離屏 viewer 顯黑，並非桌面截圖。最新 universal macOS11 build `build-C7-r2.log` 通過；隔離包 `/private/tmp/cyder-lifecycle-c7-build/Cyder.app` 配置 local.cyder.lifecycle-c7、CD2 support/runtime 與 ad-hoc 簽章，manifest `build-C7-source-sha256.json`。本輪沒有啟動完整 app 或 Wine，以上為 L1–2，不能宣稱 Wine／NGS 相容性通過。

C7 補齊 primary 端未接受副本的明確恢復操作；secondary fallback 的遠端狀態核對、詳細 feedback owner／錯誤分類、supervisor 與跨崩潰 late-spawn fencing、環境 waiter、精確程序／視窗動作、剩餘主執行緒 action I/O 與 V01–V14 最終交付仍待完成。目標保持進行中。

C7 提交前追加：恢復核對返回時也直接比較同一 monotonic expiresAt，不能只依主佇列 deadline callback 是否已送達；r8 與第二次 universal build 重新通過。

## C8：supervisor 握手前不得提早釋放實際操作

- 確認並重現正式 shell 的缺陷：detached supervisor 尚在前置 attach 工作，父 launcher 的 250×0.01 秒握手輪詢到期便返回失敗；ProcessRunner 因父程序實際退出而釋放環境 lease，但背景子程序仍可能稍後啟動。`supervisor-C8-baseline-r3.log` 以正式 `cyder_run_wine_exe`＋`CyderProcessRunner`＋`CyderOperationGate` 重現「native launcher released mutation ownership before its delayed supervisor handoff」。失敗前先釋放受控 gate、等待子結果，不留下故意卡住的 fixture。
- 正式 `cyder-common.sh` 不再以握手觀察期限代替 executor 結束。父程序持續等待 PID 發布，或由 Bash 自己的 child job table 確認該直接子工作已結束，再 wait 取真實退出碼；不以系統 kill -0／PID 重用猜測。握手前失敗保留非零 child status，無狀態且無 PID 才回一般失敗。背景輪詢為 0.1 秒，AppKit 不等待；既有 native 觀察期限仍可回 unconfirmed，實際 owner 不因此釋放。
- 新 `test-cyder-supervisor-owner.sh` 使用隔離 support/runtime/prefix、空 EXE 路徑；只把 sentinel attach 與最末 Wine 執行替換成受控 native 函式，正式 launch、PID/result 發布、wait、runner、gate 都實際執行。六秒 attach stall 中主 event loop 可前進、觀察先 unconfirmed、同環境後續 lease 仍等待；放行後 native worker 才成功返回、lease 一次釋放，root result 保留 53。握手前 supervisor exit 37 回原碼且未 spawn。另驗 runner quiesce 不終止已授權子工作，觀察結果不改寫、實際返回後才 release。`supervisor-C8-r2.log` 及 artifacts 通過。
- 保留 fixture 失敗：baseline／r2 未進入目標點，r2 保存 launcher log 後確認 `cyder_init_paths` 參數錯用 repo root，導致 resolve-wine-locale 路徑錯誤；改用 scripts directory 後 r3 才算有效基線。新增每個等待點的呼叫行號與可選 artifacts 保存；清理先放行本 fixture 的 gate，不全域終止程序。
- `test-cyder-launcher.sh` 回歸通過（`launcher-C8.log`），事前已讀取全檔，使用其隔離 runtime／fake arch、Wine、wineserver 及安裝器；測試 log 內兩行 fake wineserver 的空 stop-log 警告仍保留，不當真實 Wine 執行。`test-cyder-sentinel.sh` 靜態接線回歸通過（`sentinel-C8.log`），不當 runtime 證據。Bash syntax／diff 檢查通過。
- universal macOS11 build `build-C8.log` 通過。隔離包 `/private/tmp/cyder-lifecycle-c8-build/Cyder.app` 配置 local.cyder.lifecycle-c8、CD2 support/runtime 與 ad-hoc 簽章，manifest `build-C8-source-sha256.json`。完整包本輪未啟動；以上為 L1–2，不是真實 Wine／NGS 或完整退出 computer-use 證據。

C8 只修復「握手前父程序自行逾時退出」造成的實際所有權破口。PID 目前仍可能代表 log/Wine wrapper，而非已完成 Wine exec 的證據；PID 發布後的 wrapper lifetime、持久關聯回執、跨 primary crash 的操作鎖接管仍未完成。既有每 launch shell waiter 也尚未與每環境 monitor waiter 整合。後續須繼續解決這些核心門檻，以及精確 process/window action、剩餘 UX／I/O 與 V01–V14 全矩陣，不能標目標完成。

## C9：跨 primary 的原生 executor 票據與操作鎖

- 正式 CyderSwift 增加 AppKit 初始化之前的 execution-owner helper。非觀察 launcher 先保存 private prepared 票據，再由 helper 取得跨程序 scope／owner locks，原子保存 active 與 boot UUID／PID／微秒出生時間，才建立真正 Bash 子程序；等待 actual child outcome 後保存 finished。argv／environment 不寫入 ledger。UI 的觀察期限不終止 helper 或提前釋放鎖。
- 票據及鎖採同 UID、0700 目錄／0600 regular file、NOFOLLOW／NONBLOCK、FD-based 讀寫與 fsync／rename；512 筆／逐檔 8 KiB 有界。環境 scope 使用 UID／device／inode，symlink 別名共享操作鎖，票據保存的 prefix 被替換時拒絕執行。全環境鎖與個別環境鎖共同覆蓋 launcher 及正式 GPTK filesystem maintenance。
- 新 primary 在啟用 request channel 前核對舊票據：未認領 prepared 撤回，活躍 owner lock 保留；owner 不在但 active 尚未確認者轉 uncertain，禁止重播或同 scope 新副作用，其他 prefix 可繼續。已確認不同 boot 的舊票據可撤回。原始資料損壞即拒絕取得派送權，不清空修復。
- 新 test-cyder-execution-owner.sh 實際啟動原生 helper／受控 shell：prepared 撤回後晚到拒絕、一次認領、同 prefix／symlink／global 衝突、另一 prefix 並行、child 真正退出碼 23、原生出生身分、GPTK 共用 scope barrier、prefix 替換拒絕、argv 不落盤。核對出生身分後只終止本 fixture 的 helper，確認存活子程序未遭停止；重開轉 uncertain、同 scope 拒絕而其他 scope 正常。boot boundary 使用明確注入的 metadata，不是真實重開機。
- 最新 standalone `execution-owner-C9-r5.log` 通過；使用完整建置中 CyderSwift 的實際 helper 入口重跑同套，`execution-owner-C9-app.log`／artifacts 通過。coordinator harness 新增 prepared 票據，在 primary 回呼時已撤回的順序斷言；`instance-C9-r2.log` 通過。`request-ui-C9.log`、`outbox-C9.log`、`settings-ui-C9-r2.log` 回歸通過。
- 保留失敗：首輪 typecheck 的 default module cache 權限拒絕，指定隔離 cache 後通過；r1 新 fixture 的 throwing autoclosure 編譯錯誤已修正。r2 在 sandbox 無法讀取 BSD／boot 身分，頂層 throw 令 fixture 31392 停在 OS UE；確認該 fixture 的完整執行身分後僅嘗試一次 SIGKILL，未把停滯當成功。改為明確 do/catch exit 並以 desktop 權限執行同原生測試，r3–r5 通過；原 r2 資料保存在 artifacts。
- universal macOS11 `build-C9-r2.log` 通過。隔離包 `/private/tmp/cyder-lifecycle-c9-build/Cyder.app` 配置 local.cyder.lifecycle-c9、CD2 support/runtime、ad-hoc 簽章並驗證；manifest `build-C9-source-sha256.json`。本輪啟動的是該包原生 helper，未啟動完整 GUI 或 Wine，以上是 L1–2 證據，不能宣稱 Wine／NGS 相容性。

C9 尚未解決 detached Bash 返回後的 wrapper late-spawn 交接；helper 崩潰但子程序存活時安全保留 uncertain，尚無完整結果接回。票據也尚未直接攜帶 request／launch correlation，finished／revoked 安全回收尚待加入（目前滿 512 筆會拒絕新工作，不能無界成長）。這些限制、環境 waiter、精確 process/window action、其餘 UX／I/O 與 V01–V14 仍繼續實作，目標不標完成。

## C10：原要求關聯回執與終態票據回收

- 正式 launch 將原 request ID、payload digest、launch ID、executor epoch 帶入 executor 票據；格式有界驗證，派送世代不符時拒絕建立執行權。helper 實際執行及結束時保留這些識別，另保存 exit／signal 區別。argv／environment 仍不進 ledger。
- primary 啟動後、要求刷新及 native operation 實際返回時，背景核對 executor 票據。journal 僅接受四項識別全相符且 ticket ID 一致的回執；舊階段、替換的 owner／child 出生身分與互相矛盾的終態不覆寫已保存證據。一次批次原子持久提交後才回確認，ACK 遺失可重試。這只是 native executor／Bash 層證據，不改 dispatch／uncertain 為 Windows 啟動成功，也不授權 resume／重播。
- 回執核對同時最多一個 physical worker，磁碟工作不進 main。執行期間多次刷新合併成至多一個待辦位，實際完成後再讀，避免較早快照漏掉同時返回的新結果；卡住時不增加 worker，quit 後不補送 journal 工作或更新畫面。無需等待這個額外核對才顯示 primary UI。
- executor 容量仍為 512 筆。達到 128 筆時 prepare 可回收無 request 關聯的 finished／revoked，只保留 32 筆此類診斷票據（依檔名排序，不稱最新）。有關聯者須先寫入正式 journal 且取得 exact snapshot ACK，才能回收。每筆删除前取得 owner lock、重讀全票據等值，只刪 terminal；active／prepared／uncertain、未知或衝突關聯都保留。不刪 journal 的 request 去重紀錄，其原容量與拒絕策略不變。舊 helper 必须重讀票據，已回收 ID 不會重新建立權限。
- `journal-C10.log` 通過：注入錯誤 request／digest／launch／epoch、before-write failure、after-commit ACK 遺失、舊 active／換 ticket／換 child 回執；原回執持久保留、重開仍 uncertain，authorize／resume 均拒絕。這些 process 數值是明確注入的 journal 證據，不是真實 Wine PID。
- `instance-C10-r2.log` 通過：無 primary 期間注入的 finished 回執在重開後接回原要求，持久保存後才刪 executor 副本，無 launch 重播／成功誤判；新增受控 reader stall，60 次刷新只有一個 physical reader，main event loop 仍前進，放行後只追加一輪且正常退出。既有 election／startup deadline／corrupt history 斷言全保留。
- `execution-owner-C10.log` 通過原生 helper 與 512 筆 injected terminal retention 測試。最新 fixture 增加真正 native helper 的 correlation／termination reason 斷言，並使用完整建置的 CyderSwift helper 入口重跑，`execution-owner-C10-app.log`／artifacts 通過。exact ACK 前後、stale ACK、uncertain 保留及已回收票據晚到拒絕均通過；log 的 unavailable 是刻意執行已回收票據的預期拒絕。此次沒有新增失敗輪次。`outbox-C10.log`、`request-ui-C10.log` 回歸通過。
- universal macOS11 build 最新 `build-C10-r2.log` 通過；隔離包 `/private/tmp/cyder-lifecycle-c10-build/Cyder.app` 配置 local.cyder.lifecycle-c10、CD2 support/runtime、ad-hoc 簽章並驗證；manifest `build-C10-source-sha256.json`。本輪只啟動正式包的原生 helper，不是 GUI／Wine／NGS 相容性驗收。

C10 補齊 executor 與原要求的可核對關聯及安全終態回收；它仍不能把 Bash 返回當作 Windows 已 exec。detached wrapper 的 late-spawn／最終執行權交接、helper 崩潰後的同 boot uncertainty 收斂、環境 waiter、精確 process/window action、剩餘 UX／I/O 與完整 V01–V14 矩陣繼續處理，目標保持進行中。

### C11 基線：PID 公布後的 late-spawn

- `.local/lifecycle-evidence/late-spawn-C11-baseline.py`／log 使用 C10 完整建置的原生 helper＋正式 cyder_run_wine_exe，只把 sentinel attach 與最後 Wine call 換成受控 native function。實測 pidPublished=true、nativeExit=0、ticket.phase=finished，但 effectBeforeRelease=false；放行後才產生 effect，正式 result 保存 exit_status=53。fixture 位於 `/private/tmp/cy-c11-late-spawn-2os1a2fz`，已放行並收到 result，未啟動 Wine。這是確認存在的產品交接缺口，不是修復通過。
- 已核對隔離 engine 的 bin/wine 為 Mach-O x86_64。後續實作需把最末 Wine spawn 經過一次性原生執行入口，並將 PID／回執發布延至這個入口的真實 spawn；維持原 power policy 與 stdout／stderr 生命週期，同 prefix 後續 launch 不應等遊戲退出。
- Apple 官方 [posix_spawn(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html) 記載成功返回會提供新 child PID，失敗回錯誤且不建立 child；[setbinpref_np](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setbinpref_np.3.html) 可明確選取 x86_64 slice；[setflags](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setflags.3.html) 說明 START_SUSPENDED 在 user-space 執行前暫停，但單靠暫停會引入 helper 崩潰後留下停止程序的風險，尚未採用。這些文件是 API 決策依據，不是本產品執行或相容性證據。


## C11：最後 Wine spawn 的一次性交接

- 正式 detached launch 現在使用同一張 executor 票據中的 Handoff：prepare 以 Foundation 固定 Wine executable canonical path，最後 wrapper 必須驗 owner boot／PID／出生時間、目前 prefix UID／device／inode 及 executable。先在 spawn lock 下持久保存 claiming，才可建立原生 Wine 子程序；同一 ticket 不得再認領。owner 的 Bash 結束結算也取得同一把鎖，避免「Bash 已退出、舊 wrapper 尚能 spawn」競態。
- 原生入口在 AppKit 初始化前執行，直接 posix_spawn Mach-O Wine，明確要求 x86_64 slice；taskpolicy 若有選用仍套在此 helper 與其後代之前，並保留原 stdin／stdout／stderr、cwd、Wine environment。Wine 不繼承 CYDER_EXECUTION_ 執行權 transport。spawn 成功後核對尚未 reap 的直接 child 出生身分（包含立即結束的 zombie），保存 spawned／handedOff 後才原子公布 PID；該 PID 不再是 log wrapper。sentinel、session registry 與 shell result 對應實際原生 Wine PID。
- handedOff 只表示原生 Wine executable 已建立，不代表 Windows 根程序或視窗已可用。外層 scope 仍持有至 Bash 真正返回；之後同 prefix 操作可前進，不等遊戲退出。native helper 等待自己的 child 並保存 exact exit／signal；此等待不在 UI。Bash 結果及原生 root 結果分開保存，第二個結果到達才封存 finished，避免快退出時寫入不完整且不可更新的終態。
- owner 崩潰時，未取得合法 claim 的 wrapper 不得再 spawn；已有原生 spawn 證據的 handoff 可接回，child 不被終止。尚無足夠證據者仍 uncertain，不猜沒有啟動。讀取驗證 Handoff／NativeSpawn schema，未知 phase／缺少原生出生身分不能当作交接成功；corrupt bytes 保留。GC 同時取得 owner／spawn locks，回執持久進 journal 後才刪 terminal，root 結果不因原 executor 副本回收而丟失。
- journal 新增原生 spawn 子回執，bridge／root 各自含 boot／PID／出生時間，並獨立拒絕階段倒退、換 bridge 或換 root。仍不把 native success 改成 request completed，也不授權舊要求重播。`journal-C11-r2.log` 通過含這些注入身分的斷言；`execution-owner-C11-r2.log` 通過所有 C9／C10 回歸及未知 handoff schema 保留檢查。
- 新 `test-cyder-native-handoff.sh` 編譯可信最小 x86_64 Mach-O 替身。正式 shell 的 quiet-log wrapper 在 mkfifo 前受控停滯，正式 cyder_exec_wine／native bridge 不替換：未放行前 scope 仍占用且不公布 PID；別的 prefix 可前進，recovery 不撤銷活 owner。放行後 receipt／PID 檔與真正 x86_64 child 一致，重複 bridge 拒絕，同 prefix 下一個操作在原 child 退出前成功。放行 child 後保存 exact 53；另跑十次立即退出保留出生身分及兩層結果。
- 同一 fixture 只終止自己尚未 reap 的 Popen owner child：spawn 前 owner crash，late wrapper 拒絕且沒有 native child；spawn 後 owner crash，native child 繼續、handoff 可恢復，新 scope 可取得；root 後來退出保存 53，但不捏造已失去的 Bash result。不可執行的 Mach-O 測試保證 posix_spawn 錯誤不公布 PID、不卡住，並修復 supervisor cleanup 蓋掉實際 failure 的缺陷。最新 standalone `native-handoff-C11-r6.log`、完整包 helper 加包內 scripts 的 `native-handoff-C11-app-r6.log`／artifacts 全通過。這是 L2 原生 x86／故障注入，不是 Windows／NGS 測試。
- 保留失敗：最初 r1/r2 票據由 Python 手寫 executable path，與 Foundation 對 /private/tmp 的 canonical 表示不同，正式 guard 回 executableChanged；改由正式 prepare 正規化並建票據後 r3 通過，不放寬比對。app-r3 誤與同路徑重建重疊而找不到 helper，未啟動 fixture owner；之後只在建置完成後測。最終 harness 清理也等待 detached native receipt 與 orphan test Bash 的完成確認，未確認時保留 fixture，不先刪 release markers。app-r4 把包內 ogom-scripts 當 Resources 傳入，fixture 缺正式 context 的 CYDER_SCRIPTS，找不到 locale helper；按正式 launcher 的 Resources-root 初始化及 context 修正後 app-r5 通過。失敗 logs／artifacts 皆保留，未算成功樣本。
- `supervisor-C11-r2.log` 保留 C8 的延遲握手／原碼／quiesce 不殺子程序斷言並通過；`launcher-C11.log` fake-engine 回歸通過，原本兩行 fake wineserver 空 stop-log 警告仍在；`sentinel-C11.log` 是靜態接線通過。`instance-C11-r2.log` 另驗正式 coordinator 將獨立 root status 53 保存進原 request，才回收 executor 副本；request 仍 uncertain。
- 另以真實已知 test engine、全新 private prefix、正式 C11 helper 執行 `wine --version`，`wine-version-C11-r2.log` 返回 wine-11.0／status 0，PID／出生回執與結果吻合。這證明真實 x86 Wine CLI 可通過原生入口；沒有 Windows app／GUI／NGS 相容性結論。
- 最新 universal macOS11 build `build-C11-r3.log` 通過；`/private/tmp/cyder-lifecycle-c11-build/Cyder.app` 使用 local.cyder.lifecycle-c11、CD2 support/runtime、ad-hoc 簽章並驗證，manifest `build-C11-source-sha256.json` 同時核對包內 common／launcher 與 repo bytes 相同。完整 GUI 本輪未操作，未覆蓋正式安裝或發布。

後續仍須完成：獨立 taskmgr 的舊 detached 路徑尚未接 final handoff；launch 中的 GPTK runtime symlink 設定須再核對全域互斥範圍；legacy sidecar／log-drain 與每環境 waiter 仍待整合到原生關聯事件。C11 修復本節的正常遊戲 launch 最末 spawn 交接，但沒有解決所有同 boot uncertainty 的收斂、精確 process/window action、剩餘 UX／I/O 或 V01–V14 全矩陣，不能標整體完成。

## C12：工作管理員交接及執行憑證隔離

- 正式 taskmgr-prefix 原先 fork 後立即返回，尚未到 cyder_exec_wine 即釋放 owner。新增 frontend gate 驅動正式 cyder_open_prefix_taskmgr，`taskmgr-C12-baseline.log` 明確重現「task manager released authority before its final spawn」。失敗 fixture 已放行且保存 artifacts，沒有啟動 Wine。
- runLauncher 現為工作管理員建立同一原生 Handoff 票據及 private、唯一 PID transport。正式 shell 設定 final 入口，等待原生 spawn 公布 PID 或直接子工作實際結束，再返回；握手前錯誤保留原碼。scope 不等待工具整段壽命，native receipt 保存真正 child 的出生身分與退出碼。transport 在實際 ProcessRunner release 的背景 callback 刪除，觀察逾時不提前刪除。
- 正式 Swift／Bash 遊戲設定都禁止覆寫 CYDER_EXECUTION_ namespace。每個原生 owner 清除繼承的該 namespace，再依本張票據重建需要的 handoff transport；一般操作不攜帶舊執行權，最終 Wine child 仍不繼承此 transport。settings snapshot 測試注入四個覆寫值，確認合法 transport 未變而一般自訂變數仍套用；原生 owner fixture 注入 stale authority，確認其真正 Bash child 全部清除。
- `taskmgr-C12-r2.log` 及完整包 helper＋包內 scripts 的 `taskmgr-C12-app.log`／artifacts 全通過。frontend stall 期間 owner active、未公布 PID、同 scope 拒絕；放行後 PID 等於 native receipt，下一個同 scope 操作可在工具退出前成功，工具結果 53 保留。C11 的 log stall、late bridge、spawn 前後精確 fixture owner crash、不可執行檔與十次快退出斷言同時回歸。
- `execution-owner-C12.log`、`settings-C12.log`、`settings-snapshot-C12.log` 通過。Bash syntax、diff 檢查通過。測試使用可信自建 x86_64 Mach-O 與隔離檔案，沒有 Windows app／NGS 結論；本輪未從完整 AppKit 選單點擊工作管理員，該接線由 universal 編譯驗證，不能冒稱 GUI 實測。
- universal macOS11 最新 `build-C12-r2.log` 通過；隔離包 `/private/tmp/cyder-lifecycle-c12-build/Cyder.app` 配置 local.cyder.lifecycle-c12、CD2 support/runtime、ad-hoc 簽章並驗證。`build-C12-source-sha256.json` 保存來源及包內程式 hash，核對 common／launcher 與 repo bytes 相同。完整包測試在建置完成後執行，未覆蓋正式安裝。

C12 完成 taskmgr 的 late-spawn 修復。後續 GPTK 共享 runtime symlink 的變更仍需全域互斥；native receipts 與 lifecycle 事件、環境 waiter、精確 process/window action、剩餘 UX／I/O 及 V01–V14 全矩陣繼續處理，整體目標保持進行中。

## C13：GPTK 共用連結的全域操作權

- `runtime-C13-baseline.log` 用保留的完整 C12 helper／scripts 重現 prefix-only launch 仍修改共用 GPTK tree。自建 x86 替身及 inert GPTK files 位於 fixture，沒有載入 GPTK dylib。舊包執行 cyder_apply_gptk_launch_environment 後建立連結並產生 runtime.changed，斷言失敗；原始 logs／artifacts 保留。
- 正式 launch preflight 背景檢查目前 GPTK 來源及 engine 連結。缺少、失效或指向其他來源者先排入既有 all-environments operation gate，取得 lease 後才 authorize 原要求；已吻合或引擎自帶有效 GPTK 者維持個別環境 scope。native ticket 增加 requiresGlobalScope，保留真正 prefix UID／device／inode 供 Wine handoff 核對，同時以全域 lock 持有共享修改權。原生 owner 結果不明時，全域 barrier 不能退化成只阻擋原 prefix。
- Bash 在原生 scope 下再次檢查：不需變更直接返回；若 discovery 在排程後改變、但未取得全域權限，返回 75，保留原 link，不自行升級或重播啟動。需要修改時只有原生 owner 從票據重建的 CYDER_EXECUTION_RUNTIME_MUTATION=1 才允許。此 namespace 已由 C12 在兩種設定讀取端封鎖，child 不繼承偽造值。獨立 CLI 維持既有行為，沒有宣稱不經 owner 的手動 CLI 已加入跨程序 lock。
- `gptk-C13.log` 驅動正式 Swift preflight：缺少連結／dangling／其他來源需要全域權限，正確連結／有效實體 tree 不需要。`runtime-C13-r2.log` 與完整 C13 包的 `runtime-C13-app.log` 通過：prefix-only 拒絕且沒有修改；global owner 實際修復隔離連結、阻擋其他 prefix，真實原生 spawn 後保留 prefix identity，在 Bash 返回後釋放全域權限，子程序仍存活，最後保留 53。C11／C12 全部原生交接案例同套回歸。
- 首輪新 global case 放在「owner crash 後保持 uncertain」案例之後，被正式全域安全 barrier 拒絕；`runtime-C13.log` 及 owner log 保存原因。將案例移至 crash injection 之前，未放寬產品 uncertain 防護。`execution-owner-C13.log` 另注入全域 uncertain ticket，確認不同 prefix 的真正 native operation 與 withScope filesystem work 都被拒絕，只有明確注入的 prior-boot recovery 才撤回。該 boot 證據不是實際重開機。
- `operation-gate-C13.log` 驗證現有 global FIFO barrier、取消前派送、quit freeze、真實 owner 返回後 release。`game-settings-C13-r2.log` 回歸通過；首輪該舊 fixture 缺少 runtime/engines namespace，試圖對正式 engine 的 MoltenVK symlink 執行 ln -sfn，被 sandbox 拒絕。修正測試為所有次要 engine paths 明確落在 TMP 後重跑，沒有提權重試正式路徑。原失敗 `game-settings-C13.log` 保留。測試仍有既有 plutil 缺 key 訊息被當成 graphicsBackend 值後 fallback 的 warning，未刪除或當成實際 Wine 證據。
- universal macOS11 `build-C13.log` 通過；隔離包 `/private/tmp/cyder-lifecycle-c13-build/Cyder.app` 使用 local.cyder.lifecycle-c13、CD2 support/runtime、ad-hoc 簽章並驗證，manifest `build-C13-source-sha256.json` 核對完整來源與包內腳本。包內 helper／scripts 已實際測試，完整 AppKit 啟動選單接線本輪只有編譯證據，沒有新增 GUI／Windows／NGS 相容性結論。

C13 修復 GPTK 連結路徑的 scope；回歸盤點確認 MoltenVK preference reader 仍會修改另一個共用 engine symlink，須接續加上相同權限約束並避免唯讀讀取產生副作用。不能把 C13 稱為所有 shared runtime mutation 已解決。native lifecycle 事件、環境 waiter、精確 process/window action、其餘 UX／I/O 與完整 V01–V14 驗證仍持續。

C13 提交前追加：全域 scope ticket 使用 schema 2，普通票據繼續讀取 schema 1；避免舊 helper 忽略 requiresGlobalScope 後以 prefix lock 執行。最新 `build-C13-r2.log`、`execution-owner-C13-r2.log`、完整包 `runtime-C13-app-r2.log` 全通過，manifest／ad-hoc 簽章已更新。後者另外真正呼叫保留的 C12 helper：它拒絕 schema 2、未建立 child marker、原票據仍 prepared，隨後 C13 helper 正常取得並完成同張票據。此輪沒有新增 Windows／NGS 實测。

## C14：MoltenVK 設定讀取與共用 runtime 修改分離

- 新 `test-cyder-runtime-mutations.sh` 在隔離 engine 放置 inert dual-variant files，使用正式 settings reader。保留的 C13 包於讀取偏好時改寫 libMoltenVK.real.dylib，`runtime-reader-C14-baseline.log` 重現 FAIL reading saved settings modified shared runtime；未載入 dylib 或執行 Wine。
- 正式 cyder_load_saved_settings 不再變更 engine。所有 game target 共用的 cyder_run_wine_exe 在真正啟動前明確套用 MoltenVK；安裝／維護既有明確 apply 路徑保留。連結已符合時只驗證，不再 ln -sfn，避免每次讀取或 launch 都替換 shared link。需要更動時依 native scope 拒絕 prefix-only 操作，保留 75，不將其改為一般 1 或逕行重試。
- 背景 launch preflight 從原 accepted settings snapshot 取得 MoltenVK 偏好，檢查 dual layout 與所需 target，與 C13 GPTK 條件共同決定全域 lease；settings snapshot 缺失／不合法時暫停於派送之前。原生 owner 現對所有操作重建單一 CYDER_EXECUTION_RUNTIME_MUTATION 能力值，不限有 Wine handoff 的操作；root／ticket／helper／FINAL 仍只在需要時重建，不繼承舊憑證。GPTK guard 也識別這個值，非 handoff 的 prefix 子工作不再是可繞過的路徑。最終 Wine child 仍清除整個 CYDER_EXECUTION_ namespace。
- MoltenVK 為全域偏好，Swift／Bash 遊戲環境設定不再允許覆寫 CYDER_MOLTENVK_VARIANT_PREFERENCE。`settings-C14.log` 以正式 preflight 驗 legacy layout、缺 link、正確 link、dangling link；`settings-snapshot-C14.log` 驗原 accepted 1.2.10 不被後來的 1.4.2 或遊戲環境覆寫。`execution-owner-C14.log` 驗 inherited transport 清除且 runtime capability 由票據重建，保留所有既有 native/crash/recovery 斷言。
- `runtime-reader-C14.log` 與包內 scripts 的 `runtime-reader-C14-app.log` 通過：讀設定不改連結、prefix-only 更動返回 75、matching link inode 不變、global explicit apply 成功。MoltenVK Mach-O validation 的 otool 是明確替身，檔案為不可載入的 inert fixture；這不是實際 dylib／圖形相容性測試。
- `native-handoff-C14.log`、完整包 `native-handoff-C14-app.log`／artifacts 全通過。正式 native non-handoff prefix owner 無法改 MoltenVK；global owner 真正準備隔離 GPTK／MoltenVK、保持其他 prefix 排他直到原生 handoff 與 Bash 返回，子程序繼續，最後保存 53。既有 spawn 前後 crash、late bridge、taskmgr、快退出與 C12 舊 helper 拒絕 schema 2 仍通過。
- `moltenvk-C14.log`、`game-settings-C14.log` 回歸通過；後者仍保留先前已記錄的 plutil 缺 key／fallback warnings。Bash syntax、diff 檢查通過。universal macOS11 `build-C14.log` 成功；`/private/tmp/cyder-lifecycle-c14-build/Cyder.app` 配置 local.cyder.lifecycle-c14、CD2 support/runtime，ad-hoc 簽章驗證通過。`build-C14-source-sha256.json` 也新增核對包內 moltenvk-variant script 與來源一致。未啟動完整 GUI，未覆盖正式安裝或發布。

本批為 L1–2 權限／原生程序／故障注入證據，不是 Wine／NGS／圖形驗收。共用 runtime scope 只保護 Cyder 原生 owner 管理的操作，不替手動 CLI 或外部安裝器建立全系統互斥。接續仍須將原生出生回執接入 lifecycle 事件、整合每環境 waiter 與可靠收尾、精確 process/window action、其餘 UX／I/O 及 V01–V14 矩陣；目標不標完成。

## C15：原生 root 回執的連續核對與正式啟動觀察

- 盤點確認 C10–C14 只在啟動、手動 refresh 或外層 launcher 返回时讀 executor；原生 Wine root 稍後退出不一定接回。coordinator 現在於實際 spawn 記錄後啟動每秒核對，只保留一個 physical reader、一次 pending invalidation。active／handedOff／uncertain 的未完成 root 繼續核對；native terminal 必須 durable journal ACK 後才可停輪詢及回收副本，不能因本地 JSON 顯示 finished 就提前停。quiesce／stop 取消排程，晚到回呼不補工作。
- 無變化的 receipt 不再每秒重發 recovery UI 更新；有變化者仍先通過 request／digest／launch／epoch、ticket 與出生身分的 journal 驗證及持久保存，才通知 UI。app 的 recovery callback 也在 quit transaction 後拒絕更新。
- 正式 runWineThroughLauncher 已改用原生 receipt 推送至 CyderLaunchObserver，不再從 legacy result／lifecycle sidecar 決定 root 結果。觀察器逐一核對 request、launch、digest、executor epoch；同 ticket 的 root PID／boot／出生時間不可更換，exited 不可倒退。before-wait 到達的原生結果會保留到觀察建立；signal 結果轉為慣例 128+signal 供錯誤顯示，journal 仍保存原始 signal／status。正常 root 0 不等於後繼或環境退出，因此繼續原 deadline 等啟動證據。啟動／退出回呼都直接比較原 monotonic deadline，不能由晚送的 timeout callback 延長期限。
- `launch-observer-C15-r2.log` 通過：錯 request／launch／digest／epoch 拒絕，同 PID 不同出生拒絕、提前結果、native 模式完全不讀 legacy sidecar、root 0 後遲到啟動、signal 9→137、已過期觀察不被排隊中的啟動／結果繞過。原本受阻 reader 上限兩個、一次完成、晚到事件及安全 sidecar 的 legacy 測試保留；該 legacy 模式已非正式 launch consumer。
- `instance-C15-r4.log` 實際驅動 coordinator、journal 與同一正式 launch observer。初始注入 handedOff／spawned 原生 metadata，後續只更新 executor 檔、不手動 refresh；自動核對將 root 53 持久保存，送達 observer，再回收 terminal ticket，request 仍 uncertain，不猜 Windows 成功。自動第二次讀取受控停滯 1.2 秒，timer 未增加 physical worker；暫時移開本 fixture 的 journal directory 令真正 atomic write 失敗，未送 terminal 到 UI、未刪 ticket，恢復目錄後自動重試成功。stop 後再等待 1.2 秒，reader 數量不增加。此處 root／boot 數值為注入證據，不是真實 Wine PID。
- 第一輪 `instance-C15.log` 被舊字串「暫時無法確認啟動要求」斷言擋住，尚未進 runtime；檢查現行正式 enterReadOnly(.forwardUnconfirmed) 與 CyderUnavailableWindowController 可操作回饋後，將靜態接線斷言改成該現行路徑。既有 loader harness 的該視窗按鈕／不偽報取消斷言保留；不把字串測試當本輪 UI runtime 證據。instance runtime r2–r4 逐步加入自動 reader／fault／正式 observer 整合，最新完整 script 通過。
- 最新 universal macOS11 `build-C15-r4.log` 通過；早期 build 期間曾追加產品接線，未使用其產物驗收，最後完整重建時來源固定。隔離包 `/private/tmp/cyder-lifecycle-c15-build/Cyder.app` 使用 local.cyder.lifecycle-c15、CD2 support/runtime、ad-hoc 簽章並驗證，manifest `build-C15-source-sha256.json`。本轮未啟動完整包 GUI 或 Wine，以上是正式原始碼 harness／故障注入及編譯證據。

C15 尚未接通 native root 0 加環境排空的完成證據；目前 native 模式無視窗正常結束可在原期限回 unconfirmed，不能算 E 收尾驗收完成。接下來需將原生 prefix／出生身分綁入 lifecycle store 與 monitor，補正常 root／後繼／環境排空的結果，並移除重複 waiter、替換 legacy 數值 PID 的顯示／動作權威。完整精確 window action、其餘 UX／I/O 及 V01–V14 仍未完成，目標保持進行中。

## C16：正常 root 與環境排空的完成證據

- 正式 coordinator 現將 native ticket 的實際 prefix UID／device／inode key 保存至 journal，再送 launch observer；全域 runtime lease 的票據仍使用其真正 prefix identity。已存在的 key 不可改寫或移除，舊 journal 缺欄位時允許從同一票據補入，包含只有這個欄位變化的 terminal receipt；其他 terminal／出生資料仍不可倒退或更換。
- 正式 runWineThroughLauncher 在 beginExecution 時建立此輪專屬排空觀察；只有 exact request／launch／digest／epoch／ticket／root birth 的正常 native exit 0，才請 monitor 核對實際 prefix key。monitor 還要求該 execution 的 server generation 相同、所有可能派生 Wine 的 executor 已釋放，以及兩次相距至少 0.5 秒的新 empty calibration，才讓 observer 回 finishedWithoutWindow。這表示無視窗正常結束，並非 Windows 視窗已可用。alive／unknown 會清除 empty 序列；root 0 本身仍等待後繼或原觀察期限。
- beginExecution、實際 executor release 及正常 root proof 都重設 calibration revision；舊 revision 的受阻 probe／timeout 返回不再計入新排空序列，也不釋放額外 physical worker。正常 root proof 加實際 release 可省去另一段 30 秒 grace；一般無 proof 的 release 仍保留 grace。重複 track 已管理中的環境不再延長 grace；新的 executor 仍建立保護。server 出生世代更換會移除舊排空訂閱，cancel／quit／函式離開亦撤除訂閱。
- 正式 environment probe 的空 namespace／缺 lock 快速返回前再驗 prefix identity；lock 使用 O_NONBLOCK，FIFO 不會卡住兩個 probe slots。registry reader 亦改 nonblocking open，既有 private regular-file 驗證保留。
- 新 `test-cyder-launch-drain.sh` 編譯正式 monitor／probe／observer／lifecycle，`launch-drain-C16-r3.log` 通過：root 0 後仍有 executor 時，即使假時鐘超過 grace 也不結束；受阻的舊 empty 返回、晚到 alive successor、重複 track、兩次 fresh empty 才完成；錯 scope、相同數值 PID 但新 server birth、取消皆不誤完結。prefix replacement 使用真實目錄 inode 與正式 probe，舊 path 被移開再建立後保持 unknown。其他 server 狀態／root birth 為明確注入，沒有執行 Wine。
- `request-journal-C16.log` 驗證 scope immutable／舊 terminal additive upgrade／重開後保存；`launch-observer-C16.log`、`environment-monitor-C16.log` 保留 C15 exact-authority、固定期限、實際 executor barrier、恢復及一次完成回歸。`environment-probe-C16.log` 使用真正隔離 POSIX lock／socket／原生程序，另驗 FIFO 回 unknown；並非 wineserver 相容性實測。
- 首輪 `instance-C16.log` 在能讀取真實 boot ID 的測試環境下暴露舊 fixture 缺陷：虛構 boot 被正式 recovery 正確判為跨 boot，票據撤回後回收，與該案例預期的 live root 衝突。C15 的 fixture 通過依賴當時無法取得 birth／boot，不能作為完整跨 boot 證據。改用當前真實 boot，PID／出生時間仍明確注入；`instance-C16-r2.log` 全通過，包含 prefix key durable forwarding、自動 root 輪詢、受阻 reader 上限、真正 journal write failure／復原後持久 ACK／回收及 stop。未放寬產品 recovery。首輪 assertion 後 fixture PID 19013、出生 Mon Sep 21 14:13:30 2026、完整 argv `/private/tmp/cy-instance.R6Ad8f/test /private/tmp/cy-instance.R6Ad8f/state` 顯示 UE；精確核對後只送一次 SIGKILL，不宣稱已清除，也不反覆重試。
- `build-C16.log` universal macOS11 建置成功。來源在編譯期間固定；隔離包 `/private/tmp/cyder-lifecycle-c16-build/Cyder.app` 配置 local.cyder.lifecycle-c16、CD2 support/runtime，ad-hoc 簽章及 strict verify 成功，`build-C16-source-sha256.json` 保存 40 個來源／產物 hash，包內三支腳本 bytes 與 repo 相同。未啟動本輪完整 GUI／Wine，未改正式安裝、未發布。

C16 接通正常 root 加排空的正式完成路徑，但仍未將所有 native launch／process 寫入 lifecycle store 的單一模型；status item 的 legacy 數值 PID、精確 window／successor action、重複 waiter，以及 preparation 與 30 秒 observation deadline 分離等仍須完成。回歸使用的新 monitor 排空橋接不等於 A–F／V01–V14 全矩陣已驗收，整體目標持續。

## C17：準備與交棒觀察的期限分離、spawn 不阻塞狀態 queue

- 正式 runWineThroughLauncher 不再於函式進入就扣除 30 秒；native launcher 準備／handoff 返回後，CyderLaunchObserver.wait(duration: 30) 才在自己的序列 queue 建立單一 monotonic deadline。root 退出、晚到事件不重設它；取消後不可重開，第二個 wait 亦不能覆蓋第一個 continuation／期限。保留顯式 wait(until:) 供有既定期限的 caller／回歸使用。
- CyderProcessRunner 的準備工作仍有獨立期限（目前 launch native executor 30 秒）。期限現於操作登記前取得、登記後即排程，不再等 Process.run 返回才開始。Process.run 移到每 runner 最多兩個 physical spawn workers；狀態 queue 仍可交付逾時、inspect、quit，操作容量 32 保持不變，不因 timeout 再開同一底層工作。
- 已 claim 的 spawn 呼叫可能仍在 OS 內，因此 timeout／quit 只交付 unconfirmed，保留 output、operation 與 onRelease 到真正 spawn return／process exit；launch／mutation 不被 kill。尚未 claim 的 queued work 在 quit 時確認 cancelledBeforeSpawn，撤除 owner、關其 output，worker 隨後不能啟動它。Cyder 自有 observation helper 若在 timeout 後才真正 spawn，返回後才停止該 Process。快速 child 提早觸發 terminationHandler 時，必須等 Process.run 也返回才釋放，onSpawn 仍先於正常完成交付。實際 finish 直接核對 monotonic deadline，晚送的 timer 不延長觀察。
- `process-runner-C17-r4.log` 通過正式 runner 原生測試：立即退出／spawn error／output 保留／observer-only termination／quit，以及注入兩個受阻 spawn path 時五筆操作全數有界回 unconfirmed、physical count 仍為 2、inspect 保留 5 owners；quit 後只撤未 claim 的 3 筆，放行 gate 後原生 fixture 實際建立恰好 2 個 marker，五筆各只交付／release 一次。另加一筆尚未逾時的 queued launch，quit 明確回 cancelledBeforeSpawn，沒有建立 marker；立即退出案例也核對 onSpawn 在正常 completion 前交付。受阻 hook 位於正式 spawn worker 內，明確模擬 syscall 停滯；並非聲稱本輪真實 OS spawn 卡住或 Wine 通過。
- 同一 runner harness 另真正執行 0.5 秒的 native preparation，再透過正式 observer 開始 0.2 秒觀察並於 0.08 秒後注入啟動事件，成功完成，證明 preparation 沒有耗用 observation budget。`launch-observer-C17.log`／`open-files-C17.log` 通過重複 wait／cancel-before-wait 與既有 root／期限案例；Finder 接線檢查改為現行 duration API，未把文字檢查當 GUI 實測。`operation-gate-C17.log` 驗實際 runner release 前互斥不釋放及不同 bottle 前進；`launch-drain-C17.log` 保留 C16 正常 root／排空／舊世代回歸。首輪新增 fixture 的 throwing call 放在 precondition autoclosure 內無法編譯，`process-runner-C17-r2.log` 保留；改為先讀資料再斷言，r3／r4 通過，產品未因此放寬。
- `build-C17.log` universal macOS11 成功，編譯期间產品來源固定。隔離 `/private/tmp/cyder-lifecycle-c17-build/Cyder.app` 使用 local.cyder.lifecycle-c17、CD2 support/runtime；ad-hoc／strict verify 成功，`build-C17-source-sha256.json` 保存 40 個來源／產物 hash 並核對包內 scripts。未啟動完整 GUI／Wine，未覆蓋正式安裝、未發布。

本批修正 native Process.run 邊界及交棒觀察的期限；runLauncher 之前的檔案準備／身分解析、返回後 legacy PID transport 與 log tail 仍有需整理的 I/O，不能宣稱全部前置工作皆有界。native lifecycle store 完整接線、精確 process／window authority、重複 waiter、其他 UX／I/O 與 V01–V14 全矩陣仍在範圍內，目標不標完成。

## C18：原生程序出生身分接入選單與視窗歸屬查核

- 正式 launch 不再從 pid transport 檔建立選單程序身分。coordinator 的 durable NativeRoot proof 同時送 observer 與 status controller，觀察完成後的 native receipt 仍可更新既有群組。beginLaunch 綁定 request／launch／digest／executor epoch；attachNativeRoot 逐項核對該 authority、ticket、PID／boot／出生時間、prefix UID／device／inode key 與不可倒退的 root phase。移除未使用的 numeric-only attach／monitor／update／activation API；numeric PID 只剩通知提示、syscall 輸入與診斷輸出，Session 的 root／adopted／windowed sets、kqueue source key 均改完整 ProcessID。
- 新 CyderProcessEvidence 在背景查核同 UID 的 BSD process birth／parent。每個子程序候選須實際 parent PID 吻合、同 boot、出生不早於 parent，且父子身分在關係讀取前後一致；整個掃描最多 1024 個程序、每層最多 256 個候選。不可讀取不當成退出；明確不存在／zombie 或 PID 已屬於另一個 birth 才能撤掉舊程序。watch attach 前後也再核對；late exit／fork callback 使用捕獲的完整身分，不能刪除 PID 重用後的新程序。
- 首輪實際 native parent/child 測試失敗，找出沿用舊 helper 的 count bug：proc_listchildpids 已將回傳 bytes 轉成 PID 數量，舊 caller 又除以 sizeof(pid_t)，一個 child 會被當成零個。已核對 [Apple libproc 原始碼](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)，修正新 adapter 與舊 wineProcessTreeIDs。`process-evidence-C18.log` 保留失敗；fixture PID 29330、出生 Mon Sep 21 14:38:38 2026、argv `/private/tmp/cy-process-evidence.hHrIGp/test /private/tmp/cy-process-evidence.hHrIGp/state` assertion 後顯示 UE，精確核對後只送一次 SIGKILL，未宣稱清除。`process-evidence-C18-r2.log` 真正 native parent/child birth／tree 通過，另注入 PID／boot 重用、偽 child list、parent-edge race、早於 parent 的 child 及讀取失聯。
- Wine distributed／Workspace activation 現只觸發背景查核；Workspace handler 不再在 main 讀 WINEPREFIX，也不 fallback 至目前等待的 prefix。必須唯一對應已證實 root／descendant 且查到該完整出生身分仍在的可見視窗，才發 onWindowConfirmed(launchID)；app 只 signal 同一 launchID 的 waiter。單純同 prefix、通知 PID、程序存在不構成成功。移除 notification-driven automatic activate／yieldActivation 與直接 hideSetup；晚到／無歸屬通知不搶焦點、不關閉其他操作的進度。這不代表精確使用者視窗切換能力已完成，該能力仍須接續實作／驗證。
- wineOnscreenWindows(ownedBy:) 僅篩 caller 已核對的 PID 集合，不在核對後偷偷再擴張 numeric tree。window 查詢返回後再次核 birth，main 套用時驗 session version 及 exited birth tombstone；原生 exit 後晚到的舊 window snapshot 不可復活程序。保留已完成 root 的 immutable provenance 供已在途的 child 證據比對，沒有已知活程序的完成群組隱藏；環境 end 依實際 prefix key 回收，不用同一 pathname 誤刪新 inode 的群組。已知程序但無視窗改顯示「執行中；尚未確認視窗」，不從沒有 foreground 推測 tray/background。
- 新 `native-menu-C18-r2.log` 驅動正式 AppKit controller 與真實自建 native child，native receipt metadata／可見視窗資料明確注入。涵蓋錯 authority、不帶回執的通知、同 PID 異 birth exit、程序不等於視窗、同 prefix 的兩筆要求不共用啟動成功、受阻舊 window query 跨 native exit 後拒絕復活、舊 environment inode 不刪新 scope，以及觀察清理未停止真正 child。這不是 Windows／NGS 實測，也不是完整 Cyder.app 使用者視窗切換驗收。
- `status-item-C18.log` 通過 lifecycle reducer 與實際 AppKit menu callback harness；`menu-C18-final.csv` 30 次 callback-cycle proxy p95 0.032375 ms、max 0.045417 ms，包含 blocked query、tracking 不變更／不移除、快速重開、stale session／revision／epoch 拒絕。首次 sandbox 輪 `menu-C18.log` 未產生樣本，原因未完全確認，不計為通過；可操作 AppKit 的執行環境 r2／final 通過。`open-files-C18.log` 及 `sentinel-C18.log` 通過更新後的接線檢查與正式 launch observer 回歸；原要求 numeric pid-file attach／prefix activation 的舊 assertions 改為 native proof／launchID 接線，未拿字串檢查代替 runtime 證據。
- `build-C18.log` universal macOS11 成功，編譯期间產品來源固定。隔離 `/private/tmp/cyder-lifecycle-c18-build/Cyder.app` 使用 local.cyder.lifecycle-c18、CD2 support/runtime；ad-hoc／strict verify 成功，`build-C18-source-sha256.json` 保存 41 個來源／產物 hash，含新 process evidence source，包內三支腳本與 repo bytes 相同。完整包本輪未啟動，未覆蓋正式安裝或發布。

C18 改善正式程序／視窗歸屬的證據邊界；Session 呈現尚未全部遷入 LifecycleStore 的唯一模型，既有 native root 退出後才出現、已無 Unix ancestry 可驗的 Windows successor 仍需 explicit bridge／其他可靠證據，不能用 prefix 猜回。歸屬不明但受管理的程序、完整 process/window capability 與操作、server generation 到 process model 的接線、重複 waiter、其餘 UX／I/O 及 V01–V14 全矩陣仍須完成，整體目標保持進行中。

## C19：共用 reducer 的環境隔離與排空收尾

- 接入原生 request／process 之前，以新增 isolation harness 驅動正式 reducer，`lifecycle-isolation-C19-baseline.log` 重現 13 個失敗斷言：觀察中要求使已確認排空事件被丟棄、跨環境 exit／window close 改掉其他環境、同出生身分被移到另一環境、新世代沿用舊 launch 歸屬，以及未確認被記成 completed。基線是 C18 提交 f701f89 的 reducer；純事件 fixture 沒有啟動子程序或 Wine，失敗以 exit 1 回報，沒有 assertion crash。
- 已確認的環境結束由 monitor 完成 executor ownership、世代與雙樣本校準後送入，store 不再因 queued／observing 要求而丟棄它。要求本身仍獨立維持 UI；環境結束不推定遊戲啟動成功。結束會撤销該環境的 process／window capability、waiter／operation；同世代晚到 alive／scan 不可復活，必須先收到更高世代的 manage。此判斷沿用正式 monitor 的證據門檻，未把 wineserver -w 返回當排空。
- dispatchCommitted／observationFinished 現必帶 monitor epoch、environmentID、generation；store 記錄每個 launch 的原 stamp。新 server generation 清掉舊程序／視窗及 launch membership，尚未完成的舊觀察僅收為 unconfirmed 並只交付一次；新世代程序不能繼承舊 launch。匹配的 root＋drain 結果仍可在同世代環境退出之後完成。觀察完成不能宣稱 dispatch 後 cancelled；未確認要求改為 uncertain，成功與失敗保留原分類。
- process／window exit 逐項核對所在環境；未知程序的退出 tombstone 依 environment＋完整 ProcessID 保存，不能污染另一環境。已存在的程序不能被另一環境 snapshot 搬走。processObserved 的 exited 結果同樣撤销視窗並建立 tombstone，晚到 alive 無法復活。
- `lifecycle-isolation-C19.log` 通過新增案例及 stamp／epoch 錯配、取消邊界、重複完成、未知 exit 污染、exit snapshot；`lifecycle-C19.log` 保留既有固定取消／dispatch／quit 排列回歸。擴充原 `cyder_launch_drain_harness.swift`，讓正式 monitor 事件進入真正 CyderLifecycleStore，正式 observer 結果再回 store；`launch-drain-C19.log` 驗證正在 observing 時排空仍被接受，匹配結果完成後 canAutoTerminate，毋須第二次已不會送出的 monitor event。server 換代則保留 uncertain。clock、server／native root 證據明確注入；真實目錄身分替換案例仍保留，沒有 Wine／NGS 結論。
- `environment-monitor-C19.log` 通過正式 monitor/store 既有恢復、阻塞隔離、世代、排空與 quit；`status-item-C19.log` 通過 reducer 與 AppKit menu callback harness。原始 30 筆 callback-cycle proxy 保存於 `menu-C19.csv`，p95 0.030375 ms、max 0.034041 ms；不代表完整點擊至呈現延遲。
- `build-C19.log` universal macOS11 建置成功，編譯期間產品來源固定。隔離包 `/private/tmp/cyder-lifecycle-c19-build/Cyder.app` 使用 local.cyder.lifecycle-c19、CD2 support/runtime，ad-hoc／strict verify 通過；`build-C19-source-sha256.json` 保存 41 個來源／產物 hash，包內三支 scripts 與 repo bytes 相同。本輪未啟動完整包／Wine，未覆蓋正式安裝或發布。

C19 修正共用模型的接線前置缺陷，並加入 monitor → store → observer 的正式元件整合證據；正式 app 的 request／launch／process／window 全部轉入單一 store 尚未完成，不能將這個 fixture 接線稱為 app 遷移已完成。其餘 C18 列出的精確視窗操作、未歸屬程序、重複 waiter、UX／I/O 及 V01–V14 全矩陣仍持續，目標不標完成。

## C20：正式 launch、程序與視窗證據接入 store

- 正式 runWineThroughLauncher 在 journal 已提交 dispatching 之後，由 monitor 自己的序列 writer 為仍持有 execution registration 的 token 回傳 Stamp。不可用 pathname 或 main 上最後收到的 snapshot 猜世代；token 已釋放或 monitor 已停則不提供 stamp。app 用真正的 request／launch／digest 與 stamp 呼叫 beginLaunch，store 的 executionAttached 原子建立 observing request／launch，沒有 spawn effect，也不製造 queued 要求重跑歷史。缺少授权／世代就保留 unconfirmed。完整 journal 歷史／queued 顯示尚未全部遷入此模型，原可靠 coordinator 仍是唯一派送者。
- CyderLaunchObserver 在自己 queue 真正開始 wait 時，將同一 monotonic deadline 公布給 store；準備期間不先扣除 30 秒。觀察結果及準備失敗／不明由 app 的單一 defer 回 store，重複起始不能延長期限。actual runLauncher／journal finish／operation gate 沒有新增第二個 consumer。只記錄現有已授權 executor，不因模型 attach 而再啟動。
- Session 現綁定原 stamp；native receipt 除 request／launch／digest／executor epoch 及 birth 外，還須符合 stamp 的實際 UID／device／inode scope。已驗 root、descendants、真正 kqueue exit 送 processObserved／processExited；native terminal receipt 同樣撤销 store 內完整 birth 的存活資格。程序證據以一批事件送入 store，保留每個 effect，只交付一份快照，避免掃到 1024 個程序便產生 1024 份漸增模型。window 與相應 process evidence 也同批提交。
- Core Graphics 查詢保留 kCGWindowNumber，WindowID 使用完整 ProcessID＋coregraphics source＋window number，不使用標題或把它當 Windows HWND。已核對 [Apple kCGWindowNumber 文件](https://developer.apple.com/documentation/coregraphics/kcgwindownumber)：它識別目前使用者 session 內的視窗。只有 CG 身分尚不足以提供精確切換，因此 capability 明確為 unsupported；沒有製造可點但無效的 action。關閉／最小化／焦點及後續能力查核仍待接續。
- 正式已綁定群組的選單列、排序、starting 狀態、tooltip 現讀 store 的 request／launch／process／window 快照；同名以穩定 ID 排序。legacy Session 保留為觀察 adapter 及未綁定測試接縫，不再用已綁定 Session 的 activated flag 獨立維持 app。環境退出或更高世代會退休對應 session、取消其 watcher；舊回執不能重建群組。視窗成功通知改為 reducer 接受 windowObserved 後的 windowConfirmed effect，不能在 store 拒絕舊世代前直接 signal observer。現有視窗紀錄是已觀察證據，尚未完成持續 closed／minimized 更新，不能宣稱目前視窗狀態完整。
- 新 `test-cyder-lifecycle-binding.sh` 真正寫入隔離 journal、提交派送、註冊正式 monitor、取得 stamp、讀取真正自建 native child 出生身分，經正式 status adapter／store／observer 及 AppKit 選單驗證。`lifecycle-binding-C20-r5.log` 通過錯 scope 拒絕、root／window 與要求關聯、真 observer deadline／完成、native terminal 撤销視窗、更高世代退休、released token 不再取得 stamp，以及 quiesce 未停止 child。window 77 與 terminal receipt 明確注入；fixture 的自行啟動 native child 不是 Wine executor，不宣稱完整 Cyder GUI／Wine／NGS 已驗證。r1 缺少 unknown enum 的必要字串參數而編譯失敗，`lifecycle-binding-C20.log` 保留，沒有啟動 fixture；r2–r5 通過，後續輪次分別驗批量交付、store 核可後交棒及量測。
- 同一已綁定群組、故意受阻的視窗查詢下，r5 保留 30 筆 callback-cycle proxy：p95 0.037625 ms、max 0.0865 ms，原始資料另存 `bound-menu-C20.csv`。另 `status-item-C20-r2.log` 的既有 AppKit callback harness p95 0.033625 ms、max 0.048125 ms。兩者都不是完整點擊至呈現或真實 tracking 延遲。`lifecycle-isolation-C20-r4.log` 通過 attachment 不派送／不接回 uncertain、deadline 只設一次、錯 scope 不發視窗成功，以及 1024 個程序加 quit 的批次只交付一次並保留所有退出 effects。
- `native-menu-C20.log`、`launch-drain-C20.log`、`open-files-C20-r2.log` 回歸既有出生身分／晚到視窗、排空與 observer 路徑。`sentinel-C20.log` 首輪文字檢查仍要求「背景執行」，但本批移除沒有視窗就推論背景的舊 branch；改驗「執行中；尚未確認視窗」，`sentinel-C20-r2.log` 通過。沒有恢復舊錯誤語意來滿足字串測試，也未將靜態檢查當 runtime 證據。

- 最後 `build-C20-r3.log` universal macOS11 建置成功，arm64／x86_64 由 lipo 核對。每次建置期間產品來源固定；r2 加入批量交付，r3 加入 store 核可後的視窗交棒，不能拿早輪產物當最後版本。隔離包 `/private/tmp/cyder-lifecycle-c20-build/Cyder.app` 配置 local.cyder.lifecycle-c20、CD2 support/runtime，ad-hoc／strict verify 通過；`build-C20-source-sha256.json` 保存 41 個來源／產物 hash 並核對三支包內 scripts。完整本輪 app／Wine 未啟動，未覆蓋正式安裝或發布。

C20 已讓本次正式 launch 的關聯事件及呈現走入 store，仍有需完成的 adapter 遷移：所有 durable queued／歷史 requests、未歸屬的受管理程序、重開後重新發現、server 換代與新 executor 的可靠重新綁定、窗口關閉／最小化及精確操作、重複 waiter、觀察 queue 的 I/O 與其餘 UX／V01–V14 全矩陣。尤其準備後發現新的 server generation 時目前採保守失效，尚不能稱所有正常重建環境的群組都能可靠接回。整體目標持續，不標完成。

## C21：新 executor 的世代校準及 monitor 阻塞隔離

- 新 `test-cyder-launch-generation.sh` 以正式 monitor／store 重現 C20 提交 7122184 的缺陷：先看到舊 server、它退出、開始新要求、再看到新 server；新要求取得舊 stamp，第一次發現新 server 就使它和自己的排空回呼失效。`launch-generation-C21-baseline-r2.log` 保存四個失敗斷言。首輪 baseline fixture 的 store closure 少一個參數，僅編譯失敗，`launch-generation-C21-baseline.log` 保留；修正 fixture 後才取得上述 runtime 基線，沒有把編譯失敗当成產品缺陷。
- beginExecution 現先登記不允許 spawn 的 admission，重設校準 token，等待登記後的新鮮 probe。確認仍是 live server 時使用已核對世代；若先前有 owner、現在已空，需兩次間隔至少 0.5 秒的 fresh empty 證據才退休舊世代、準備新世代，然後交付 execution token。新世代尚未有 owner，第一次發現它的 server 不再把自己的新 launch 作廢。舊 launch、舊 drain／waiter 仍失效，不把舊事件移植過來。新 namespace 沒有先前 owner 時，一次新鮮 empty 可準備首個 executor；這不宣稱環境已運行或已排空。
- admission 從 monitor 接收工作起有 5 秒準備期限，含 prefix 身分解析及 probe slot 等待；unknown／卡住不能授予 spawn。逾時／退出會撤回尚未交付資格的登記，晚到解析或 probe 不能再回一個成功 token。已交付且仍持有的 executor 不因這個 timer 被撤回，root／executor release 後的正式排空條件保持不變。drain callback 到真正 admission 時才綁當前世代。
- prefix identity resolution 改用獨立 OperationQueue，實體最多兩個、連同排隊工作最多 32 個名額。名額保留到實際工作返回，不能藉 caller timeout 不斷加新工作；過期且尚未開始的 admission 在 worker claim 時跳過讀取。一個 prefix 卡住時另一 worker 可前進，也不把 registry persistence 卡在相同讀取 queue 後方。probe 的兩個物理名額維持原限制。
- 自有 wineserver -w 的 Process.run 移出 monitor 狀態 queue；每 monitor 最多兩個實際 spawn 呼叫，其他環境仍可校準、取得 stamp 或退出。舊世代／quit 在尚未 claim 時禁止啟動；已進入呼叫但晚返回者，只對自己建立的 Process 清理。spawn 未返回前，狀態 queue 不查該 Process 的 isRunning；返回後才讀取並清理，termination 狀態也在 callback queue 先取得。沒有依 PID 或 prefix 停止 server／Wine client，也沒有把 helper 的返回當環境結束。
- `launch-generation-C21-r7.log` 通過：新 launch 取得 generation 2 後，首個新 server 不重設成 generation 3、保留自己的 drain；舊 launch 為 uncertain、晚到成功被拒絕。另驗受阻 probe／明確 unknown 的有界拒絕；一個身分讀取卡住時另一 prefix 成功；兩個物理讀取受阻時 35 個要求全數返回且沒有新的實際讀取，放行後過期排隊工作仍不讀取；兩個 waiter spawn 受阻時第三個環境、admission／stamp 與 quit 可前進、沒有第三個物理 spawn。
- 同 harness 另真正啟動本次自建 native helper，故意在 monitor stop 之後才讓 Process.run 返回，確認只對該 Process 送 SIGTERM、正常終止。另以正式雙樣本排空後建立替代 Entry，確認舊 Entry 的晚到 native helper 同樣收到自有 SIGTERM，舊回呼不能修改新世代；新 Entry 安裝時亦撤回舊 helper 的資格。helper executable／參數由測試 adapter 明確替換，沒有啟動 Wine。server owner、clock、empty／unknown、受阻 syscall 皆是明確故障注入；這驗證控制流程與原生 helper 清理，不是實際 server 重建／Windows／NGS 相容性證據。
- `environment-monitor-C21-r2.log`、`launch-drain-C21-r2.log` 通過既有恢復、卡住隔離、世代、prefix 置換、executor release 與雙樣本排空回歸。`lifecycle-binding-C21-r2.log` 通過正式 journal → monitor → store → observer → AppKit，bound callback proxy 30 筆 p95 0.029875 ms、max 0.043041 ms，保存在 `bound-menu-C21.csv`，不是端到端使用者延遲。該正常接線 fixture 的 probe 由 unknown 改為明確 empty，符合新的授權前置；unknown 拒絕情形另有上述獨立測試，沒有刪除未知狀態的覆蓋。
- 最後 `build-C21-r4.log` universal macOS11 成功，編譯期間產品來源固定；r2 含身分讀取 worker，r3／r4 再加入 spawn-return 及 retired Entry 的資格檢查，以 r4 為最後產物。`/private/tmp/cyder-lifecycle-c21-build/Cyder.app` 配置 local.cyder.lifecycle-c21、CD2 support/runtime，ad-hoc／strict verify 及 lipo 的 arm64／x86_64 核對通過。`build-C21-source-sha256.json` 保存 41 個來源／產物 hash，三支包內 scripts bytes 與 repo 相同。本輪完整 app／Wine 未啟動，未覆蓋正式安裝或發布。

C21 修復已重現的正常空環境接新 launch 路徑；校準後、實際 spawn 前若有另一個外部 server 更換，仍採世代失效而非猜測原 launch 的歸屬，沒有宣稱跨外部工具原子性。完整歷史／queued 接回、未歸屬程序發現、視窗狀態／精確操作、重複 waiter 及其餘 UX／I/O 與 V01–V14 全矩陣仍須完成，目標保持進行中。


## C22：精確 Accessibility 視窗操作與一次性回饋

- 新 `CyderWindowAccess` 以公開 AXUIElement 物件、完整原生程序出生身分及 environment stamp 保存目標。AX 視窗自己的 token 不與 CGWindowID／Windows HWND 混用，不以標題尋找視窗；每次動作前重新驗證該物件仍在原程序的視窗集合。背景只讀，未授權不自動提示；明確選用權限入口才要求一次，拒絕後保留基本功能與系統設定說明。
- 正式 status menu → reducer → window adapter 已接通。單視窗直接操作、多視窗有子項，同名附可辨序號；文字寬度限制 360 point 並保留同名序號，目標不依截短後文字。available 才啟用；未知／暫時失聯／權限撤銷停用，永不支援時回到資訊列。重新檢查不啟動 Wine。所有 app 的 Workspace activation 都轉入撤銷判定，不能只監聽 Wine app。
- 同目標 pending 合併，新目標取代舊意圖；程序退出、視窗關閉、環境換世代在 reducer 同一交易撤銷 pending 結果，晚到 shown 無法覆蓋。視窗快照先完整檢查 source／process／重複 ID，再更新 capability，不留半套修改。精確程序出生身分阻擋數值 PID 重用。
- 兩個 physical scan 與兩個 action worker 各自有界；邏輯逾時不釋放仍受阻的實際占位。0.5 秒進度、3 秒操作觀察；AX IPC 在背景逐物件設 0.5 秒訊息上限，期限過後不再發新動作。成功不通知，失敗保留到下次選單真正呈現／關閉；tracking callback 不重建或移除選單。退出只取消本 app 觀察，未停止外部程式。
- 核對 Apple [AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)、[kAXRaiseAction](https://developer.apple.com/documentation/applicationservices/kaxraiseaction)、[kAXMainAttribute](https://developer.apple.com/documentation/applicationservices/kaxmainattribute) 與本機公開 SDK 的 AXUIElementSetMessagingTimeout／AXIsProcessTrustedWithOptions 說明。cannotComplete 不保證動作沒發生；正式 adapter 因而只在原期限內查核前景、精確 focused window 及非最小化狀態，不自動重送 raise／activation。main 與鍵盤焦點不同，不能用 main 單獨宣稱 shown。以上秒數／寬度為工程選擇，非 Apple 門檻。
- **真實原生 AX，有限通過**：`ax-permission-C22.log` 無提示查核為 true。`test-cyder-window-native.sh` 建立獨立原生 helper app、兩個同名 NSWindow，其中一個最小化；正式 controller 的 NSMenuItem selector 使用真實 AX 枚舉及動作。`window-native-C22-r8.log` 兩個指定目標均 shown，quiesce 後 helper 仍在；最後只終止自建 helper。process birth 是實讀，environment／launch attachment 明確注入。這不是完整 Cyder GUI 的 computer use tracking，也不是 Wine／NGS／Space 相容性證據。
- 原生失敗完整保留：r1 fixture 的 pump 呼叫編譯錯誤；r2 父／子共用 bundle 身分且兩次 unconfirmed；r3 被模型新增 late-result guard 的 Swift exclusivity 編譯錯誤擋住。r4 記錄 result observation／initial focus 未確認；改為父工具與子 app 分開 bundle，前景轉換未知時只繼續讀取，r5 為 2/2。r6（同時建置）foreground request／enumeration 未確認，r7 為 1/2、main eligibility 未確認；不能只保留 r5 成功，也不能據此把原因全歸編譯負載。修正 cannotComplete 的僅觀察處理並將過度積極的 0.15 秒訊息上限改為 0.5 秒後，r8 為 2/2。仍可能局部 unconfirmed；沒有以重試搶焦點換取成功率。
- **替身正式路徑**：`test-cyder-window-actions.sh` 以真實 AppKit controller／menu selector／store 加注入 AX driver，涵蓋兩個同名及最小化目標、refresh identity、合併／取代、焦點變更、0.5/3 秒、晚到回覆、視窗同名替換、PID 重用、permission 拒絕／明確請求、不自動重複、quit 中受阻動作，以及兩個永久 pending scan 不增加 physical calls。初輪 fixture 的閉包漏寫 owner，僅編譯失敗；r2–r5 runtime 輪次分別加入 quit、最終來源回歸及長同名標題截短後仍可區別的斷言。
- `lifecycle-isolation-C22-r3.log` 通過新增快照原子性／重複 ID／舊 shown／跨世代／回饋 dismiss 與原有 scope 斷言；初輪 guard 的 Swift exclusivity 編譯錯誤保留於 `lifecycle-isolation-C22.log`，改先計算 verified 再賦值後通過。`lifecycle-C22.log`、`native-menu-C22.log`、`lifecycle-binding-C22.log`、`open-files-C22.log`、`status-item-C22.log` 通過相關回歸。bound fixture 窗口與 receipt 仍是注入資料，不能因 native child 真實而改標整段 Wine 實測。


- C22 最後 r5 callback-cycle proxy 保留 30 筆於 `window-menu-C22.csv`：p95 0.209 ms、max 0.535083 ms。r4 的 p95 0.035875 ms、max 0.124125 ms 原樣留在 log，沒有為較小數字改挑樣本。既有 status callback harness 為 p95 0.037 ms、max 0.043166 ms。這些僅量 callback cycle，不含真實點擊／畫面呈現／tracking，也不宣稱全 app 無主執行緒停頓。
- 最後 `build-C22-r3.log` universal macOS11 建置成功；第一次 build 不含後續 AX 修正，r2 尚未保留長同名標題的序號，均不作最後交付版本。37 個輸入檔在最終編譯前後 hash 相同；隔離包 `/private/tmp/cyder-lifecycle-c22-build/Cyder.app` 配置 local.cyder.lifecycle-c22、CD2 support/runtime，ad-hoc／strict verify 及 arm64／x86_64 核對通過。`build-C22-source-sha256.json` 保存 43 個來源／產物 hash，含本輪新增 AX source 及 build script；包內 common／launcher／MoltenVK script bytes 與來源相同。完整本輪 Cyder.app／Wine 未啟動；上述真實 AX 是獨立 native harness。未覆蓋正式安裝或發布。
- 已送入 OS 的呼叫不能原子撤回；取消會封鎖後續指令與晚到結果，不能承諾回收已在途的系統訊息。native harness 為可選桌面測試，`bash tests/test-cyder-window-native.sh` 會建立／操作自己的兩個視窗並清理 helper；一般故障回歸使用 `bash tests/test-cyder-window-actions.sh`，不操作其他 app 視窗。

本批只完成可用 AX 能力下的精確操作及降級；先前 Wine 不可綁定 computer use target 的限制仍在。完整歷史／queued 接回、未歸屬程序發現、重複 waiter、其餘 UX／I/O 與 V01–V14 最終矩陣仍需收斂，目標保持進行中。


## C23：歷史要求與仍存活原生 root 的正式恢復

- 確認 C22 的接線缺口：onRecoveryChanged 雖讀到 native receipt，但 status 的 attachNativeRoot 要求既有 Session；重開後 Session 為空，回執被忽略。新增正式 recovery record mapper／observer，app 的 journal callback 同時交付共用狀態與候選；正常啟動仍經原 attachNativeRoot 核對，不另建 dispatch consumer。
- journalRequest 以 request ID／digest／version 更新 LifecycleStore，queued 納入共用存續政策；較舊版本不回退狀態。已綁定 observer 的期限／結果保留，不因新 native receipt 又回 observing。executionAttached 可接受已發布、完全匹配的 dispatching 紀錄，仍拒絕歷史 uncertain；恢復不是重新派送。退出後晚到 dispatching 保存為 uncertain，不能誤列為可繼續的未派送工作。
- 候選必須有相符 request／launch／digest／executor epoch 的 native spawned receipt，且唯一對上目前 alive／healthy 的 wine-user 環境 UID/device/inode scope。背景以真正 boot UUID／PID／微秒出生時間及本 UID 核對原程序；歷史名稱只作顯示，不是存活或視窗能力證據。若候選資料對同一 birth 提出矛盾要求歸屬，不任選一筆。未校準、舊 boot、PID 重用、已 exited、無 receipt 的資料不建立活程序。
- store 以當前 stamp 原子建立 recovered launch／root，僅發 restoreObservation；沒有 spawn effect、不重設 30 秒 observer、不發恢復成功或視窗切換。原 request 保持 uncertain／completed／failed，launch 的歷史 observation 已收尾；接回後正常 process watcher 與 AX adapter 重新觀察，後代只沿現行驗證過的 Unix tree 認領。session 安裝與更新 receipt 之間的版本變化，交由原不可變 ticket／birth／scope 檢查處理，不能換 root。
- recovery reader 與 monitor／UI 分離，最多兩個 physical lookup；五秒邏輯期限不釋放仍受阻的實際占位。舊世代 read 返回不能套用新世代；新版需重新查核。初始 metadata retention 最多五秒，completion 遺失不永久維持已關閉 UI；startup idle 亦等待 AppKit launch 與 coordinator role 確認。quit 撤銷 late recovery，不終止遊戲。
- 新 `test-cyder-recovery.sh` 寫入正式 journal／environment registry，再關閉重開；receipt 的相關 metadata／server calibration／window probe 明確注入，原生 child 與實際出生身分是真實的。正式 mapper → monitor → store → status/session → menu 通過：重開 uncertain／awaitingUserResume 保持原類別，未校準前零活程序，校準及 native 檢查後接回，沒有 starting 或 activation；同 ID 拒絕再次 authorize，40 次相同版本不重建，退出觀察後 native child 仍活。
- `recovery-C23-r5.log` 為最後完整 harness，另涵蓋實際 native reads 拒絕 prior-boot／數值 PID reuse、矛盾候選不任選、單一受阻環境不阻擋另一環境、新世代需新 read、quit 拒絕替代 read、metadata 無 completion 的五秒釋放、兩個受阻 lookup 不增生及 late-result fence。30 筆 callback-cycle proxy 在 `recovery-menu-C23.csv`：p95 0.035209 ms、max 0.109416 ms；是 callback 代理量測，非點擊至呈現或真實 tracking。r1–r4 的逐步擴充結果保留，沒有挑较小數字替代最後樣本。
- `lifecycle-binding-C23-r2.log` 加上真正 queued／authorized journal record 經正式 mapper 先進入 store，再走正常 launch attachment，原有 monitor／observer／窗口歸屬斷言通過。`lifecycle-isolation-C23-r2.log` 驗 journal 版本、不重啟歷史 observer、未校準拒絕、late receipt 不回退 outcome、已派送的 post-quit 紀錄不能 resume。`window-actions-C23.log`、`open-files-C23.log`、`status-item-C23-r2.log` 回歸通過。status-item 首輪仍要求 app 直接呼叫 attachNativeRoot，已改驗 app → receiveHistory → attachNativeRoot 接線；保留正式 binding／recovery runtime 證據，沒有把字串測試當恢復實測。
- 最後 `build-C23-r2.log` universal macOS11 建置成功；staged review 發現 pending recovery 應先比對 stamp 再移除，避免舊 effect 刪到新等待項，修正後重跑 recovery 並重建。先前 build／hash 保留，39 個最終輸入 hash 在編譯前後相同。`/private/tmp/cyder-lifecycle-c23-build/Cyder.app` 配置 local.cyder.lifecycle-c23、CD2 support/runtime，ad-hoc／strict verify 及 arm64／x86_64 核對通過。`build-C23-source-sha256.json` 保留 45 個來源／產物 hash，三支包內 Bash scripts bytes 與 repo 相同。本輪完整 Cyder.app／Wine GUI 未啟動，沒有新的 Wine／NGS 相容性宣稱；原生 recovery harness 的 process／AppKit 是真實、server／receipt metadata 則為標示的替代證據。

C23 接通有完整 native root 證據的重新觀察及 queued/history 共用政策；原 root 已退出、後繼失去 Unix ancestry、缺少環境登錄的可信 bottle 補查與未歸屬程序呈現仍待完成。重複 waiter、其餘 UX／I/O、完整 V01–V14 最終驗收及可重現交付亦未完成，目標保持進行中。


## C24：未歸屬程序的有界發現與獨立呈現

- 靜態盤點確認既有 programRows 只列 launch，而 activation／Unix tree 不能發現已 reparent 的無視窗程序。新增正式 CyderProcessInventory／CyderIndependentProcesses，經 status controller → LifecycleStore → 共用 menu renderer 接線。環境仍為管理範圍，不從 prefix 推定遊戲歸屬；發現不建立 request／launch、不啟動 Wine、不自動要求 AX 權限或切換視窗。
- 同 UID 的 sysctl KERN_PROC_UID 盤點上限 4096，另以原生完整 boot／PID／微秒出生身分查核。先核對目前管理環境之 engine 相對位置的精確 loader 路徑，再讀該程序的 WINEPREFIX，並重新核對 prefix UID/device/inode、環境路徑、image 與 birth。只接受絕對 WINEPREFIX；不把 CX_BOTTLE 名稱當路徑，不接管其他 prefix 或其他 engine。引擎位置 allowlist 不等於任意名稱含 wine 的檔案。以 monitor 已校準的 canonical server 路徑作詞法比對，不為每個 PID 解析所有環境的 symlink，避免無關的慢掛載點耗盡兩個 worker。
- KERN_PROCARGS2 reader 上限 2 MiB／4096 個參數及環境項目，處理空參數、截斷、重複 WINEPREFIX 及無效資料；只保留 prefix 和第一個 .exe 的短 basename，沒有保存或輸出完整 argv／environment。核對 Apple [sysctl(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html) 的 KERN_PROC_UID 與長度／失敗語意，以及本機 SDK 結構。盤點失敗、超限或漏列均不能推定程序退出。
- 一個實體 inventory worker、兩個實體 classification worker，各自不阻塞 UI/state queue；排隊上限 4096，保留尚未讀到的 PID 順序，不每輪重置而餓死尾端。每三秒刷新，五秒邏輯逾時保留仍受阻的實體占位；一個 PID 卡住時另一環境可前進。已知獨立 birth 即使沒列在盤點中也會重新讀取。DispatchSource 的 exit／exec 只提示再次驗身分，不以通知中的數值 PID 直接刪除程序。
- 新 independentProcess reducer 事件不能覆蓋已知 launch／ownership。明確不存在或已換 birth 才標 exited；失聯／scope 證據不足保留 unconfirmed，移除視窗能力與待完成操作。世代不符、已退役 birth、quit 後的晚到結果被拒絕；alive 還需目前環境 alive／healthy。環境降級會撤掉獨立程序的可操作狀態，並拒絕較早讀取的 late alive。
- 有完整回執的恢復可把先被盤點發現的 root 接回原 launch，解決兩個 observer 回覆順序競態；後來的獨立 alive／unknown／exit 不能再降級已證實的遊戲歸屬。沒有回執或可驗 ancestry 時仍獨立顯示。選單加入「其他執行中的 Windows 程序」，同名列以 PID 區分；已知 AX 視窗沿用同一精確 action renderer，沒有窗口時只是停用資訊列，未知不顯示 starting。
- **真實原生程序、注入管理環境**：新 test-cyder-independent-processes.sh 編譯自建 C helper 放在測試 engine 位置，fork 後原 parent 退出、child 無視窗且 reparent。系統 PID 枚舉、image、argv/prefix、stat 與 birth 均實讀；正式 controller/store/AppKit menu 確認獨立列，quiesce 保留 child，另一 controller 無 journal 也可重新發現。最後只在核對完整 birth 後 SIGTERM 自建 child，程序退出但共享環境保持 alive。此測試的 engine 名稱／環境校準為 fixture；它不是 Wine、Windows 或 NGS 相容性證據。
- **故障注入正式路徑**：一個讀取卡住、另一 bottle 可列出；盤點漏列不刪除、讀取失聯降級、同 PID 新 birth 分開；舊世代返回不得附加，新世代需新實體讀取；環境校準失聯與 late alive；兩個讀取超過五秒不增加 physical calls；quit 拒絕返回／排隊讀取。另驗已知歸屬不可被獨立事件降級、有回執可以認領先發現的 root，以及獨立 window 不製造 launch success、失聯後 late shown 被拒絕。
- 最後 `independent-C24-r7.log` 全部通過且要求 harness 完成檔。32 個同名獨立列可區分，兩個讀取仍受阻時 30 筆 callback-cycle proxy 為 p95 **0.302 ms**、max **0.311625 ms**，原始資料 `independent-menu-C24.csv`。先前 r2–r4 空獨立列及 r5 的 32 列量測（p95 0.764292 ms、max 0.827708 ms）均留存；r7 是最終來源回歸，不挑選較小樣本。這仍是 menu delegate callback 代理值，不是真實點擊至呈現／tracking，也不是全 app 主執行緒無停頓的證明。
- 回歸 `recovery-C24.log`、`lifecycle-binding-C24.log`、`lifecycle-isolation-C24.log`、`window-actions-C24-r3.log`、`status-item-C24-r2.log`、`open-files-C24.log` 通過。保留失敗：window-actions 首輪為 Swift 無法匯入 PROC_PIDPATHINFO_MAXSIZE macro，改用 SDK 對應的 4×MAXPATHLEN；受限環境的 independent 首輪無法取得自建 birth、window-actions r2 無有效輸出、status-item 首輪未產生必要 CSV，均不算通過。改由原生桌面權限執行取得上述完整結果。失敗 harness 86936（/private/tmp/cy-independent.iCjZvR/test，16:45:59）卡在 UE；首次清理因 ps 路徑截短而拒絕發訊號，之後以未截斷路徑／時間核對，只發一次 SIGKILL，未碰 Wine 或其他測試程序。r6 收緊 loader 比對後因 fixture 直接注入 /private/tmp、正式 image 卻為 /tmp 而失敗；限定自建 helper 的診斷保存在 independent-C24-r6-diagnostic.log。改由正式 EnvironmentProbe.identify 產生 canonical identity，加入可執行的假 server 檔而不執行它，r7 通過；沒有放寬 path equality。r6 的 UE harness 91582（16:55:50，/private/tmp/cy-independent.TkvUSW/test）亦核對後只發一次 SIGKILL；86936 仍是 UE，未重送。
- 最後 `build-C24-r3.log` universal macOS11 編譯及簽名檢查通過，iconutil 的既有 ICNS fallback 正常；40 個編譯輸入前後 SHA256 一致；前兩次 build log 與輸入 hash 留存但不作最終交付，最後採完全詞法的 engine allowlist。隔離包 `/private/tmp/cyder-lifecycle-c24-build/Cyder.app` 配置 local.cyder.lifecycle-c24、CD2 support/runtime，ad-hoc／strict verify 與 arm64／x86_64 核對通過；`build-C24-source-sha256.json` 有 46 項，三支包內 Bash scripts bytes 與 repo 相同。本輪完整 Cyder.app／Wine GUI 未啟動，未覆蓋正式安裝或發布。

本批對已登錄、校準可用環境補上孤兒／無視窗程序發現；並未承諾所有 Wine build 的 loader 位置與環境記憶體均可讀。缺少 WINEPREFIX、未知 loader 位置、權限不足、盤點超限時不猜 scope，環境入口照原校準政策保留。未登錄 bottle 的可信補查、重複 waiter 分工、其餘 UX／主執行緒 I/O 及完整 V01–V14 最終交付仍待收斂，目標保持進行中。


## C25：可信 bottle 目錄補查與明確重新檢查入口

- 新 CyderBottleRecovery 補足 §18 缺少環境登錄時的候選來源：只掃目前設定的 Cyder support/bottles 直接子目錄，不全機搜尋。support、bottles 與候選以 O_NOFOLLOW／相對 directory fd 開啟，要求本 UID 且不可由 group/other 寫入；候選需有非 symlink 的 user.reg、system.reg、drive_c 結構。不讀遊戲 argv、不讀 profile 的外部 EXE 路徑、不啟動 Wine 來確認。
- 目錄盤點／排隊最多 4096 筆，不以 monitor 的 32 環境限制提前截斷已安裝目錄；否則 32 個閒置 bottle 可能遮住後續活躍候選。盤點保存 device/inode，讀取前重查目錄種類、UID、權限，再交正式 EnvironmentProbe.identify／inspect；只有 exact prefix identity 和可信 engine 的 alive server 證據才呼叫 monitor.recoverVerified。empty／unknown 的普通安裝目錄不建立環境列、不保留 spinner、不建立 launch 或 replay。
- 一個實體目錄讀取、最多兩個實體候選讀取。各讀取有五秒邏輯期限，整輪 completion 也有五秒界線；逾時不釋放仍受阻的實際占位，反覆點檢查不增生工作。停止會清除排隊候選並拒絕晚到結果；退出主路徑同時 quiesce status、bottle recovery 及 monitor。補查完成後透過 monitor 非同步 barrier 排序 restoring=false，避免先清掉保留狀態再提交已驗環境。
- monitor 接回新證據時不覆蓋當前活動 entry。已退休 entry 只有不同 server birth、而且候選讀取開始時間晚於退休時間才可進新世代；排空前的 late alive 不能讓環境復活。未知或已存在的活動 entry 仍由原 monitor 校準，沒有第二個 dispatch consumer。
- 一併修正 restore 與正常啟動的交錯：晚到的磁碟紀錄不能重新安裝／覆蓋當前已建立的 entry。讀 registry 期間暫緩環境快照寫入，讀完且有效才保存合併結果；損壞 registry 原檔保留，仍可用目前可信目錄補查已活環境。journal 的 accepted／dispatch 權威未改動。
- 選單入口改為「重新檢查執行狀態」，呼叫正式環境重校準、bottle 補查、歷史 root、獨立程序及 AX 刷新；顯示 Cyder UI 時即使沒有已登錄環境也可操作。一般開選單仍只讀快照，不觸發這些讀取或權限提示。secondary／quit 中的 app 不啟動環境補查。
- `bottle-recovery-C25-r8.log` 通過正式 filesystem → recovery adapter → monitor → LifecycleStore。目錄、symlink、權限、inode 替換與保存檔案皆是真實暫存檔；活 server 與 clock 明確注入。驗證 42 個合格候選不被 32 個已安裝目錄上限截斷、僅一個 alive 環境建立、empty 原生 namespace 不產生環境、損壞 registry bytes 不變、late history 不覆蓋當前 generation、一個候選卡住另一個完成、退休後新 server 接回、退休前讀取被拒絕、同路徑替換拒絕、兩個物理卡住工作不增加、quit 撤銷晚到結果。harness 必須產生完成檔才通過。
- `window-actions-C25.log` 以正式 NSMenuItem selector 驗證重查 callback，以及無環境但 UI 可見時的重查入口；原精確窗口、同名／最小化、取消、失聯、permission／quit 回歸通過。30 次 callback-cycle proxy p95 0.264792 ms、max 0.519208 ms，原始樣本另存 `window-menu-C25.csv`；不是端到端呈現或真實 tracking。`environment-monitor-C25.log`、`launch-generation-C25.log`、`recovery-C25.log`、`status-item-C25.log`、`open-files-C25.log` 相關回歸通過。
- 失敗與擴充輪次保留：bottle-recovery 首輪為 Swift 預設參數函式不能直接轉成單參數 closure 的編譯錯誤，改為明確 closure 後 r2 通過；r3–r8 逐步加入窗口重查、正常啟動與 restore 交錯、退休時間、新 owner fixture 及 42 候選。沒有刪除失敗樣本或將替身標為 Wine 實測。本輪沒有新的 Wine GUI／NGS／computer use 相容性結果。
- 核對 Apple [directory(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/directory.3.html) 的串流遍歷／關閉與 [open(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html) 的 O_NOFOLLOW 行為；fdopendir、openat、fstatat／O_DIRECTORY 另核對本機 SDK 公開宣告。4096、兩個 worker 與五秒是 Cyder 工程上限，非 Apple UX 門檻。

- 最後 `build-C25-r3.log` universal macOS11 建置成功，41 個輸入檔在編譯前後 SHA256 相同；前兩次建置 log／輸入 hash 保留，後續分別加入退休時間檢查與超過 32 候選的補查修正。`/private/tmp/cyder-lifecycle-c25-build/Cyder.app` 設定 local.cyder.lifecycle-c25、CD2 support/runtime，ad-hoc／strict verify 與 arm64／x86_64 核對通過；`build-C25-source-sha256.json` 保存 47 個來源／產物 hash，三支包內 Bash scripts 與 repo bytes 相同。本輪完整 Cyder.app／Wine GUI 未啟動，未覆蓋正式安裝或發布。

本批完成可信 support/bottles 的補查及手動刷新接線；自訂外部 prefix 仍依既有環境登錄或新明確啟動接回。目錄／metadata 持續不可讀時保留有限降級，不推定 Wine 結束。重複 waiter 與 runtime session 分工、長時間多環境容量、其餘 UX／主執行緒 I/O、最終 V01–V14 及整包交付仍須收斂，目標保持進行中。


## C26：已排空環境不占用活動監控容量

- 修正 manage／recoverVerified 的容量計算：32 個上限只計尚未 exited 的 entry。歷史 entry 保留世代與退休證據，但不占活動位置；重新啟用歷史 prefix 也必須取得位置，不能利用「字典已有此 key」繞過上限。當前活動 prefix 的重複 track 繼續共用 entry，不多占位置。manage 另拒絕已達 UInt64.max 的歷史世代，避免重新接納時整數溢位。
- 新 `bash tests/test-cyder-environment-capacity.sh` 驅動正式 monitor → store，以注入的 prefix identity／server birth／時鐘逐一建立並排空 33 個環境。驗證新 prefix 仍可接納、32 個活動環境時新／歷史 track 與 verified recovery 均不能增加活動數、既有活動 track 可共用、排空後 track 與 verified recovery 各可重新使用位置且世代遞增；真實暫存 registry 最終仍為 32 筆。這是容量與世代的替代證據，未執行 Wine。
- 最終 `environment-capacity-C26-r4.log` 通過且產生必要完成檔。首輪 precondition deadline 失敗，原日誌保留；診斷版 r2 定位於滿载後等待被重新接納環境變成 alive 的十秒斷言。32 環境共用兩個實體 probe，該斷言把後續校準排程與容量接納混為一談；改為檢查正式 store 的新世代及活動數，沒有放寬產品期限或宣稱立即完成校準。測試同步標記亦改為 monitor barrier 後單次 store UI marker，避免原雙重 toggle 的競態。r3 通過後，r4 加上 verified recovery 在釋放位置後成功的情境。首輪 harness 5222（17:29:49，/private/tmp/cy-capacity.3GdNRz/test）成為 UE；以完整路徑／出生時間核對後只發一次 SIGKILL，未對 Wine 發訊號，未重複清理。
- `environment-monitor-C26.log`、`bottle-recovery-C26.log`、`launch-generation-C26.log` 回歸全部通過，分別涵蓋排空證據、恢復／過期證據及世代 admission／晚到 helper。容量 harness 的後續校準延遲不是選單回應性量測，本批未產生新的 menu latency 數字。
- `build-C26.log` universal macOS11 建置成功；41 個來源輸入在編譯前後 hash 相同。隔離包 `/private/tmp/cyder-lifecycle-c26-build/Cyder.app` 使用 local.cyder.lifecycle-c26 與既有 CD2 support/runtime，ad-hoc／strict verify 和 arm64／x86_64 核對通過，三支包內 shell bytes 與 repo 相同；`build-C26-source-sha256.json` 保存 47 項。完整 app／Wine GUI 未啟動，沒有正式安裝覆蓋或發布。

本批修正正常 track 及可信補查的活動容量，不宣稱所有啟動交錯已收斂：restore 的磁碟紀錄與先建立的新 entry 合併仍需檢查總容量，不能直接截斷而遺失外部 prefix 的恢復資格。滿載時新 admission 的校準優先序、重複 waiter／runtime session 分工、其餘 UX／I/O 及 V01–V14 最終交付繼續處理；目標保持進行中。


## C27：首次 registry 讀取與 admission 排序

- 根因不是單純合併後多一筆：manage 先寫環境紀錄、restore 後讀取的順序可能直接覆蓋未讀的外部 prefix。monitor 現在讓 restore、track／beginExecution、recoverVerified 共用同一次背景 registry 讀取；任何新 entry／快照保存都在這個讀取之後。有效的最多 32 筆歷史紀錄先保留監控位置，再處理新入口，無須截斷歷史、擴張 registry schema 或放寬容量。
- 讀取等待佇列上限 32，單一實體 reader；每個等待者五秒內完成或失敗，逾時移除要求但不釋放仍卡住的讀取。beginExecution 的原五秒期限包含 registry、identity 與校準，晚到讀取不能重新認領已逾時 admission。stop 立即清除等待工作並完成 caller；晚到 reader 不 emit、不保存、不啟動 identity。重複 restore 共用結果，不用檔案中的較大 generation 覆蓋現行程序。
- 原安全讀檔邏輯提取為 readRegistryFile，仍限制私有 regular file／UID／64 KiB／O_NOFOLLOW，ENOENT 才視為沒有歷史；取消額外 fileExists 查詢。readRegistry closure 是故障注入接點，正式預設仍走該讀檔路徑。損壞紀錄保留原 bytes，明確新入口及可信 bottle 補查仍可運作；没有新 Wine 動作。
- 另修正滿載時 admission 校準排在一般輪詢後方的問題：新的待執行 entry 優先嘗試 probe；實體工作槽返回時優先服務等待中的 executor，仍最多兩個實體 probe。未知／尚待雙 empty 的要求依實際 monotonic 時間限制自動重試，每次至少相隔半秒，避免以高速重試換取五秒內成功。一般環境 round-robin 保留；期限內仍拿不到可靠證據就不准執行。
- 新 `bash tests/test-cyder-environment-restore-admission.sh` 的正式 monitor/store harness 通過：track 先到、明確 restore 後到仍完整保留 32 筆外部 prefix；可信 recovery 不能超額；未讀完成前零 identity／零寫入；10 次 restore 共用一次 reader；40 個 track 加 executor 的排隊上限、五秒失敗及單次完成；晚到歷史不復活逾時要求；讀取中退出立即返回且拒絕晚到權威。磁碟紀錄／讀取與 callback 是真實，server／prefix 身分與 stall 是注入，不是 Wine 相容性證據。
- 同 harness 再讓兩個正式 probe 工作槽停住，向排序最後的 prefix 要求 beginExecution；釋放一個槽後能在原期限內得到 executor，另一個仍卡住。接著注入 unknown，驗證重試次數有界、沒有 executor，quit 可結束 pending admission。最終 `environment-restore-admission-C27-r4.log` 四組 PASS 且有完成檔。首輪只因 test check autoclosure 包含 throwing Data read 而編譯失敗，改為普通 Bool 後 r2 通過；r3 增加優先序／重試測試；review 再讓一般輪詢略過待 admission 的 entry，避免繞過優先排程器的半秒下限，r4 與相關回歸通過，所有輸出保留。
- `environment-monitor-C27-r3.log`、`launch-generation-C27-r3.log`、`bottle-recovery-C27-r2.log`、`environment-capacity-C27.log` 通過。bottle recovery 中原「late restore 不覆蓋」案例改為「重複 restore 不重新讀檔」的準確描述，保留相同世代不變斷言；新的受阻 reader 測試負責真正的首次讀取交錯。
- 原生桌面 `recovery-C27.log` 通過正式 journal／registry／native birth／AppKit 接回回歸。自建 child、native birth 與 AppKit 真實，server 證據仍注入；30 個 callback-cycle proxy 原始樣本保存 `recovery-menu-C27.csv`，p95 0.036292 ms、max 0.111167 ms。這是 callback 代理量測，非真實 tracking／點擊至呈現，也不代表整個 app 沒有主執行緒停頓。
- 最終 `build-C27-r2.log` universal macOS11 建置通過，41 個輸入編譯前後 hash 相同；第一輪 log／hash 留存，後續為輪詢排除 admission 的修正重新建置，舊 app 產物已由新建置取代；隔離包 `/private/tmp/cyder-lifecycle-c27-build/Cyder.app` 設 local.cyder.lifecycle-c27、CD2 support/runtime，ad-hoc／strict verify 和雙架構核對通過。`build-C27-source-sha256.json` 有 47 項，包內三支 shell bytes 與 repo 相同。本輪未啟動完整 Cyder.app／Wine GUI，未發布或覆蓋正式安裝。

C26 留下的首次恢復合併容量及 admission 排序問題已有正式路徑證據。下一步仍是 shell detached supervisor 的 per-launch -w 與原生 monitor 的分工：不能只刪等待而提早釋放 session guard，亦不能用 socket 存在當成精確存活證據。其餘 UX／I/O 與 V01–V14 最終驗收、可重現整包交付持續進行，目標未完成。


## C28：原生環境等待交給 monitor，保留 session 設定互斥

- 原生 app 的正式 launch 環境新增內部 CYDER_ENVIRONMENT_MONITOR=1，優先於 per-game 值。detached supervisor 同時確認 native execution ticket 後，root 結束只發布精確 result／background lifecycle，不再每個 launch 執行 wineserver -w 或自行發布環境 stopped。環境生命週期與每世代的一個 waiter 由既有 EnvironmentMonitor 負責；明確停止的 -k／-w 及未採用原生 monitor 的 CLI fallback 沒有混入這個改動。
- session guard 仍保護共同 wineserver 的同步／電源設定。native session 在取得時標示 observer=native；root reaped 後以原子替換保留 background、把 PID 清為 0，避免數值 PID 重用冒充仍活的 root。park 前先撤掉本 supervisor 的 EXIT release，寫入失敗也不刪掉保護檔。若只剩較早的 running 狀態，observer=native 仍要求環境證據才能清除，不因 dead root PID 直接放行。
- 提交前另修正 native park 與下一次 acquire 的競態：兩者共用 session 鎖，取得鎖後重新檢查 session；已被新接納清掉的舊 guard 不可重建。native 分支直接在鎖內完成 background／PID 0／退出時間更新，避免先走未上鎖的 legacy mark_background。Bash 3 背景 subshell 的 $$ 仍是舊 parent，鎖的 pid 改由前景 /bin/sh child 的 PPID 寫入實際持鎖 shell；舊 parent 退出不會讓別人誤拆 native park 的鎖。新測試在鎖被占用時證明 park 沒有完成，再移除舊 session、建立新 reservation、釋放鎖，確認晚到 park 不重建／覆寫；r5 通過後重建並重跑包內整合。
- 新唯讀 `CyderEnvironmentCommand` 經正式 CyderSwift --environment-state 入口執行，不建立 NSApplication／UI、不啟動 Wine、不發訊號。使用原 EnvironmentProbe 的 prefix 身分、server lock／socket／完整 birth 核對；兩次 empty 間隔至少半秒且重查 prefix identity，才回固定 empty 協定及 status 10。alive 回 status 0，unknown／替換／restart 保留未知；Bash 同時比對協定文字及 status，缺 helper／錯誤／不符格式不能解除 session。
- helper／server 路徑由 runLauncher 以 app bundle 與目前 engine 內部覆寫，不能由 per-game environment 替代。只把新校準用在 session 接納，沒有改動一般 bootstrap 的 engine 尚未安装判斷。session lock 內同一 prefix 只讀一次環境，12 個舊 session 不會變成 12 個 helper／半秒等待；明確排空後才清掉該 prefix 的舊保護，別的 prefix 不受影響。PID 0 另改為非有效 PID，避免 kill -0 0 查到 shell process group 而永久占用。
- `native-session-C28-r5.log` 通過：正式命令的 alive、unknown、兩次 empty、樣本間新 server、prefix inode 替換及錯誤參數；真實暫存 prefix／實際空 namespace 與可執行檔 stand-in 清除舊 session；注入 alive／unknown／錯誤文字／status 不符均拒絕不相容設定；失敗 park 留下 running 狀態仍受保護；12 個背景 session 共用一次校準且另一 prefix 保留。這些不是 Wine 執行結果。
- `native-handoff-C28-bundle-r2.log` 使用本次 **包內 CyderSwift 與 ogom-scripts**，透過真正 native owner、bridge、Bash supervisor 及自建 x86_64 Mach-O 程序驗證：同 prefix 兩個 root，PID／birth／退出 53 正確；兩個 per-launch wineserver 呼叫計數皆為零；兩份 session 保留、observer=native 且 pid=0；真正空 namespace 的正式命令允許後續不同 sync 設定並清掉舊 guard。原有 dispatch 先後 crash、晚到 bridge、獨立 prefix、global runtime barrier、taskmgr、十次 fast exit 全部通過。輸出及 fixture 證據保存 native-handoff-C28-bundle-r2-artifacts；前兩輪 source harness 輸出亦保留。這是原生 x86 程序與正式路徑整合，沒有把它稱為 Wine／NGS 相容性實測。
- **真實隔離環境的唯讀校準**：包內新命令讀取 /private/tmp/cy-cd2/support/bottles/shared 及既有 runtime wineserver，回 `cyder-environment-v1 alive`、status 0（5.791 ms，單次命令時間，不是 UI latency）。當前 version 檔為 CX26.3.0-W11-Cyder012，server SHA256 和回覆保存在 environment-command-C28-real-prefix.log。沒有 Wine spawn、停止訊號或 prefix 寫入；未測該 Wine 視窗與 NGS。
- `session-C28-r3.log`、`launcher-C28-r3.log`、`open-files-C28.log`、`environment-monitor-C28.log` 回歸通過。launcher 首輪已有 PASS，但假 wineserver 在非停止案例未設定 CYDER_TEST_STOP_LOG，對空檔名重導產生兩行 stderr；查明為 fixture 後把未指定的日誌導向 /dev/null，停止記錄／失敗斷言仍保留，r2 無該錯誤。沒有刪除斷言、跳過原 CLI waiter 行為或將 mock 當 Wine。
- 已依 repo 規則重讀 engine AGENTS／incremental guide，沒有改 engine repo、make 或 engine pack。核對 Apple [Thread.sleep(forTimeInterval:)](https://developer.apple.com/documentation/foundation/thread/sleep%28fortimeinterval%3A%29?language=objc)：sleep 會阻塞目前 thread 且不處理該 thread 的 run loop；本處只在独立命令的 utility worker 進行，未加在 app UI thread。半秒雙樣本是 Cyder 工程政策，不是 Apple UX 門檻。
- 最終 `build-C28-r2.log` universal macOS11 建置成功，42 個來源輸入在編譯前後 hash 相同；第一輪 build／hash 與包內測試輸出保留，新建置取代舊 app 產物；隔離包 `/private/tmp/cyder-lifecycle-c28-build/Cyder.app` 設 local.cyder.lifecycle-c28、CD2 support/runtime，ad-hoc／strict verify 和 arm64／x86_64 核對通過。`build-C28-source-sha256.json` 保存 48 項，三支包內 shell bytes 與 repo 完全相同。正式完整 app GUI 未啟動，只有其無 UI 命令入口及 executor 入口被上述測試執行；未覆蓋正式安裝或發布。

本批接通原生 monitor 與 session guard 的責任分工。舊 CLI 的相容觀察仍保守保留，未知校準不允許任意更換同步設定；實機完整 Wine／多視窗／NGS 體驗沒有因本批替代測試而升級為通過。session 鎖首次 mkdir 到 pid 發布之間仍沿用歷史 stale-owner 協定，尚需用初始化停頓注入檢查；其餘 UX／I/O 盤點、V01–V14 最終整合驗收及可重現交付仍繼續，目標保持進行中。


## C29：以核心檔案鎖取代 session PID 目錄鎖

- 真正重現 C28 留下的初始化空窗：第一個正式 cyder_session_lock 在 mkdir .lock 後、寫 PID 前被注入停頓；第二個 caller 把缺 PID 當 stale 而刪除／重建，第一個恢復後也成功取得鎖。session-init-baseline-C29.log 記錄兩個仍活的 shell 同時 claimed；基線為 54bc326，腳本 bytes／SHA256 另存 cyder-common-before-C29.sh，reproduce-session-init-C29.py 固定讀此基線，不把修正後來源當舊版重現。
- 改用不刪除的 .session.lock regular file 與 Darwin flock；Bash 在短暫 critical section 持有 FD 9，系統 Perl helper 以繼承的 stdin 對同一 open file description 取得非阻塞 exclusive lock。helper 返回後 Bash 仍持有，unlock 只關閉自己的 descriptor，最後一個引用關閉或程序退出才釋放；不寫 PID、不猜失效、不 unlink lock inode。檔案持續存在不是仍有人持鎖的證據。
- 非阻塞重試最多 250 次、間隔 20 ms，CYDER_SESSION_LOCK_ATTEMPTS 只允許 1–250，非法／過大數字直接拒絕；底層 metadata 呼叫仍可能受 OS I/O 影響，不把次數上限宣稱為硬即時期限。鎖要求 regular file、本 UID、不可由 group/other 寫入，取得前後核對 path／descriptor device+inode；既有 symlink、FIFO 和已占用的 caller FD 9 均拒絕。原 caller descriptor 不被覆寫。
- acquire／native park 的所有正常與失敗收尾改呼叫 unlock。新 native-session 測試中，fork 的競爭者先關閉自己繼承的引用，再嘗試獨立鎖；parent 的 lock 繼續有效，關閉 child 引用不會把 parent 解鎖。遊戲只在 session critical section 結束後執行，x86 fixture 新增實際 fcntl(9) 檢查，確認鎖 descriptor 沒有進入被啟動程序。
- `session-lock-C29-r2.log` 通過正式 cyder_session_lock／unlock：open 後初始化停頓不能搶走後來的 holder；取得前／取得後對精確 unreaped Popen child 注入 SIGKILL，下一個 caller 可取得；parent 退出、child 仍繼承 descriptor 時繼續互斥，最後 close 才放行；持續使用同一 inode；FD 保留、symlink／FIFO 拒絕；四個真實 shell caller 的 40 次 counter 更新沒有遺失。沒有殺 Wine 或搜尋／操作任意 PID。harness 要求完成檔；失敗時保留 fixture，cleanup 只處理本次 Popen children。
- **舊鎖相容限制**：舊版 .lock 目錄（包含缺 PID、損壞、數字看似已死）不再自動刪除。舊協定無法證明是否仍有停頓中的 initializer 或晚到舊 writer；回報該 prefix 的上一個操作未確認結束並保留資料，需先確認舊操作已結束後明確處理。這不是新鎖的正常收尾途徑：新格式崩潰的自動釋放已由上述實測證明。舊測試原本要求「缺／壞 PID 即刪除」正是重現缺陷的政策，因此改驗拒絕且 bytes／目錄保留；另加真正 kernel ownership 的 crash／contention 測試，沒有以放寬斷言冒充通過。
- `native-session-C29-r2.log`、`session-C29-r2.log`、`launcher-C29.log` 回歸通過。`native-handoff-C29-bundle.log` 使用本次包內 Swift helper／shell，正式 owner、bridge、同 prefix 兩個 root、session 停放／校準、runtime barrier、dispatch 前後 crash、late bridge、taskmgr 及十次 fast exit 均通過；所有自建 x86 child 也通過 FD 9 未繼承檢查。這是原生程序／核心鎖與正式路徑驗證，不是 Windows／Wine／NGS 相容性測試。
- Apple [flock(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html) 與 [close(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/close.2.html) 說明 duplicated／fork descriptor 共用同一鎖及 last-close 釋放語意；本機亦先以獨立 Perl caller 實測 helper exit 後鎖保留、最後 close 後可重新取得。這裡使用 flock，不把 fcntl 的 per-process lock 語意混用。
- `build-C29.log` universal macOS11 建置成功；42 個輸入檔編譯前後 hash 一致。`/private/tmp/cyder-lifecycle-c29-build/Cyder.app` 設 local.cyder.lifecycle-c29、CD2 support/runtime，ad-hoc／strict verify 和雙架構核對通過；三支包內 shell bytes 與 repo 相同，build-C29-source-sha256.json 保存 48 項。未啟動完整 GUI 或操作 Wine；只執行包內無 UI executor 入口與自建程序整合，未發布／覆蓋正式安裝。

已修正並驗證新 session 鎖的初始化／崩潰互斥；舊版無法驗身分的鎖保留為明確局部錯誤，不把它當成 Wine 已結束。本批沒有新的 UI 延遲數字。接下來繼續目前 app 的 UX／主執行緒 I/O、V01–V14 最終整合驗收與可重現交付；目標尚未完成。


## C30：移出 UI 入口的引擎資源同步讀取

- 盤點確認 CyderLaunchContext 原同步 initializer 會讀 engine-archive.txt／engine-version.txt 並查詢 archive 是否存在；建立／移除 profile、重建、遊戲庫啟動、準備環境、Winetricks、prefix action／stop、URI launch 多個入口在 Task.detached 之前建構 context。它們不是僅組合字串，慢磁碟可能直接卡住 UI。
- 將 context 與原 resolver 移至 cyder_launch_context.swift，加入正式 universal build。initializer 改為 async，資源解析明確在 detached task 執行並 await 結果，所有 caller 由編譯器要求 await；UI 入口先顯示既有狀態，再於既有 worker 載入。URI session begin/end 與設定掃描只需要 launcher 字串，改用不讀檔的 launcherPath。archive manifest 優先、version slug fallback、engine-payload fallback 及環境變數不變。
- 新 test-cyder-launch-context.sh 驅動正式 initializer：從 main actor 呼叫、注入卡住的 resolver，斷言 resolver 不在 main；等待期間主 RunLoop 完成 30 次 timer callback、context 尚未完成，釋放後只得到原預期資料。另以真正臨時目錄驗證缺檔、slug archive、manifest 優先及 manifest 指向缺檔的 fallback。launch-context-C30-r2.log 通過且有強制完成檔；r1 通過但有 Sendable function conversion 警告，改為明確 closure 後 r2 無警告。這是 L2 正式 API／故障注入，不是實際 NSMenu tracking 或端到端延遲量測；30 次 callback 也沒有被換名為 30 次選單量測。
- open-files-C30.log 通過既有正式 observer／receipt 行為測試。windows-documents-C30.log 失敗在文件錯誤訊息未出現；隔離重現的 windows-documents-C30-isolated-diagnosis.log 證實目前 Rosetta 檢查失敗，launcher 在文件驗證前進入 softwareupdate 的授權提示，未提供同意、未完成安裝即退出。沒有接受授權或嘗試修復系統安裝。該測試原本部分命令未指定隔離 support，現全部設為測試臨時 support/runtime，並明確以 uname 替身略過與此文件路由測試無關的 Rosetta 安裝。所有原文件錯誤／缺環境斷言保留，windows-documents-C30-r3.log 通過；這不證明目前主機能執行 x86 Wine。r2 失敗輸出亦保留。
- build-C30.log 首輪在 CompatDB inspect 選到 .brew-x86/bin/python3 時回報 Bad CPU type，尚未進入 Swift 編譯；本次不修改 engine／Homebrew。以建置程序局部的 exported Bash function 將 python3 指向 /usr/bin/python3 後，build-C30-r2.log universal macOS11 編譯成功，沒有 Swift warning/error；staged diff 發現新增檔尾多一空行，移除後再以 build-C30-r3.log 完整重建，最終 manifest 對應 r3。iconutil 的既有 portable fallback 正常使用。
- 43 個來源輸入編譯前後 hash 相同；隔離包 /private/tmp/cyder-lifecycle-c30-build/Cyder.app 設 local.cyder.lifecycle-c30、CD2 support/runtime，ad-hoc 簽名／strict verify、arm64+x86_64 核對通過；三支包內 shell 與 repo bytes 一致，build-C30-source-sha256.json 保存 49 項。未啟動本包完整 GUI、未操作 Wine、未發布或覆蓋正式安裝；不能以 universal 編譯成功宣稱當前 x86 runtime 可用。
- Apple [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) 建議同步工作若不能改寫，可用 detached task 避免繼承 MainActor；本次採此明確邊界。測試的 timer 間隔與樣本數是工程 fixture，非 Apple 門檻。

本批可重現建置（在 repo 執行 Bash）：

```bash
python3() { /usr/bin/python3 "$@"; }
export -f python3
SIGN_IDENTITY=- CYDER_REQUIRE_NATIVE_SWIFT=1 CYDER_SWIFT_OPTIMIZATION=-Onone \
  bash scripts/create-cyder-app.sh /private/tmp/cyder-lifecycle-c30-build
bash tests/test-cyder-launch-context.sh
bash tests/test-cyder-open-files-lifecycle.sh
bash tests/test-cyder-windows-documents.sh
```

以上 build command 產生本次程式，但若重新建置，要再設定前述隔離 bundle identity／wrapper 並重新 ad-hoc 簽名，才可作 GUI 測試；不要直接把一般 wrapper 用於正式資料。已完成隔離設定的本批產物與 manifest 保留在上述路徑。新發現的使用者 docs/releases/next.md 未修改／納入。本批修復 context 的 UI I/O；setup progress 取消後晚到、其餘 UI I/O、最終 V01–V14 整合與完整交付仍待完成，目標保持進行中。


### C30 主機 Rosetta 唯讀複核（2026-09-23）

C30 提交後以 require_escalated 在沙箱外執行系統 /usr/bin/arch -x86_64 /usr/bin/true，仍得到 Bad CPU type、status 1；pkgutil 查詢 com.apple.pkg.RosettaUpdateAuto 也無 receipt、status 1。工具輸出轉錄保存於 rosetta-C30-host-check.log。這支持「目前主機無法執行此 x86 系統測試」而非僅沙箱拒絕，未安裝／更新任何系統元件，沒有執行 Wine。先前 C28/C29 的 x86 實測仍是其當時紀錄，不能推論為今日 runtime 可用；本次 universal 編譯、arm64 API 故障注入及文件路由替身保持各自證據範圍。真實 x86 Wine 復測須先恢復可執行的 Rosetta 環境，其餘產品修正與替代驗證繼續，不因此停止目標。


## C31：準備進度的畫面世代與讀取上限

- C30 後續盤點確認原 runLauncher 只 cancel timer；正在執行的 Data(contentsOf:) 返回後仍直接呼叫 showSetup，該函式會建立 panel 或覆寫 library 狀態。Apple [Dispatch Sources — Canceling a Dispatch Source](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html) 明確指出取消是非同步，已處理中的 event 會繼續，故 cancel 本身不足以撤銷 UI 更新權限。此結論來自正式程式路徑與 API 契約；本批沒有宣稱在真實 GUI 重現了舊視窗重開。
- 新 CyderSetupProgress 為 main-thread authority：每次 showSetup 取得新的 presentation UUID；profile-create、rebuild、bootstrap 把該 UUID 傳進 runLauncher。開始讀取時另配 watch UUID，讀取返回主執行緒後同時核對 presentation／watch，才呼叫既有 renderer。延遲的 begin 不可認領較新的畫面，舊 end 不會取消新的 watch。hideSetup、較新的 showSetup、primary／secondary 的終止入口都撤銷舊權限。進度回報只更新已授權 renderer，不再次呼叫建立新世代的 showSetup。
- 檔案讀取仍在 utility worker；整個 adapter 同時最多一筆實際讀取，取消／替換不提早釋放讀取占位。新的 timer tick 在舊讀取卡住時直接返回，不累積 queue 工作；舊讀取真正返回後才允許下一筆。進度檔最多 64 KiB，缺檔、UTF-8 損壞、超量或空白不覆寫既有訊息；重複文字不重新呈現。讀取卡住不提供假的新進度，也不等待其返回才取消 UI。
- `bash tests/test-cyder-setup-progress.sh` 通過（setup-progress-C31.log）：正式 adapter／真正 Dispatch worker，第一筆讀取注入停頓；40 次替換仍只有一筆讀取，main RunLoop 完成 30 次 callback；釋放後舊結果丟棄、最新進度正常送達；晚到 begin/end、hide/quit 撤銷、重複資料、真正臨時檔的缺失／無效 UTF-8／過大／更新均有行為斷言，完成檔必須存在。這是 L2 受阻注入及正式進度 API，不是 NSMenu 點擊到呈現量測，也不是完整 GUI 實測。
- mutation check 只對臨時複本移除最後 presentation/watch 核對，再執行同一未修改 harness；它因舊資料混入而在 event-loop deadline 失敗，且未產生完成檔。setup-progress-C31-mutation.log 保留預期 FAIL 與外層 PASS mutation check，證明測試能拒絕缺少最後核對的版本；沒有把 mutation 的失敗當作產品通過、也未修改正式建置來源。
- open-files-C31.log（正式 observer／receipt）及 bootstrap-timing-C31.log（shell 進度格式／時間記錄，無 Wine）通過；未改其斷言。build-C31.log 以 C30 記錄的主機 Python override 完成 universal macOS11 編譯，無 Swift warning/error；44 個輸入編譯前後 hash 一致。隔離包 /private/tmp/cyder-lifecycle-c31-build/Cyder.app，local.cyder.lifecycle-c31、CD2 support/runtime，ad-hoc／strict verify、雙架構及三支包內 shell bytes 核對通過，build-C31-source-sha256.json 保存 50 項。

本批沒有啟動完整 app GUI、沒有 Wine spawn／停止或系統安裝；C30 已確認的當前 Rosetta 限制仍適用。已修正進度讀取晚到／取消的具體權限缺口，尚待其餘 UI I/O 盤點、目前測試包最終整合及完整可重現交付；V01–V14 未整體升級為完成。
