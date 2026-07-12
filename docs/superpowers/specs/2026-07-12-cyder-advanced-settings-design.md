# Cyder 進階設定與操作流程設計

> 日期：2026-07-12  
> 範圍：`Cyder.app`（AppKit Swift 前端）與共用 Wine prefix  
> 狀態：產品與互動規格，供後續分階段實作

## 1. 結論

Cyder 可以加入完整的進階設定介面。建議不要只依賴 Dock 右鍵，而採三個入口：

1. **主要入口**：選擇執行檔視窗右下角的齒輪「進階設定…」。
2. **標準入口**：macOS 選單列 `Cyder → 設定…`，快捷鍵 `⌘,`。
3. **便利入口**：Dock 圖示右鍵 →「進階設定…」。

Dock 選單透過 `NSApplicationDelegate.applicationDockMenu(_:)` 實作，但目前 Cyder 啟動遊戲後會終止，Dock 圖示也會消失，所以 Dock 右鍵只能是輔助入口。若未來要讓它隨時可用，需將 Cyder 改為常駐管理程式；第一版不建議為此增加常駐行為。

## 2. 設計原則

- **簡單模式不受干擾**：第一次使用仍是安裝引擎 → 選 `.exe` → 啟動。
- **安全預設**：一般使用者看到的是經過驗證的預設組合，不必理解 Wine registry。
- **先解釋影響，再允許變更**：高風險設定顯示相容性與重啟提示。
- **立即儲存、下次啟動套用**：開關與下拉選單變更後立即寫入設定，但不修改正在執行的遊戲。
- **可復原**：每一頁都有「恢復此頁預設值」，總覽另有「全部恢復預設值」。
- **避免假功能**：引擎尚未具備的 Direct3D backend 不顯示成可用選項。

## 3. 設定作用域

目前 Cyder 使用 `~/Library/Application Support/Cyder/SharedPrefix`，因此 registry 類設定會影響所有由 Cyder 啟動的遊戲。

第一階段明確標示：

> 這些設定會套用到所有使用 Cyder 共用環境的遊戲，並於下次啟動生效。

若未來加入每遊戲 bottle，再將頁面頂部增加作用域選擇：

- 所有遊戲（全域預設）
- 此遊戲（覆寫全域設定）

第一版不提供看似 per-game、實際仍污染共用 prefix 的覆寫功能。

## 4. 主視窗與入口

### 4.1 啟動狀態

沿用目前 360 × 120 的載入面板：

- 建立遊戲引擎中…
- 準備 Windows 環境中…
- 正在套用設定…（新增）
- 正在啟動遊戲…

安裝或套用 registry 時禁止修改設定；進階設定入口可顯示但 disabled，並附「初始化完成後可使用」。

### 4.2 選擇執行檔視窗

不要再只顯示系統 `NSOpenPanel`。改為一個小型 Cyder 主視窗：

```text
┌──────────────────────────────────────────┐
│                 Cyder                    │
│                                          │
│   將 Windows 執行檔拖到這裡              │
│   或                                     │
│   [ 選擇 .exe… ]                         │
│                                          │
│   最近使用：game.exe                     │
│                         [⚙ 進階設定…]    │
└──────────────────────────────────────────┘
```

拖入 `.exe` 或按「選擇 .exe…」後直接啟動；使用者不必先進設定頁。

### 4.3 選單與 Dock

macOS 應用程式選單：

- 關於 Cyder
- 設定… `⌘,`
- 重置所有設定…
- 結束 Cyder `⌘Q`

Dock 右鍵：

- 選擇 Windows 執行檔…
- 進階設定…
- 最近使用（最多 5 個，僅列仍存在的檔案）

## 5. 進階設定視窗

採原生 `NSWindow` + 左側 sidebar，建議尺寸 680 × 500：

