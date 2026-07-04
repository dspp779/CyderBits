# Cyder MVP

> **產品名**：Cyder（Old Game on Mac）  
> **日期**：2026-07-04  

## 決策

| 項目 | 選擇 |
|------|------|
| Windows 檔 | 預設**連結原路徑**；可選 standalone 複製進 app |
| Wine 引擎 | 預設**共用**（`~/Library/Application Support/Cyder/Engines/`）；可選可攜完整包 |
| Prefix | 預設**獨立 bottle**；進階 **game_dir 當 prefix**（BlueCG 模式） |
| 實作 | 最快 MVP：Python + osascript + `.app` |

## 使用

```bash
# 建立 Cyder 主程式
bash scripts/create-cyder-app.sh
open dist/Cyder.app

# 或 CLI
python3 scripts/cyder_create_game_app.py --gui
python3 scripts/cyder_create_game_app.py --exe /path/to/game.exe --output ~/Desktop
python3 scripts/cyder_create_game_app.py --exe ... --standalone --portable-engine
python3 scripts/cyder_create_game_app.py --exe ... --prefix-mode game_dir
```

## 流程

1. 開啟 Cyder.app → 選 `.exe` → 選輸出資料夾  
2. 以 osascript 對話框依序詢問：standalone / portable engine / game_dir prefix / no gecko / **Mac 高解析度（預設是）**  
3. 首次會把引擎安裝到 `Application Support/Cyder/Engines/wine-x86_64`  
4. 建立 `遊戲名.app`（內含 `meta.json` + 啟動器）  
5. 雙擊遊戲 app → 用共用（或內嵌）Wine 啟動（預設 `WINEMSYNC=1`）  

## 佈局

```text
~/Library/Application Support/Cyder/
  Engines/wine-x86_64/     # 共用 relocatable Wine
  Bottles/<id>/            # 每遊戲獨立 prefix（bottle 模式）

Desktop/MyGame.app/
  Contents/MacOS/CyderGame
  Contents/Resources/meta.json
  Contents/Resources/game/     # 僅 standalone
  Contents/Resources/wine/     # 僅 portable-engine
```
