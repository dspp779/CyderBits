# BlueCG MIDI underrun

> 狀態：**已觀察、未定根因／未定修復**（2026-07）

## 現象

BlueCG 執行期間的 Wine log 曾出現：

```text
dmsynth underrun
```

目前專案文件只把它列為「通常可忽略的已知雜訊」；尚沒有足夠紀錄證明它會導致 BlueCG 黑屏、崩潰或遊戲邏輯失敗。它應與 `winemac.drv` 的視窗 backing 問題分開追蹤：A6 patch 修的是畫面 resize，不是音效時序。

## 目前判定

| 項目 | 狀態 |
|------|------|
| 是否可重現 | 執行期間曾觀察到，需以同一 engine／prefix／音效輸出再確認頻率 |
| 是否造成可聽見爆音、停音或遊戲失敗 | 未記錄，未知 |
| 是否由 MIDI 檔案或 dmsynth 音源觸發 | 未證實 |
| 是否與 A6 resize 黑屏同一根因 | 否；目前沒有證據支持，分開處理 |
| workaround | 尚無專案級修復；先記錄 log 與實際聽感 |

## 建議診斷資料

每次測試固定記錄 engine 版本、macOS、音效輸出裝置、是否使用 launcher／direct，以及是否同時發生爆音或停音。可用下列方式產生單獨 log：

```bash
WINEDEBUG=+midi,+dmsynth \
  bash scripts/run-bluecg.sh --direct 2>"$HOME/Desktop/bluecg-midi.log"
```

若該 Wine build 不接受 `+dmsynth` channel，保留完整 stderr，並改用 `WINEDEBUG=+midi` 重跑；不要因為單行 underrun 就把音效或 A6 patch 判定為失敗。

## 後續驗證

1. 以 A6 final、baseline／A4 各跑一段相同場景，分別記錄 underrun 次數與可聽見結果。
2. 比較 `WINEMSYNC`、`WINEESYNC` 都關閉與預設設定；若只在某一同步模式出現，再拆成 runtime 相容性問題。
3. 若確認有音效問題，再補上音效 backend、MIDI source 與最小重現步驟；在此之前維持「已知雜訊」分類。