```text
┌────────────────────────────────────────────────────────────┐
│ 進階設定                                                   │
├──────────────┬─────────────────────────────────────────────┤
│ 一般         │ 顯示                                       │
│ 顯示         │                                             │
│ 字體         │ 高解析度（Retina Mode）       [ 開啟 ]      │
│ 鍵盤         │ 縮放比例 / DPI                [200% ▾]      │
│ 圖形         │                                             │
│              │ ℹ 建議搭配：Retina + 200%                  │
│              │                                             │
│              │ [恢復此頁預設值]                           │
└──────────────┴─────────────────────────────────────────────┘
```

視窗底部固定狀態列：

- 未變更：`設定將於下次啟動遊戲時生效`
- 已變更：`已儲存；重新啟動遊戲後生效`
- 套用失敗：紅色錯誤訊息 +「查看記錄」

## 6. 各頁規格

### 6.1 一般

| 欄位 | 控制項 | 預設 | 行為 |
|---|---|---:|---|
| MSync | Switch | 開 | 啟動時設定或移除 `WINEMSYNC=1` |
| 設定套用範圍 | 說明文字 | 所有 Cyder 遊戲 | 第一版不可切換 |
| 恢復所有預設值 | 危險按鈕 | — | 二次確認後清除設定並重建預設 registry |

MSync 說明：

> 通常可改善效能與執行緒同步。若遊戲無法啟動、凍結或引擎記錄顯示不支援，再嘗試關閉。

### 6.2 顯示

| 欄位 | 控制項 | 預設 | 實際值 |
|---|---|---:|---|
| 高解析度（Retina Mode） | Switch | 開 | `HKCU\Software\Wine\Mac Driver\RetinaMode=y/n` |
| 縮放比例 / DPI | Popup | 200% | 100%=96、125%=120、150%=144、175%=168、200%=192、250%=240 |
| 自訂 DPI | Number field | 關 | 允許 72–480，超出拒絕儲存 |

互動規則：

- 開啟 Retina 時，若 DPI 仍為 96，顯示黃色提示：「畫面較清晰，但介面可能縮小；建議 192 DPI（200%）。」
- 關閉 Retina 且 DPI > 96 時，顯示黃色提示：「部分舊遊戲可能出現黑邊或版面異常。」
- 提供一鍵建議按鈕「使用 Retina 建議設定」：Retina 開、DPI 192、ClearType RGB。
- 不強制綁死 Retina 與 DPI，保留除錯與特殊遊戲需求。

### 6.3 字體

「系統預設字體」需避免讓使用者以為能任選任何 macOS 字體且所有 Windows 程式都會遵守。第一版設計為**字體替代方案**：

| 欄位 | 控制項 | 預設 | 說明 |
|---|---|---:|---|
| Windows 預設字體方案 | Popup | Cyder 繁中建議 | 寫入 Wine Fonts Replacements |
| 字體平滑 | Popup | ClearType RGB | 寫入 Desktop FontSmoothing 系列值 |

字體方案：

- Cyder 繁中建議（目前 Songti TC replacements）
- Windows 相容預設（移除 Cyder replacements）
- 自訂 macOS 字體…（第二階段）

字體平滑方案：

- 關閉
- 灰階
- ClearType RGB（預設）
- ClearType BGR

進階展開區可提供 Gamma（1000–2200），預設 1400。一般頁面不直接暴露 registry 名稱。

### 6.4 鍵盤

不要提供三個彼此可能衝突的獨立開關。採「Mac 修飾鍵映射」表格，每個實體鍵只能映射到一個 Windows 鍵：

| macOS 實體鍵 | 預設 Windows 鍵 | 可選值 |
|---|---|---|
| Command ⌘ | Ctrl | Ctrl / Alt / Windows / Command 原樣 |
| Option ⌥ | Alt | Alt / Ctrl / Windows / Option 原樣 |
| Control ⌃ | Ctrl | Ctrl / Alt / Windows / Control 原樣 |

頁面提供三種預設：

- Mac 習慣（⌘→Ctrl、⌥→Alt）
- Windows 鍵盤（⌘→Windows、⌥→Alt、⌃→Ctrl）
- 原樣傳遞

若兩個實體鍵映射到相同功能，允許但顯示提示；若造成某個 Windows 修飾鍵完全不可輸入，顯示警告。實作前須先用目前 CX26 mac driver 驗證可用的 registry／driver 能力；無可靠底層支援的映射不應顯示為已完成。

