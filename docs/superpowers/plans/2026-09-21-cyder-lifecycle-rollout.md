# Cyder 啟動與環境監控：實作批次及驗收

> 2026-09-21 實作授權：本任務已進入 A–F 實作與隔離測試。下文「只做文件／不建置／不操作 Wine／待使用者實測」均為先前階段歷史紀錄，不再限制本任務；依 goal prompt 先真實實測，受阻後採明確標示的替代驗證。允許任務分支上的 Conventional Commits；不 push、merge、發布或覆蓋正式安裝。進度及證據另記於 `docs/superpowers/reports/2026-09-21-cyder-lifecycle-evidence.md`。

日期：2026-09-21；驗收更新：2026-09-23。A–F 應用層實作與授權的替代驗證完成，實機限制及 V01–V14 結果見 [交付摘要](../reports/2026-09-23-cyder-lifecycle-delivery.md)。下文批次順序與早期測試盤點保留為追溯，不代表仍需從 A 重做。

設計依據：[統一規格](../specs/2026-08-19-launchgroup-menu-bar-design.md) §12–23；細項追溯：[歷史計畫](2026-08-19-launchgroup-menu-bar.md) Task 5–28。後續以本文件為實作入口，不順序重跑歷史 Task 1–4，不把既有勾選當作新版完成。

## 實作批次

| 批次 | 範圍與主要檔案 | 前置／完成條件 |
|---|---|---|
| A：共用狀態 | cyder_lifecycle.swift 的 model／store、status item 與 app adapter | 先完成無 I/O reducer；環境、程序、視窗、request 分離，單一退出政策、epoch 與 snapshot revision。舊 observer 可送事件，不可保留獨立退出權威 |
| B：選單回應性 | cyder_status_item.swift、app 的選單生命週期接線 | 依 A；兩個開關回呼不改選單，更新只讀快照，tracking 不移除；慢掃描不阻塞主事件處理 |
| C：可靠接管與派送 | cyder_instance.swift、cyder_sentinel.swift、app 入口、journal／非同步 runner | 依 A；持久 ACK、同 ID 去重、取消／dispatch 序列化、primary 所有權；先驗證崩潰間隙，再切換 consumer，禁止新舊同時派送 |
| D：退出隔離 | app 的 quit／termination／stop 路徑、supervisor 清理接線 | 依 A、C 的 queued 保存與派送凍結；退出零停止環境指令，停止不關 Cyder UI，accepted 不遺失。不可只移除 -k 就視為完整退出修復 |
| E：環境監控與交棒 | prefix waiter adapter、launch support、必要 app-owned shell receipt | 依 A、C；單 prefix waiter、30 秒有界觀察、一次收尾、校準證據門檻。需要引擎變更時另開 engine repo 工作，不在此混改 |
| F：互動與恢復 | menu capability／action、app 恢復、journal reader | 依 B–E；精確視窗操作、能力降級、退出重開接回、舊要求不重播、非模態回饋 |

D 的意圖／路由單元可與 B 同時準備，但使用者可用的退出整合必須等 C 的保存契約完成。A–F 是內部落地批次，不代表各批完成即可獨立發布。遷移未完成時維持單一生效路徑，不以半套新模型掩蓋舊存續邏輯。

## 先處理的技術門檻

1. **環境結束證據**：wineserver -w 的 zero exit 不足以單獨判定完成；E 前需明訂可用證據與錯誤通道。無證據可降級 unknown，但不能以永遠 unknown 宣稱環境收尾驗收通過。
2. **primary／supervisor 交接**：新 primary 取得鎖不代表舊 supervisor 不會再 spawn；C 必須涵蓋 dispatch 後 crash 與晚到執行者，無法確認者不重播。
3. **退出不影響遊戲**：D 先用替身驗證不產生停止意圖；supervisor／pipe／父程序退出的實際影響列為實機必要驗收，不能用 unit test 宣稱已證實。

門檻不阻擋 A／B 的純模型與快照工作；阻擋的是相關批次的完成宣告及發布。

## 分層驗收

| 層級 | 可驗證內容 | 不能宣稱 |
|---|---|---|
| L0：文件／靜態檢查 | 新舊規則一致、無錯誤引用、來源與變更範圍、diff whitespace | runtime 正確或不再 beachball |
| L1：無 Wine 的事件／時鐘替身 | 去重、競態、取消、世代、期限、退出指令、恢復決策 | Wine 程序／視窗／tray 能力 |
| L2：原生編譯與隔離 harness | 相關 Swift typecheck、真實非同步回呼、tmp journal／socket、AppKit callback／tracking | NGS 與 engine 相容性；手動呼叫 callback 不等於真實 tracking |
| L3：實機驗收 | 指定 engine 與 macOS、實際 Wine／NGS／Space／tray／VoiceOver、Instruments | 未測組合全部支援 |

