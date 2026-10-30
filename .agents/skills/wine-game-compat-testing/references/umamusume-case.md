# 參考案例：小萌繁中賽馬娘登入白底

2026-10-30 本機受控測試：M4、macOS 27.2、Cyder012、遊戲 2.18.6-10300、DXMT 0.80。不是原回報者 M3 Pro／macOS 27.0 的直接驗證。

- 相同遊戲、bottle、DXMT；兩組各用新 registry。原始環境 logo／UI 可見、背景全白；使用 Cyder 的媒體 helper 後影片持續播放。
- 白底遊戲 PID 紀錄：找不到 H.264 parser／decoder factory，`Failed to create winegstreamer transform`。
- 修正後同一解碼流程建立 `h264parse → vtdec_hw`，實際輸出協商 I420、1920×1088、24 fps；先前的 1920×1080 transform 是 Wine 支援探測。
- 離線四組：預設與只指定 scanner 均找不到元件；只指定 plugins 找到但 external scanner 失敗回退；兩者指定可找到且無回退警告。
- 另一 child 的 H.264 encoder 探測仍可失敗，不能當成登入影片解碼失敗。full-video 未含 libav 時，`avdec_h264` 不存在也不阻止 `vtdec_hw` 播放。

根因是 bundled GStreamer 的編譯預設搜尋位置仍指向建置機；修正 dylib 依賴並不會修正 plugins／scanner 的預設字串。Cyder 在程序環境選擇實際 engine root 下的：

- `GST_PLUGIN_PATH_1_0`、`GST_PLUGIN_SYSTEM_PATH_1_0`：`lib/wine/gstreamer-1.0`
- `GST_PLUGIN_SCANNER`：`libexec/gstreamer-1.0/gst-plugin-scanner`
- `GST_REGISTRY_1_0`：可寫且依 engine identity 隔離的 cache

這是該次 engine layout，其他 engine 必須實際探索；先用現有 `cyder_apply_media_launch_environment`，不要無條件覆寫使用者 GST 設定。DXMT 和 GPTK 的先前對照均因媒體環境修正而恢復影片，不能單靠換後端歸因。主要遊戲 3D 與 UI 可正常顯示。

歷史來源（需要現況時重新讀取）：

- [Issue #11](https://github.com/dspp779/CyderBits/issues/11)：原回報與後續重測。
- [PR #13](https://github.com/dspp779/CyderBits/pull/13)：已合併 app 層修正與離線測試。
- [DXMT v0.73](https://github.com/3Shain/dxmt/releases/tag/v0.73)：已列登入影片上游修復，但不能推論涵蓋所有地區版、媒體探索或後續版本條件。

不要把此案例的結論、PID、安裝路徑或螢幕點位套用到未驗證遊戲。
