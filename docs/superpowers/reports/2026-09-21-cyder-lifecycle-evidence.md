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