目前已完成正式路徑的 L1／L2 及部分限定 L3；不是所有平台／Wine 組合都已通過。真實操作受阻後的替代方法與範圍依交付摘要逐項列示；本次授權只允許隔離測試，不包含發布產品。

## 最小驗收矩陣

| 編號 | 事件序列 | 必須成立 | 批次／層級 |
|---|---|---|---|
| V01 | 掃描永久 pending，使用者開選單 | callback 不等待，快照仍可用；in-flight 不無界增加 | A、B／L1–2 |
| V02 | menu 展開時環境退出，隨即關閉重開 | 回呼內不修改、tracking 不移除，最終只採最新 revision | B／L2 |
| V03 | accepted 已提交但 ACK 遺失，同 ID 重送 | 只接回同一筆，不重派；不拿其他要求清空當 ACK | C／L1–2 |
| V04 | cancel 與 dispatch 同時到達 | 未派送才 cancelled；已跨界不偽報、不殺遊戲 | C／L1–2 |
| V05 | dispatch 後 primary crash，supervisor 晚到 | 不重播、不猜未執行，結果可 uncertain | C／L1–2 |
| V06 | root 先退出，後繼晚到 | 有證據才附加，期限不重設，排程只釋放一次 | E／L1、L3 |
| V07 | MapleStory 結束，NGS 留存且未發現視窗 | 環境入口仍在，無持續 spinner，不稱等待清理 | E、F／L1、L3 |
| V08 | waiter 過早返回／被取消／舊世代返回 | 不誤判當前環境結束，不高速重建 waiter | E／L1–2 |
| V09 | 同 prefix 兩 launch，另有第二 bottle | 共用環境不猜遊戲歸屬；一處停止不影響其他 bottle | A、E／L1、L3 |
| V10 | 每個退出入口，包含 queued／dispatch／stop 中 | 無新停止指令；queued 保存，已發停止不補送 | C、D／L1–3 |
| V11 | 停止環境成功，遊戲庫仍開啟 | Cyder 視窗不隱藏／不強制退出 | D／L1–2 |
| V12 | 切換中目標退出／同名替換／使用者改焦點 | 不切錯視窗、不重啟、不追著搶焦點 | F／L1、L3 |
| V13 | 重開後遊戲還在／OS 已重啟／紀錄損壞 | UI 先可用，重新驗身分，不重播舊要求 | F／L1–3 |
| V14 | 一個環境失聯／engine 缺失 | 局部降級，其他環境可操作，退出仍可用 | E、F／L1–3 |

## 實作前測試盤點（歷史；處理結果見證據報告）

- `tests/test-cyder-menu-responsiveness.sh` 已有慢掃描替身，但目前手動呼叫 AppKit delegate，不能驗證真正 tracking；需補回呼內 mutation 計數、延後移除與 stale revision 行為，不能只確認返回即可。
- `tests/test-cyder-instance.sh` 仍要求 requestPollTimer／waitUntilNoPendingRequests 等舊機制；改驗可靠接管與回應性，不為讓字串測試通過保留輪詢／同步等待。
- `tests/test-cyder-sentinel.sh`、`tests/test-cyder-open-files-lifecycle.sh`、`tests/test-cyder-session.sh` 逐一映射新版契約；保留仍有效行為，明確記錄被新設計取代的斷言。不刪除失敗斷言冒充修復。
- 實作盤點確認 `tests/test-cyder-status-item.sh` 存在；它以原始碼字串固定多項舊政策，需逐項改為新版行為驗證，不能用字串通過當 runtime 證據。
- 不盲跑全套 launcher 腳本；先讀其副作用，確認是否使用替身／可能啟動 Wine。編譯來源清單按實際 build script 核對，新檔須加入 product build 與 harness。

## 每批交付記錄

每批記錄：變更檔案、替換掉的舊權威、已跑命令與結果、未驗證行為、下一批依賴。測試失敗區分回歸／舊契約衝突／既有問題，不能未調查就標成既有問題。只跑與改動有關的必要檢查，通過後不無理由重複。

需要回退時保留 journal 與去重 tombstone；舊版本若不能讀新 schema，禁止自動派送舊要求。內部遷移以一致 adapter／單一 consumer 切換，不用同時跑兩套 executor 的方式比對。本任務已授權在專用分支分批 Conventional Commits 及隔離測試建置；未授權 push、merge 或發布。

## 交付與後續實機復測

正式路徑及目前完成界線見 [交付摘要](../reports/2026-09-23-cyder-lifecycle-delivery.md)。使用 [測試版指南](../reports/2026-09-23-cyder-lifecycle-test-guide.md) 可重建全新隔離包；舊證據與失敗輪次不刪除。後續真實 Wine／NGS、Space、VoiceOver 與端到端性能復測需要可用的 Rosetta／UI 工具，不把本次替代驗證改稱相容性實測通過。
