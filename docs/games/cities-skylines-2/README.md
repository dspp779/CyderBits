# Cities: Skylines II（城市：天際線 2）使用指引

> 適用：Cyder 0.15.0 起（Windows 引擎 Cyder014）。
> 狀態：**測試中，尚未宣稱可玩**。已確認可進主選單、新建城市、存檔、重開讀檔與正常退出；長時間建造、Paradox Mods 與設定保存仍在驗證（[#10](https://github.com/dspp779/CyderBits/issues/10)）。

Cyder 不修改遊戲檔案，也不替你啟動 Steam 或略過任何登入。以下步驟只使用 Steam 本身與 Cyder 的設定。

## 需求

| 項目 | 說明 |
|---|---|
| macOS | 15 以上（CS2 只能使用 DXMT 圖形，DXMT 需要 macOS 15） |
| GPU | 支援 Metal GPU Family Mac 2（Apple Silicon 可用）。不支援時 Cyder 會在啟動前停止並顯示 `CYD-GFX-002` |
| Cyder | 0.15.0 以上；較舊的 Windows 引擎會在啟動時出現 `IOException` 並停在黑畫面 |
| Steam | Windows 版 Steam，安裝在 Cyder 的 Windows 環境中，並已登入、擁有 CS2 |

## 一次性設定

1. **全域圖形轉譯不要選 DXVK。** 選 DXVK 時 Steam 不會出現視窗。保持「預設」即可；若必須使用 DXVK，請把 Steam 本身單獨設為 WineD3D（見 [Steam](../steam/README.md)）。
2. **CS2 的圖形保持「預設」。** Cyder 會自動讓 `Cities2.exe` 使用 DXMT。只有 DXMT 能正常顯示：D3DMetal 會讓城市畫面全黑，DXVK 會停在主選單無法操作。
   - 如果你把全域或 CS2 的圖形設成「預設」以外的選項，Cyder 會照你的設定執行，不會改成 DXMT。畫面異常時請改回「預設」。

## 每次遊玩

1. 用 Cyder 開啟 Steam 並登入，**讓 Steam 留在背景執行**。
2. **不要按 Steam 的「開始遊戲」。** 那會安裝並啟動 Paradox Launcher，目前無法在 Cyder 使用。
3. 在 Cyder 直接開啟遊戲資料夾中的 `Cities2.exe`，通常位於：
   `C:\Program Files (x86)\Steam\steamapps\common\Cities Skylines II\Cities2.exe`
   - 可以把它加入 Cyder 遊戲庫，之後從遊戲庫啟動。
   - Cyder 會從 Steam 的安裝資料自動帶入遊戲的 Steam App ID，不需要 `steam_appid.txt`。
4. 第一次啟動會出現 Paradox 使用者協議與隱私權政策，請自行閱讀並決定是否同意。

## 顯示模式

遊戲預設的獨占全螢幕在 macOS 上切換視窗（Cmd-Tab）時可能不穩定。建議進入遊戲後到「選項 → 圖形」把顯示模式改成 **全螢幕視窗（Fullscreen Window）** 或 **視窗**。

## 結束遊戲

在遊戲內按 Esc 開啟選單 → 退出 → 退出至桌面。Steam 會繼續在背景執行，可以從 Cyder 或 Steam 正常關閉。

## 已知限制

- Paradox Launcher 與 Steam「開始遊戲」按鈕無法使用，請直接開啟 `Cities2.exe`。
- 只有 DXMT 圖形可用，因此需要 macOS 15 以上。
- 舊款 Intel Mac 目前無法執行：在 GTX 780M（OpenCore Legacy Patcher，macOS 15.8）上，DXMT 會在建立圖形時結束，DXVK 會在載入時黑畫面。這類 GPU 不支援 DXMT，Cyder 0.15.0 起會直接顯示 `CYD-GFX-002`，不再停在通用錯誤。其他 Intel GPU 尚未測試；目前請使用 Apple Silicon Mac。
- Paradox Mods、長時間遊玩與設定保存尚未驗證；遇到問題請在 [#10](https://github.com/dspp779/CyderBits/issues/10) 回報，並附上 Cyder 的遊戲記錄（請勿公開 Steam ID）。

開發者測試步驟見 [testing.md](testing.md)，技術背景見 [支援可行性與驗收方案](../cities-skylines-2-support-assessment.zh-TW.md)。
