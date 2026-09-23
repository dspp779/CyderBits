# Cyder lifecycle：A–F 交付與驗收

2026-09-23。應用層實作及本任務允許的替代驗證完成；產品程式提交 `b0d4bd59`，分支 `cyder/lifecycle-ux`。未 push、merge、發布、公證或覆蓋正式安裝；原有其他研究與未提交資料保留。

完成界線是正式程式路徑、隔離測試版與逐項證據。最新版完整 Wine／NGS、Space、VoiceOver 及真正點擊至選單呈現延遲仍未驗證。歷史真實 Wine 成功、原生 AppKit 事件重放、注入結果各自列示，不互相代替。

## 測試版

- App：`/private/tmp/cyder-lifecycle.A0NNsH/build/Cyder.app`
- 身分：`local.cy.1255e0a32c194d3d`；同 root 的 `support/`、`runtime/` 與正式資料隔離。
- 在 repo 執行 `bash scripts/build-cyder-lifecycle-test.sh` 可重建全新隔離包；不執行 app 或 Wine。
- 45 個建置輸入已逐一與 `b0d4bd59` Git blob 核對；6 個主要產物與 manifest hash 相同。arm64+x86_64、macOS11 deployment target、strict ad-hoc signature 通過。`sourceHEAD` 是建置時上下文，輸入 hash 才是版本證明。
- 詳細建置條件、開啟命令及回歸入口見 [測試版指南](2026-09-23-cyder-lifecycle-test-guide.md)。原始 log／失敗輪次／修正理由見 [完整證據報告](2026-09-21-cyder-lifecycle-evidence.md)。

## A–F 正式接線

| 批次 | 已接通的責任 | 主要證據 |
|---|---|---|
| A | reducer/store 分離 request、launch、environment、process、window；epoch/revision／完整出生身分；唯一自動退出政策 | lifecycle、binding、isolation；C16–C24 |
| B | 選單使用快照，tracking 不修改或移除；各 scanner／reader 保留實體工作上限 | menu-responsiveness；C22/C24/C32；C30–C35 UI／診斷 I/O |
| C | sentinel/journal 所有權、持久 ACK、同 ID 去重、outbox、取消／dispatch 序列化、native execution owner／one-use handoff | journal/channel/instance-runtime/operation-gate；C9–C17/C29；C33/C35 完整 secondary |
| D | Command-Q 所綁選單、status quit、AppKit 終止匯入同一有界退出；明確停止另有 scope/gate，退出不發 Wine stop | D/E/C3 歷史真實 Wine；runner/gate；C33/C35 完整 AppKit 退出 |
| E | prefix 世代監控、每世代一個 waiter、返回後校準、双 empty 證據；bounded admission／registry 恢復；原生 supervisor 不再每 launch 建 waiter | E 真實 probe；C21/C26/C27 monitor；C28/C29 包內 native child／session lock |
| F | 精確視窗 token／程序出生身分、能力降級、穩定選單、唯讀 fallback、重開接回環境與不重播歷史要求 | C22–C27；C33–C35 完整 UI／恢復重放 |

## V01–V14 結果

「替代通過」表示正式元件或完整 app 的原生事件重放／故障注入。歷史 L3 的引擎為 CX26.3.0-W11-Cyder012、當時 macOS 15.7.7；目前主機 macOS 27.0 (26A428)、arm64／Swift 6.0。不是所有列都在同一 OS 或最終包做過實機測試。

