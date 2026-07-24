# 遊戲相容性矩陣 (Game Compatibility Matrix)

本文件彙整在 macOS 環境下透過 Cyder / CyderBits (Wine / CrossOver 核心 runtime) 測試 Windows 經典遊戲與線上遊戲的相容性狀態、必要設定與已知問題變通方案 (Workarounds)。

---

## 📊 遊戲相容性總表

| 類別 | 遊戲名稱 | 測試版本 | 狀態 | 必要設定 / 啟動參數 / 依賴 | 已知問題與說明 |
| :--- | :--- | :--- | :---: | :--- | :--- |
| **單機** | 世紀帝國 2 | 3.8 | ⚠️ 可玩 (有頓挫) | 無特別參數 | 每 5 秒會頓一下 (已知 Wine/macOS 問題，國外論壇亦有相關討論) |
| **單機** | 大富翁 4 | - | 🟡 需 ddraw | 需搭配 `cnc-ddraw` | 原版會黑畫面，滑鼠移到控制項才顯示；搭配 `cnc-ddraw` 後顯示正常 |
| **單機** | 皮卡丘打排球 | - | 🟡 特殊條件 | 建議關閉 MSync；CrossOver 需開啟儲存 log 檔 | 大部分情況可玩；若未開 log 或開啟 MSync 有機率當掉 (疑與執行過快 / race condition 有關) |
| **單機** | 洛克人 X3 / X4 | - | ⚠️ 錯誤提示可玩 | 無特別參數 | 啟動時會跳 DirectX 初始化錯誤，但忽略/關閉提示後即可正常遊玩 |
| **單機** | 洛克人 X5 | - | ⚠️ 畫面縮放 | 無特別參數 | 可正常遊玩，但遊戲畫面會縮在螢幕左上角 |
| **單機** | 越南大戰 | - | 🟢 可玩 | **關閉** Retina Mode | 停用 Retina Mode 即可正常遊玩 |
| **單機** | 暗黑破壞神 2 | - | 🟢 可玩 | **關閉** Retina Mode | 停用 Retina Mode 即可正常遊玩 |
| **單機** | 魔獸爭霸 3 | - | 🟢 可玩 | 啟動參數 `-nativefullscr` | 帶入 `-nativefullscr` 參數可確保開啟螢幕最高解析度 |
| **單機** | 小朋友齊打交 2 | 1.9c | 🟢 可玩 | 無特別依賴 | 可直接執行遊玩 |
| **單機** | 小朋友齊打交 2 | 2.0a | 🟡 需 winetricks | `vcrun2005`, `wmp9`, `quartz`, `devenum`, `vb6run` | 需透過 winetricks 安裝上述 VC/VB 運行庫與 Windows Media 組件 |
| **線上** | 水藍魔力 | - | 🟢 可玩 | DirectDraw / GDI | 專案驗證基準，可正常登入遊玩 (驗證 same-view backing sync) |
| **線上** | 新楓之谷 | - | 🟢 可玩 | 搭配 MapleStory Launcher 引擎 & [CitrusGate](https://github.com/dspp779/CitrusGate) | 需搭配 CitrusGate 傳送登入 OTP 參數 |
| **線上** | 新楓之谷 經典版 | - | 🟢 可玩 | 搭配 [CitrusGate](https://github.com/dspp779/CitrusGate) | 需搭配 CitrusGate 傳送登入 OTP 參數 |
| **線上** | 爆爆王 | - | 🟢 可玩 | 無特別依賴 | 可正常遊玩（⚠️ 台灣官方預計於 2026/08/13 結束營運） |

> **圖示說明：**
> - 🟢 **可玩**：功能正常或僅需基礎設定即可順暢遊玩。
> - 🟡 **需 Workaround**：需額外安裝 DLL、依賴庫 (winetricks)、第三方補丁或特殊關聯工具。
> - ⚠️ **部分瑕疵**：遊戲可玩，但存在畫面縮放異常、偶發頓挫或錯誤提示等不影響主流程的問題。

---

## 🕹️ 遊戲詳細相容性與設定說明

### 單機遊戲 (Single-Player Games)

#### 1. 世紀帝國 2 (Age of Empires II)
* **版本**：3.8
* **狀態**：⚠️ 可玩（每 5 秒頓挫）
* **說明**：遊戲可順暢開啟與操作，但在執行過程中間歇性每隔約 5 秒會出現短暫 Micro-stutter（卡頓）。此為已知問題，國外 Wine/CrossOver 社群亦有相關討論與回報。

#### 2. 大富翁 4 (Richman 4)
* **狀態**：🟡 需 cnc-ddraw
* **說明**：原生 DirectDraw 繪圖在 Wine 下預設會出現黑畫面，僅在滑鼠移動至特定 UI 控制項時才局部刷出畫面。
* **解法**：在遊戲目錄放置並配置 [`cnc-ddraw`](https://github.com/FunkyFr3sh/cnc-ddraw) 作為 DirectDraw 轉譯器，即可恢復正常顯示。

#### 3. 皮卡丘打排球 (Pikachu Volleyball)
* **狀態**：🟡 特殊啟動條件
* **說明**：
  - 部分環境或瓶頸下關閉 **MSync / ESync** 方能正常執行。
  - 在 CrossOver 環境下，需在啟動選項中**開啟存儲 log 檔 (Save Log)** 遊戲才不會隨機崩潰（推測可能與 CPU 執行速度過快導致 timer/thread race condition 有關，寫入 Log 恰好提供了微小延遲）。
  - 詳細可參考 [皮卡丘打排球問題文件](pikachu-volleyball/README.md)。

#### 4. 洛克人系列 (Mega Man X Series)
* **Mega Man X3 / X4**：啟動時會跳出 `DirectX Initialization Error` 錯誤彈窗，但按下確認/忽略後不影響後續遊戲進入與遊玩。
* **Mega Man X5**：遊戲可正常執行，但視窗/渲染畫面會縮在螢幕左上角，未自動拉伸。

#### 5. 越南大戰 (Metal Slug) & 暗黑破壞神 2 (Diablo II)
* **狀態**：🟢 可玩
* **關鍵設定**：**停用 Retina Mode**（Retina 模式下可能導致畫面縮小或滑鼠座標偏移）。

#### 6. 魔獸爭霸 3 (Warcraft III)
* **狀態**：🟢 可玩
* **啟動參數**：在啟動命令後面加上 `-nativefullscr`
* **效益**：確保遊戲能正確鎖定並開啟螢幕的最高原生解析度。

#### 7. 小朋友齊打交 2 (Little Fighter 2)
* **v1.9c**：🟢 可直接執行遊玩。
* **v2.0a**：🟡 需安裝 runtime 依賴。
  * **Winetricks 指令**：
    ```bash
    winetricks vcrun2005 wmp9 quartz devenum vb6run
    ```
  * **說明**：2.0a 版引入了 Visual Basic 6 運行庫、C++ 2005 運行庫以及 Windows Media Player / DirectShow (quartz/devenum) 播放元件，需完整安裝上述組件方可正常啟動。

---

### 線上遊戲 (Online Games)

#### 1. 水藍魔力 (BlueCG)
* **狀態**：🟢 可玩
* **說明**：本專案驗證 DirectDraw / GDI 之基準遊戲，具備 same-view backing sync，可正常開啟與視窗化 resize。

#### 2. 新楓之谷 (MapleStory) & 新楓之谷 經典版 (MapleStory Classic)
* **狀態**：🟢 可玩
* **關鍵組件**：
  - **新楓之谷**：需切換/指定使用 `MapleStory Launcher` 引擎。
  - **OTP / 登入整合**：需搭配 [CitrusGate](https://github.com/dspp779/CitrusGate) 處理並傳送登入 OTP 參數。

#### 3. 爆爆王 (Crazy Arcade)
* **狀態**：🟢 可玩
* **說明**：遊戲運作正常。（⚠️ 台灣伺服器營運備註：原廠/代理商預計於 2026 年 8 月 13 日停止營運）。
