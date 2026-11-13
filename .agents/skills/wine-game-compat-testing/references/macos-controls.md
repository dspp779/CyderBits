# macOS Wine 視窗操作

## 探索，不依賴 Dock 名稱

在技能目錄下執行（先確認 macOS、Swift／Command Line Tools 可用）：

```bash
swift scripts/wine-windows.swift
```

輸出權限、Wine 程序 executable 和 on-screen 視窗的 PID／ID／標題／bounds／layer。不輸出完整程序參數，避免 launcher URL、token 或其他程式登入資訊。若程式名不含 Wine，可加目標 PID：

```bash
swift scripts/wine-windows.swift --pid 12345
```

多個遊戲可能共用相同 engine executable，不能只靠路徑判定。遊戲啟動後重新探索 ID；不要沿用 launcher ID。

## 截圖與座標

使用可用桌面工具截取指定視窗。曾驗證可用的 Peekaboo 呼叫形狀如下，先以本機 `--help` 確認版本支援；不要硬編碼這次測試的暫存 binary 路徑：

```bash
peekaboo see --pid 12345 --window-id 678 --no-elements --path /private/tmp/game-window.png --json
```

用影像檢視工具讀取產物後再決定點位。Peekaboo 擷取可成功，而 Wine 的 AX 元素查詢／點擊仍可能失敗；這時可用 native CGEvent fallback。不可用 voice-only 的畫面工具代替一般桌面擷取。

腳本座標是相對 **CGWindow bounds 的 points，包含 title bar**，不是任意縮圖的像素。若截圖含完整視窗，將點位按 `bounds.width / image.width` 與 `bounds.height / image.height` 分別換算；有裁切時先補回偏移。Retina、解析度或視窗大小改變後重算，不沿用案例座標。

## 原生單次點擊

```bash
# 預覽：不啟動／抬升視窗，不送輸入
swift scripts/guarded-click.swift 12345 678 '遊戲實際視窗標題' 400 300
# 明確執行：驗證後抬升／聚焦並點擊一次
swift scripts/guarded-click.swift 12345 678 '遊戲實際視窗標題' 400 300 --click
```

執行前需有新的指定視窗截圖，確認點位語意。`--click` 不構成對消費或其他未授權行為的許可。Wine 沒有 AXWindowNumber 時，腳本仍可依 CGWindow topmost 驗證，但若無法讓精確目標到前景便拒絕。overlay／modal 出現或 PID、ID、標題變動時重新擷取並觀測。空標題視窗也要由已觀測的 PID／ID 選定。

發送事件仍有極短的前景變動競態；操作期間不要同時操作桌面。每次點擊後看新截圖，避免長串固定座標腳本。拖曳需要另外採用具有同等目標驗證的工具。

## 原生單次按鍵

```bash
swift scripts/guarded-key.swift --list-keys            # 可送出的鍵名
# 預覽：不啟動／抬升視窗，不送輸入
swift scripts/guarded-key.swift 12345 678 '遊戲實際視窗標題' left --hold 1500
# 明確執行：驗證後抬升／聚焦，按下 left 1.5 秒後放開
swift scripts/guarded-key.swift 12345 678 '遊戲實際視窗標題' left --hold 1500 --send
```

- 目標驗證與點擊腳本相同（PID、window ID、完整標題、layer 0、最前方、bounds 未變）。
- 一次只送一個鍵；`--hold` 為 0–10000 毫秒，預設 80。長按期間每 50 ms 重新驗證，失焦或視窗移動就立刻放開並拒絕。Ctrl-C／終止訊號也會先放開按鍵。
- 單獨的 `shift`、`control`／`ctrl`、`option`／`alt` 以 flags-changed 事件送出（遊戲常用作跳躍或攻擊鍵）。
- 不提供 Command 鍵，也不提供組合鍵，避免觸發 macOS 快捷鍵（結束、隱藏、切換 App）。
- 不輸入文字；不要用逐鍵方式在遊戲內聊天或填表。

## 權限與停止

- 讀畫面需要 Screen Recording；送事件需要 Accessibility／PostEvent 權限。授權對象可能是執行工具或宿主 App，以當下診斷為準。
- 本機 sandbox 可能還需要工具執行授權；已有 macOS 權限不會自動解除 sandbox。
- 關閉時優先經確認的遊戲視窗正常退出。只有要強制終止時才辨識精確程序，避免 `killall wine`、`wineserver -k` 影響同 bottle 其他程式。
- 不沿用任何案例中的 PID、window ID 或絕對點位。