| 項目 | 結果與可定位證據 | 實測限制 |
|---|---|---|
| V01 慢掃描 | 替代通過：menu-responsiveness、settings-access、launch-context、setup-progress、diagnostics-async；C35 shared writer 確實卡住，完整 UI／退出可用 | 真正點擊至呈現延遲未量到 |
| V02 tracking 交錯 | 替代通過：callback mutation/removal 計數、快速關閉重開、stale revision／epoch；C22/C32 | 不稱為 OS 實際 status menu tracking 通過 |
| V03 ACK 遺失 | 替代通過：真實 journal/socket 的重送／遺失 ACK、固定 ID；C33/C35 第二完整 app 只增加一筆 ui-presented | 無 Wine 相容性推論 |
| V04 cancel/dispatch | 替代通過：reducer 固定排列、正式 journal/gate 的取消先後與 spawn 邊界；C13/C17 | 未做每個實際使用者輸入裝置的競態實測 |
| V05 crash/late executor | 替代通過：C9–C12/C29 真實 native executor 的 spawn 前後 crash、晚到 bridge、未確認不重播 | 自建原生 child，不是 Windows crash |
| V06 root 先退 | 替代通過：C16–C21 正式 receipt/observer/drain/generation，固定期限與一次完成 | 失去 ancestry 的 Wine 後繼不猜歸屬；真實接力未驗 |
| V07 無視窗留存 | 替代通過：alive server 保留環境入口、觀察期限後不持續 starting，C19/C24 projection | NGS 類型事件只驗生命週期政策；實際 NGS 未測 |
| V08 waiter 返回 | 替代通過：C21 premature/cancel/stale/blocked spawn、兩次 empty；E 有歷史真實 alive/empty probe | 最新 Wine GUI 未復測 |
| V09 多 launch/bottle | 替代通過：完整 birth/scope、獨立程序、不猜同 prefix 歸屬；E 真實停止 CD2 未波及另一測試 bottle | 真實多遊戲視窗未測 |
| V10 各退出入口 | 替代通過：gate/runner 與 native child 存活；C35 NSMenu、NSApp.terminate、RunLoop、主 GCD、secondary、唯讀、診斷受阻。D/E/C3 真實 Command-Q 保留 Wine births | C35 是選單 action 重放及 key binding 核對，非新一輪實際按鍵/Wine |
| V11 停止保留 UI | 替代通過：reducer/gate 明確 stop 與 quit 分開、UI 可见；E 歷史真實設定停止後視窗仍開 | 最新 status stop tracking 未實測 |
| V12 精確切換 | 替代通過：C22/C24 exact window、同名替換、PID reuse、焦點變動、timeout/quit；C22 原生雙視窗 AX 有限定實測 | Wine、其他 Space、VoiceOver 未驗；不穩定輪次已保留 |
| V13 重開恢復 | 替代通過：C23–C27 實際 journal/registry/current birth、prior boot、損壞／晚到；C35 完整重開不重播。E 有歷史 Wine 重新校準 | 最新完整 Wine 重開未實測 |
| V14 局部降級 | 替代通過：engine/prefix/probe 失聯不擋其他環境；C33–C35 ownership unavailable 的唯讀 UI，以及確實卡住 logger 後退出 | 實際斷網磁碟或裝置故障未測 |

## 回應性與失敗處理

C32 的 30 筆 callback-cycle 原始 [CSV](2026-09-23-menu-callback-C32.csv)：nearest-rank p95 **0.031166ms**、max **0.03625ms**。這是同程序 delegate callback 代理值，符合本任務 p95≤100ms 的代理檢查；不是端到端延遲，也不證明所有情況無≥250ms hang。C24 的 32 程序列代理分布與其他失敗樣本在完整報告保留，未挑選最低樣本來取代它們。

本輪完整入口測試發現並修復：零參數設定視窗初始化錯誤、terminateLater 中 GCD deadline 不執行、唯讀 fallback 被 idle 過早退出、隔離 bundle ID 造成 socket 路徑過長。後續修復遊戲庫檔案查詢、晚到進度／檔案結果與診斷同步 I/O。C35-r4 中真正注入卡住 writer 的 quit 為 **3.004616s**；三秒 deadline 及五秒背景觀察是工程選擇，不是 Apple 門檻。

CUA 有重複不可用 target／長 timeout，C33 未取得 AX 或 screenshot；目前 Rosetta 系統執行檢查失敗，未自行安裝。依授權改採替代驗證，沒有因受阻停止可完成的工作。C35 早期 FIFO 未真正卡住讀取，r3 的加強斷言抓到此事；只有 r4 的 beforeIO marker／沒有 session log／完整 UI 結果才作受阻證據。

## 使用限制與後續實機範圍

- 無證據時保留 unknown／unconfirmed，不把 waiter exit 0、無視窗或相同 prefix 推定成遊戲已退出或同一款遊戲。
- 舊 session `.lock` 無法證明 owner 已結束時保留並局部拒絕；不自動刪除未知鎖。新 kernel lock 的 crash／最後 close 釋放已驗證。
- 超過受管理容量、無權限、無法確認 engine/prefix、過長 socket 路徑會明確降級；不自動重派未知要求。
- 退出優先於卡住的診斷寫入；最後診斷可能未落盤，一般日誌滿載會丟棄並記數。durable request journal 與去重權威未依賴這些日誌。
- 若後續恢復可執行的 Rosetta 及可靠 CUA，可在指南的新隔離包重測 Wine 多視窗／接力／背景留存／真正 tracking、Space、VoiceOver、端到端性能及實際 NGS。這些不是本次已通過的相容性聲明。

本次未留下已知、未處理的退出殺遊戲、accepted 重播、錯誤程序歸屬或正常排空永遠 unknown 的產品缺口。此結論以以上正式路徑及允許的替代證據為界；實機限制保留，不升級為全面遊戲相容性承諾。
