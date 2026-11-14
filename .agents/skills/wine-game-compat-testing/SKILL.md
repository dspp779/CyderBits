---
name: wine-game-compat-testing
description: 在 macOS 上操作與測試 Wine／Cyder 遊戲相容性；適用於 Wine 視窗無 bundle ID、一般桌面工具無法辨識、啟動器子程序追蹤，以及圖形後端或影片播放異常的受控對照。不代替 Wine 引擎建置或 Cyder 發佈流程。
---

# Wine 遊戲相容性測試

目標：把「看到什麼」、「實際載入什麼」、「哪項改動改變結果」連起來。只處理使用者指定且可重現的畫面；範圍縮小後不再漫遊其他模式。

依序進行，任一步無法確認就停下回報，不要猜。

## 1. 準備

1. 讀 `AGENTS.md`：啟動層、設定、診斷在本 repo 修；Wine 原始碼與建置在 engine repo。
2. 找該遊戲的固定步驟：`docs/games/<game>/testing.md`（BlueCG 已有）、`docs/games/README.md`、`docs/games/compatibility-matrix.md`。
3. 要從 Cyder.app 啟動遊戲，測試版必須以 Developer ID 簽署（做法見 `cyder-dev-test`）。ad-hoc 版會停在圖形準備（`publisher_unverified`）。
4. 記錄：遊戲與啟動器版本、引擎版本、圖形後端、macOS 與晶片、prefix、資料是否下載完成、重現畫面。公開報告不含本機路徑、帳號、憑證。
5. 優先用獨立 bottle。若用既有 bottle（測試版共用使用者真正的設定與環境），先記下會被改動的設定與進度，測完還原。

## 2. 找到正確的視窗

Wine 視窗在 Dock 可能只叫 `wine`，沒有 bundle ID，也沒有 AX 按鈕；啟動器 PID 通常不是遊戲 PID。

1. 先用可用的桌面操作工具。無法辨識 Wine 視窗時，改用 [macOS 操作方式](references/macos-controls.md)。
2. `scripts/wine-windows.swift` 列出權限狀態與可見 Wine 視窗。用標題、PID、window ID、引擎執行檔與**新截圖**交叉確認目標。
3. 缺少 Screen Recording 或 Accessibility 時，告訴使用者要在系統設定開哪一項、授權給誰，然後等待。不要修改 TCC 資料庫。

## 3. 操作

1. `scripts/guarded-click.swift` 先不加 `--click` 預覽；確認目標後才加 `--click` 送出一次點擊。按鍵（移動、攻擊、技能）用 `scripts/guarded-key.swift`，先預覽，確認後加 `--send` 送出一次按鍵或一次 `--hold` 長按。
2. 腳本會拒絕不符的 PID／window ID／標題與超界座標，且要求目標視窗在最前方。驗證失敗就回到步驟 2 重新觀測，不要盲目重試或改點其他 Wine 視窗。
3. 點擊回傳成功只代表事件已送出；一定要再截圖確認畫面變化。
4. 使用者允許遊玩，不等於允許消費、抽卡、刪檔或公開發文；這些要另外取得同意。
5. 關閉遊戲走遊戲自己的結束流程。不要用全域方式終止共享的 wineserver。

## 4. 受控對照

先讀 [對照與紀錄](references/diagnostic-matrix.md)，選最小的實驗：

1. 一次只改一類變因；場景、遊戲檔案、下載狀態與其他設定保持相同。
2. 用遊戲程序實際載入的模組與紀錄確認後端。設定裡選了某後端，不代表真的載入它。
3. 環境變更限定在該次啟動的程序，測完可還原。不要把單一遊戲的假說寫成全域 DXMT 設定，也不要改遊戲二進位。

常見的錯誤推論：

| 觀察 | 不能直接推論 |
|---|---|
| UI 正常、影片白底 | 3D 渲染失敗（先分清元件探索、解碼、輸出格式、材質呈現） |
| 解碼元件 factory 存在 | 已成功解碼 |
| 輸入已送出 | 操作已完成 |
| 兩次 FPS 不同 | 效能有差（場景或 FPS 上限不同就不能比） |

GStreamer 路徑搬移或 H.264 問題再讀 [賽馬娘案例](references/umamusume-case.md)；它是特定環境的證據，不是通用修正。

## 5. 交付

1. 分開列出：已重現的現象、紀錄直接支持的原因、受控修正的效果、尚未驗證的假說。
2. 附上簡短的重測步驟與必要版本；保留篩選過的紀錄與不含敏感資訊的截圖。
3. 說明測試後留下的程序與設定，以及還原方式。
4. 本機通過不代表原回報者的環境已驗證。建立 PR、留言、關閉 issue 都要使用者授權。
5. 新遊戲有了固定測試步驟，就寫成 `docs/games/<game>/testing.md`。
