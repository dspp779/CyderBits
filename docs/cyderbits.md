# CyderBits 打包器使用指南

**CyderBits.app** 把 Windows `.exe` 包成可雙擊的 macOS `.app`，可自訂 bottle、是否內嵌引擎、是否複製遊戲檔等。Phase 1 仍使用 `~/Library/Application Support/Cyder/Bottles/<uuid>/` 作為預設 prefix。

若只需快速執行 `.exe`、不需產生 game app，請改用 [Cyder 啟動器](cyder.md)。

## 安裝 CyderBits.app

需先在本機建好 Wine：

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
bash scripts/create-cyderbits-app.sh
open dist/CyderBits.app
```

`create-cyderbits-app.sh` 會：

- 將 relocatable Wine 打包進 `CyderBits.app/Contents/Resources/engine-payload/`
- 使用 `logo/cyderbits-logo.png` 產生 app 圖示
- 內含 `cyder_create_game_app.py` 與 helper 腳本

## 建立遊戲 App

### GUI（CyderBits.app）

1. 雙擊 **CyderBits.app**
2. 選擇 `.exe` 與輸出資料夾
3. 依序回答 osascript 對話框：
   - 複製遊戲檔進 App？（預設 **否**＝連結原路徑）
   - 內嵌完整 Wine 引擎？（預設 **否**＝共用引擎）
   - 遊戲目錄當 Wine prefix？（預設 **否**＝獨立 bottle；**BlueCG 請選是**）
   - 停用 mshtml？（預設 **否**）
   - 啟用 Mac 高解析度？（預設 **是**：RetinaMode + 200% DPI）
4. 完成後 Finder 會顯示新建的 `遊戲名.app`

### CLI

```bash
python3 scripts/cyder_create_game_app.py --gui

python3 scripts/cyder_create_game_app.py \
  --exe /path/to/game.exe \
  --output ~/Desktop

# BlueCG 範例
python3 scripts/cyder_create_game_app.py \
  --exe "$PWD/BlueCrossgateNew/BlueLauncher.exe" \
  --output ~/Desktop \
  --prefix-mode game_dir \
  --no-gecko-prompt
```

### CLI 旗標

| 旗標 | 說明 |
|------|------|
| `--standalone` | 複製整個遊戲目錄進 app |
| `--portable-engine` | 內嵌完整 Wine 於 app（可攜） |
| `--prefix-mode bottle` | 預設：乾淨 prefix 於 `Application Support/Cyder/Bottles/<uuid>/` |
| `--prefix-mode game_dir` | 遊戲目錄即 WINEPREFIX（BlueCG） |
| `--no-gecko-prompt` | `WINEDLLOVERRIDES=mshtml=` |
| `--no-mac-hires` | 不寫入 RetinaMode / LogPixels=192 |
| `--no-msync` | 不設 `WINEMSYNC=1` |
| `--engine-src DIR` | Wine 安裝來源（預設 `install/wine-x86_64`） |

## 執行時行為

雙擊遊戲 `.app` 時：

- **語系**：`LC_ALL` → macOS `AppleLocale` → `LANG` → fallback `zh_TW.UTF-8`（見 `scripts/resolve-wine-locale.sh`）
- **msync**：預設 `WINEMSYNC=1`
- **Dock**：包裝 app 設 `LSUIElement`（不佔 Dock）；Wine 顯示 EXE 圖示
- **圖示**：從 EXE 資源擷取最大 icon 轉為 `AppIcon.icns`

## 檔案佈局

```text
~/Library/Application Support/Cyder/
  Engines/wine-x86_64/       # 首次建立遊戲時從 engine-payload 安裝
  Bottles/<id>/              # bottle 模式的 prefix（Phase 1 預設）

MyGame.app/
  Contents/MacOS/CyderGame   # 啟動器（agent，啟動後結束）
  Contents/Resources/
    meta.json                # 遊戲路徑、prefix、bottle_id、選項
    AppIcon.icns             # 來自 EXE
    game/                    # 僅 --standalone
    wine/                    # 僅 --portable-engine
```

### meta.json 範例

```json
{
  "name": "BlueLauncher",
  "exe": "/path/to/BlueLauncher.exe",
  "prefix_mode": "game_dir",
  "mac_hires": true,
  "msync": true,
  "no_gecko_prompt": true
}
```

## 疑難排解

| 現象 | 建議 |
|------|------|
| 中文輸入變 `??` | 確認系統語言為繁中；重建 app（會讀 `AppleLocale`）。舊 app 需重建以更新啟動器 |
| 畫面糊 / 視窗太小 | 建立時啟用高解析度，或對 prefix 執行 `bash scripts/enable-mac-retina-hires.sh` |
| BlueCG 無法啟動 | 使用 `--prefix-mode game_dir`，並 `--no-gecko-prompt` |
| Dock 兩個圖示 / 跳動 | 重建 app（新版啟動器已 detach Wine） |
| 找不到 Wine | 重新開啟 CyderBits.app 以安裝共用引擎到 Application Support |
| Gecko 安裝提示 | 建立時選停用 mshtml，或 `bash scripts/configure-mshtml.sh --disable` |
| Bottle 佔用過多空間 | 刪除 app 不會刪 bottle；可手動清理 `~/Library/Application Support/Cyder/Bottles/` |

## 相關文件

- [cyder.md](cyder.md) — Cyder 一鍵啟動 `.exe`（共用 SharedPrefix）
- [bluecg.md](bluecg.md) — BlueCG 專用設定
- [scripts.md](scripts.md) — 腳本參考
- [superpowers/specs/2026-07-04-cyder-mvp-design.md](superpowers/specs/2026-07-04-cyder-mvp-design.md) — MVP 決策紀錄
- [superpowers/specs/2026-07-06-wine-engine-slim-design.md](superpowers/specs/2026-07-06-wine-engine-slim-design.md) — **未來：** Wine Engine 瘦身
