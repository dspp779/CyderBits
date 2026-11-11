# 相容性對照與紀錄

## 最小紀錄

每次 run 記錄：run ID、時間、遊戲／launcher／engine／backend 版本、OS／晶片、prefix 的本機代稱、資料下載是否完成、設定差異、launcher 與遊戲 PID、重現步驟、畫面與媒體紀錄的對應。先從已存在的紀錄找證據，再加必要診斷。

把原始紀錄保存在私有、gitignored 位置。不要整份輸出 `env`、`ps eww`、廣泛程序參數或網路請求；公開只貼經篩選的媒體／圖形行。PID 與時間用來避免把其他 child 的 codec 探測誤認為遊戲播放錯誤。

## 後端對照

1. 同一場景，同一 engine／媒體設定，先重現原始後端。
2. 確認 Cyder 此版本實際提供的 DXMT、WineD3D、DXVK 或 D3DMetal。只測適用的後端；GPTK 已安裝不表示本次遊戲確實使用它。
3. 正常退出遊戲與 launcher，透過 Cyder 對應啟動流程切換，重新記錄 PID。
4. 在遊戲 PID 上以模組／loader log 驗證實際 DLL 和 native 元件，例如定向 `lsof -p <pid> -Fn`；只載入 `libd3dshared` 不足以認定是 D3DMetal。
5. 報告結果及限制。媒體設定同時改變時，不能將效果單獨歸因於後端；不同場景、上限或其他同時運行遊戲不能作有效 FPS 比較。

## 白底／影片缺失

| 階段 | 有用的證據 | 不能單憑它認定 |
|---|---|---|
| 插件探索 | factory 不存在、loader 搜尋錯路徑 | 需要下載新 codec |
| transform 建立 | H.264 輸入與 raw 輸出、建立成功／失敗 | 全部資產都是同一 codec |
| 解碼輸出 | 實際解碼器、協商 caps、輸出 sample | D3D11 一定正確呈現 |
| 呈現 | 同一場景持續變化的影片影格 | 所有遊戲模式已相容 |

依序檢查：

- 資料是否已下載、modal 是否刻意遮暗背景、資產／影片是否尚在載入。選定可重現畫面，不把下載中的暫態當固定白底。
- 若使用 Wine GStreamer，區分 bundled library、plugins、scanner、registry。插件本身存在仍可能因編譯預設指向建置機而找不到。
- 用新且獨立 registry 做對照，避免掃描快取干擾；不要清除使用者全域快取。必要時比較「預設／只指定 plugins／只指定 scanner／兩者指定」。每組用相同 library 與各自新 registry。
- 優先使用已有 app helper 套用媒體環境，確保測的是實際實作。記錄外部 GST overrides，避免無意混用架構／版本。
- 短期可用程序限定 `GST_DEBUG=2,WINE:4` 收集 factory、caps、transform。先確認此 Wine build 的 debug category；GStreamer `WINE` 與 Wine `WINEDEBUG` channel 不是同一機制，`trace+winegstreamer` 不一定能取得需要的 PE 紀錄。
- 能力 probe 的固定尺寸不是實際影片尺寸；H.264 encoder 錯誤不是 decoder 錯誤；`avdec_h264` 缺少不代表沒有其他可用 H.264 decoder。
- factory／解碼成功但仍空白，才繼續調查影片材質、色彩轉換與 D3D11 呈現。Unity 遊戲可能走第三方 CRI／Media Foundation，不能只靠 Unity 版本或副檔名認定 VideoPlayer／codec。

若完整路徑修正仍無輸出，不反覆亂加 DLL override。保留同一 batch 的可用證據，指出下一個可區分假說的測試；停止無法控制的比較。

## 修正與回報

以程序限定修正、遊戲專屬設定或 app 啟動契約優先；確認啟動器子程序繼承，處理搬移、中文／空白路徑、舊 engine、不完整 runtime、使用者明確 override，以及切換引擎時殘留值。對有共用影響的啟動層變更增加相應離線測試，stub 繼承測試不等於實機解碼驗證。

報告清楚分開：本機已驗證／原回報機器待重測／未測模式。PR 合併不等於已發佈，也不等於 issue 自動可關；公開留言與 issue 操作需使用者授權。