### 6.5 圖形 / Direct3D

第一版只顯示目前引擎確定支援且已驗證的 renderer：

| 欄位 | 選項 | 預設 | registry |
|---|---|---:|---|
| Direct3D 呈現器 | 自動、OpenGL、GDI（相容模式） | 自動 | `HKCU\Software\Wine\Direct3D\renderer` |

說明：

- **自動（建議）**：移除 renderer override，由 Wine 選擇。
- **OpenGL**：一般效能與縮放品質較佳；目前 CX26 的部分舊 DirectDraw 遊戲在調整視窗後可能黑屏。
- **GDI 相容模式**：可避開部分黑屏，但效能較低且縮放可能模糊，不支援平滑線性軟體縮放。
- **Vulkan / DXVK / VKD3D**：只有在引擎實際打包並通過檢測時才顯示。現階段 VKD3D 尚未接線，不提供假選項。

可在「進階」展開區預留：

- Video memory size（自動 / 512 MB / 1 / 2 / 4 / 8 GB）
- DirectDraw renderer（僅在引擎支援並驗證後加入）
- DLL overrides（專家模式，第二階段）

變更 renderer 時顯示確認：

> 圖形呈現器會影響所有 Cyder 遊戲。遊戲若正在執行，請先關閉並重新啟動。

## 7. 完整操作流程

### 流程 A：首次安裝、直接遊玩

1. 使用者開啟 Cyder。
2. 顯示「建立遊戲引擎中…」，完成後執行 prefix bootstrap。
3. 套用安全預設：MSync 開、Retina 開、DPI 192、ClearType RGB、圖形自動。
4. 顯示 Cyder 主視窗。
5. 使用者拖入或選擇 `.exe`。
6. 顯示「正在啟動遊戲…」。
7. Cyder 啟動 Wine 後結束；遊戲持續執行。

### 流程 B：啟動前調整設定

1. 開啟 Cyder。
2. 點齒輪、`⌘,` 或 Dock「進階設定…」。
3. 在 sidebar 選擇頁面並調整。
4. 每次變更先驗證，再立即寫入 `settings.json`；底部顯示「已儲存」。
5. 關閉設定視窗回到主視窗。
6. 選擇 `.exe`。
7. 啟動器將 JSON 中的環境設定套入 process，並在啟動前同步必要 registry。

### 流程 C：遊戲相容性除錯

1. 遊戲出現黑屏或 resize 黑屏。
2. 進入「圖形」，將呈現器改成「GDI 相容模式」。
3. 介面提示畫質／效能代價，使用者確認。
4. 重新啟動遊戲。
5. 若無改善，按「恢復此頁預設值」回到自動。

### 流程 D：恢復預設

1. 點「全部恢復預設值」。
2. 對話框列出影響：顯示、字體、鍵盤、圖形、MSync；不刪除引擎、遊戲或最近項目。
3. 使用者確認。
4. 重建預設 JSON 並同步 registry。
5. 顯示「已恢復；下次啟動遊戲時生效」。

### 流程 E：套用失敗

1. JSON 可儲存但 Wine registry command 失敗。
2. 保留上一次成功套用的 registry 狀態，設定標記為 pending。
3. 顯示：「設定已儲存，但暫時無法套用。Cyder 將在下次啟動時重試。」
4. 提供「重試」與「查看記錄」。
5. 記錄寫入 `~/Library/Application Support/Cyder/Logs/settings.log`，不得包含使用者文件內容。

## 8. 設定資料模型

建議位置：

`~/Library/Application Support/Cyder/settings.json`

```json
{
  "schemaVersion": 1,
  "performance": {
    "msync": true
  },
  "display": {
    "retinaMode": true,
    "dpi": 192
  },
  "fonts": {
    "replacementPreset": "cyder-zh-tw",
    "smoothing": "cleartype-rgb",
    "gamma": 1400
  },
  "keyboard": {
    "preset": "mac",
    "command": "control",
    "option": "alt",
    "control": "control"
  },
  "direct3d": {
    "renderer": "auto",
    "videoMemoryMB": "auto"
  }
}
```

