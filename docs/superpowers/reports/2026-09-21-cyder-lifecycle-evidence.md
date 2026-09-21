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

| 項目 | 目前證據 | 剩餘 |
|---|---|---|
| V01 | 慢 OS 掃描替身驅動正式 controller；有界 in-flight | 完整 observer/runner，真實 status tracking 延遲 |
| V02 | 正式 menu callback 的 mutation/removal 計數，快速重開及 stale revision 替身 | 真實 status menu tracking |
| V03 | 尚未驗證 | 持久 ACK 遺失及同 ID 重送 |
| V04 | reducer 全部 cancel/dispatch/quit 排列通過（L1） | journal/外部 executor 整合 |
| V05 | 尚未驗證 | crash 邊界與晚到 supervisor |
| V06 | reducer 固定期限、一次收尾（L1） | 真實 root/child 接力 |
| V07 | 無視窗環境保留、未知不假退出（L1） | 監控接線；實際 NGS 未測 |
| V08 | waiter 取消、重複、舊世代淘汰（L1） | 真實 waiter 校準 |
| V09 | 同環境两 launch、第二 bottle、無證據不歸屬（L1） | 真實多 bottle |
| V10 | reducer quit 無 stop effects，queued/晚到 accepted 保留（L1） | 所有 app 入口及父程序退出实測 |
| V11 | reducer stop 保留 UI（L1） | 正式 stop adapter |
| V12 | process tombstone/PID reuse（L1） | action capability、焦點競態 |
| V13 | 歷史 uncertain 不維持 app（L1） | journal/恢復中退出 |
| V14 | 狀態可局部分離（模型） | engine 缺失/失聯故障注入 |

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
