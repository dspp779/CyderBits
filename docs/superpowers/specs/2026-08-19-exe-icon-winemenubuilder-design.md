# Cyder 遊戲庫 EXE 圖示：winemenubuilder `.lnk`（方案 A）

日期：2026-08-19  
狀態：設計已核准（方案 A；實驗通過）  
範圍：Cyder.app 遊戲庫磁貼圖示。**不改** Wine engine、**不改** Dock 上遊戲行程圖示。

相關：

- 現況：`scripts/cyder_game_icon.swift` 呼叫 `/usr/bin/python3` + `cyder_create_game_app.py --extract-icon-stdin`
- 已知 Python 失敗例：`docs/releases/v0.5.0.en.md`（皮卡丘排球、帝國時代、大富翁 4）
- 實驗：`dist/皮卡丘打排球.exe`（2026-08-19）
- 上游未合入：GitLab MR [6489](https://gitlab.winehq.org/wine/wine/-/merge_requests/6489)、[6555](https://gitlab.winehq.org/wine/wine/-/merge_requests/6555)（作者關閉；diff 有 `PathFind*` 誤 `heap_free`，不可 cherry-pick）

## 目標

1. 遊戲庫圖示抽取**不再呼叫** `/usr/bin/python3`（避免未裝 Command Line Tools 的使用者跳出系統對話框）。
2. 用與 CrossOver 相同的 Wine 路徑抽圖：`winemenubuilder` 的 `open_icon` / `write_native_icon`，經現有 `-t`（只吃 `.lnk`）。
3. 加入遊戲後**不擋 UI**：先占位圖，背景完成後換成 cache PNG。
4. 失敗時維持中性 SF Symbol，**不**退回 macOS 通用 `.exe` 文件圖示。

## 非目標

- 不改 `winemac.drv` Dock 圖示（遊戲 `wine game.exe` 時已由 macdrv `set_app_icon` 處理）。
- 不 patch `winemenubuilder` 讓 `-t` 直接吃 `.exe`（上游方案 C 未合入；6489 不可用）。
- 不新增 `extract-icon.exe` helper PE（方案 B）。
- 本版不升級 48×48 磁貼解析度（見「已知限制」）。
- 不實作 security-scoped bookmark 持久化（既有缺口；本版用暫存拷貝彌補）。
- 不把 CyderBits / `exe_to_icns` 打包器一併改完（可仍用 Python，直到 CyderBits bash 化另開工作）。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 演算法 | 暫存 `.lnk` + `wine winemenubuilder.exe -t <unix.lnk> <unix.png>` |
| 建捷徑 | prefix 內 `cscript` + `WScript.Shell.CreateShortcut`（實驗已過） |
| 路徑 | **Unix 路徑**；Windows `C:\…` 會讓 `wine_get_dos_file_name` 變成找不到檔 |
| Prefix | Cyder shared bottle（與啟動遊戲相同） |
| 何時抽 | NSOpenPanel／加入紀錄後立刻排背景 queue，不 `wait` 主執行緒 |
| TCC | 用已開啟的 `FileHandle` 把 EXE **串流拷到** Application Support 暫存，再讓 Wine 讀該拷貝；抽完刪 EXE+`.lnk`，只留 PNG |
| 呼叫端 | Swift `CyderGameIconStore` 改跑 bundled shell，不再跑 python |
| Engine | 不改 `cyder-wine-engine` |

## 實驗基線（皮卡丘排球）

同一檔 `dist/皮卡丘打排球.exe`（PE32 GUI，156672 bytes）：

| 方法 | 結果 |
|------|------|
| Python `extract_exe_ico` | 失敗。Optional header 的 resource `Size` 為 470872，大於檔案 |
| `winemenubuilder -t game.exe out.png` | `could not read .lnk, 0x80004005` |
| `cscript` 寫 `game.lnk`（Target=拷貝後的 `game.exe`），Unix 路徑 `-t` | 成功：48×48 PNG，綠底像素皮卡丘 |

## 架構

三個邊界清楚的單位：

1. **`CyderGameIconStore`（Swift）**  
   何時抽、cache 路徑 `Application Support/Cyder/game-icons/<id>.png`、占位圖、失敗集合。對 helper 只傳 `game-id`、來源 `FileHandle` 或已可讀路徑、輸出 PNG 路徑。

2. **`cyder-extract-exe-icon.sh`（bundled）**  
   唯一會呼叫 Wine 的地方。輸入：`WINEPREFIX`、`wine`/`wineserver`、暫存目錄、來源 EXE 位元組或路徑、輸出 PNG。步驟：寫入 `game.exe` → `make_lnk.js` / `cscript` → `winemenubuilder -t` → 檢查 PNG 非空 → 刪暫存 EXE/lnk/js。不解析 PE。

3. **Wine `winemenubuilder`（現成）**  
   讀 `.lnk` 目標、`LoadResource`、寫 PNG。Cyder 不 fork 其內部。

Cyder.app 啟動遊戲仍走既有 `cyder_run_wine_exe`；抽圖示是**另一次短命** `arch -x86_64 "$wine" …`，共用同一 prefix / wineserver。若遊戲已在跑，**不得**在抽完後 `wineserver -k`。

## 資料流

```text
加入遊戲 / 磁貼需要圖示
  → Swift 背景 queue（現有 utility queue）
  → 若 cache PNG 仍新於 EXE mtime：結束
  → 開啟來源 EXE（NSOpenPanel 當下務必開 FD）
  → 寫入 scratch/<id>/game.exe（從 FD 拷貝）
  → wine cscript 建立 scratch/game.lnk
  → wine winemenubuilder -t "$PWD/game.lnk" "$cache/<id>.png"
  → 刪 scratch/<id>/
  → 主執行緒重載 NSImage
```

Scratch 放在 `Application Support/Cyder/icon-extract/<id>/`，不要留在 `drive_c` 以免弄髒 bottle（實驗曾用 `drive_c/cyder-icon-a`，產品路徑改支援目錄；Wine 仍用 Unix 路徑即可，不必放進 `C:\`）。

超時：冷啟動 wineserver 可能超過舊的 15s Python 上限。產品預設 **45s**；超時殺掉的是 **這次 winemenubuilder/cscript 子行程**，不是整個 wineserver。

## 錯誤處理

- `cscript` 或 `-t` 非 0、沒有 PNG、PNG 不是有效影像：記 `extract-failed`，該 `game.id` 進 `failed`，占位圖保留。
- Prefix / engine 尚未 bootstrap：跳過抽取（與現在 helper 檔不存在相同），不彈 CLT 對話框。
- 來源開檔失敗：與現況相同，`source-open-failed`。
- 磁碟：scratch EXE 可能很大。必須在成功、失敗、超時的 `defer` 裡刪 scratch。不把整份遊戲永遠複製進 Application Support。

## 測試

- 單元／腳本：`tests/test-cyder-extract-exe-icon.sh`（名稱可微調）  
  - 對 `winemenubuilder -t` **直接 EXE** 斷言失敗（回歸 0x80004005）。  
  - 對暫存 `.lnk` + Unix `-t`：若存在 `dist/皮卡丘打排球.exe` 或小型 fixture，斷言產出非空 PNG。無 fixture 則 SKIP，不要硬依賴 Python。
- Swift／payload：`create-cyder-app.sh` 打包 `cyder-extract-exe-icon.sh`；`cyder_game_icon.swift` **不得**再出現 `/usr/bin/python3`。
- `test-exe-to-icns.sh` 若仍檢查 `--extract-icon-stdin`，改成只約束 CyderBits 打包器，或刪除「遊戲庫必須走 Python」的斷言。

## 已知限制

- `winemenubuilder` 對該實驗檔選了 **48×48**，磁貼會比 256 PNG 糊。本版接受；若要高解析再開工作（例如選更大 RT_ICON，或方案 B）。
- Wine 抽得到、Python 抽不到的檔（資源表 Size 謊報）是本版要修的；Wine 也抽不到的仍占位。
- 背景第一次抽會啟動 wineserver（prefix 沒在跑時），可能看到短暫 Wine helper；不為此改 engine。

## 實作順序

1. Shell helper + 以皮卡丘 EXE 為準的測試（有檔才跑完整抽取）。
2. Swift 改呼叫 helper；打包進 `ogom-scripts`；去掉遊戲庫的 python3。
3. 調整舊測試對 `--extract-icon-stdin` 的假設。