規則：

- 以 temporary file + atomic replace 儲存，避免突然終止造成 JSON 損壞。
- schema 不認識時保留原檔並回退安全預設，不直接覆寫。
- 環境變數在每次 launch 時套用；registry 在設定變更或 launch 前同步。
- `renderer=auto` 代表刪除 registry override，不是寫入字串 `auto`。
- 所有 registry 操作集中在單一 helper，避免 Swift 各頁自行組 shell command。

## 9. 技術拆分

### Swift / AppKit

- 將目前單檔 `cyder_app_main.swift` 拆為 AppDelegate、MainWindow、SettingsWindow、SettingsStore、LauncherService。
- 建立標準 main menu 與 `⌘,` action。
- 實作 `applicationDockMenu(_:)`。
- 把 `NSOpenPanel` 降為「選擇 .exe」動作，不再是唯一主介面。
- 啟動遊戲時把設定透過環境傳給 shell launcher。

### Shell / Wine

- 新增 `cyder-apply-settings.sh`，只接受明確參數或讀取已驗證 JSON，不接受任意 shell 字串。
- 擴充現有 `enable-mac-retina-hires.sh`，將 Retina、DPI、字體平滑拆開，不再綁成單一 on/off 組合。
- `cyder-common.sh` 不再硬編碼 `WINEMSYNC=1`，改讀 `CYDER_MSYNC`。
- 新增 Direct3D renderer 的 add/delete registry 操作。
- 鍵盤映射在確認 CX26 可用機制後才接入。

## 10. 分階段交付

### Phase 1：可用的設定中心

- 主視窗、齒輪入口、`⌘,`、Dock 右鍵。
- SettingsStore 與 JSON migration。
- MSync、Retina、DPI、字體平滑。
- 重置、錯誤狀態、settings log。
- 現有 launcher 測試全部維持通過。

### Phase 2：相容性工具

- Direct3D 自動 / OpenGL / GDI。
- 字體替代方案選擇。
- 最近使用項目。
- registry 讀回與 UI 狀態一致性檢查。

### Phase 3：鍵盤與 per-game 設定

- 驗證並實作 mac 修飾鍵映射。
- 導入獨立 bottle 或可靠的 per-game registry overlay。
- 全域預設 + 每遊戲覆寫。
- 引擎能力檢測後才開放 Vulkan / DXVK / VKD3D。

## 11. 驗收標準

- 三個入口都能開啟同一個非重複的設定視窗。
- 設定視窗可在未選 `.exe` 時使用。
- 關閉／重開 Cyder 後設定仍存在。
- MSync 開關能正確決定是否輸出 `WINEMSYNC=1`。
- Retina 與 DPI 可獨立設定，預設組合為 Retina + 192 DPI。
- 字體平滑四種 preset 能得到可預測 registry 值。
- Direct3D 自動會移除 override；GL/GDI 寫入正確值。
- 設定損壞、registry 寫入失敗、引擎未安裝時均不 crash。
- 遊戲執行中修改設定不影響該 process，UI 明確提示需重啟。
- 不支援的圖形或鍵盤能力不顯示為可用。

## 12. 目前程式需特別處理的風險

1. `cyder_app_main.swift` 現在只負責階段載入與檔案選擇，且 launch 後立即 `terminate`；加入主視窗後需重新整理生命週期。
2. `cyder-common.sh` 目前硬編碼 `WINEMSYNC=1`，若只做 UI 而不改 launcher，關閉開關不會生效。
3. 現有 Retina script 同時修改 Retina、DPI 與 FontSmoothing；新 UI 允許獨立調整，因此必須先拆解。
4. 共用 prefix 代表 registry 設定為全域；UI 必須誠實揭露。
5. Direct3D 的 GDI 是相容模式而非品質升級；文案不可誤導。
6. macOS 修飾鍵映射需先以實際 CX26 build 驗證，不應僅依 registry 名稱猜測。

