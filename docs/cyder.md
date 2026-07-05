# Cyder 使用指南

**Cyder** 是 Windows `.exe` 一鍵啟動器：裝一次，直接執行任何 `.exe`，共用全機唯一的 Wine prefix（`SharedPrefix`）。若要包成獨立的 macOS 遊戲 `.app`，請改用 [CyderBits 打包器](cyderbits.md)。

## 安裝 Cyder.app

需先在本機建好 Wine：

```bash
bash scripts/build-wine.sh
bash scripts/sign-wine.sh
bash scripts/create-cyder-app.sh
open dist/Cyder.app
```

`create-cyder-app.sh` 會：

- 將 relocatable Wine 打包進 `Cyder.app/Contents/Resources/engine-payload/`
- 使用 `logo/cyderbits.png` 產生 app 圖示
- 內含 shell launcher（`cyder_launcher.sh`）與 bootstrap helper（mono、tar、locale、hi-res）
- 在 `Info.plist` 註冊 `.exe` 檔案關聯（開啟、拖放）

## 開啟 .exe

| 方式 | 操作 |
|------|------|
| **雙擊 Cyder** | 無參數時會跳出檔案選擇器，選取 `.exe` |
| **拖放** | 將 `.exe` 拖到 Cyder.app 圖示上 |
| **檔案關聯** | 在 Finder 對 `.exe` 按右鍵 → **打開方式** → 選 Cyder；可設為預設 |

首次執行某 `.exe` 時會自動 bootstrap 共用 prefix（見下節），之後再開其他 `.exe` 不會重複安裝。

### CLI（開發 / 除錯）

```bash
bash scripts/cyder_launcher.sh --engine-src install/wine-x86_64 /path/to/game.exe

# 只印出路徑，不裝引擎、不啟動
bash scripts/cyder_launcher.sh /path/to/game.exe --dry-run

# 只跑 bootstrap（mono、tar、高解析度）
bash scripts/cyder_launcher.sh --bootstrap-only --engine-src install/wine-x86_64
```

（`python3 scripts/cyder_launcher.py` 仍可用，會轉呼叫上述 shell 腳本。）

## SharedPrefix 與 bootstrap

Cyder 使用**全機唯一**的 Wine prefix，所有 `.exe` 共用同一套 Windows 環境：

```text
~/Library/Application Support/Cyder/
  Engines/wine-x86_64/       # 共用 Wine（Cyder / CyderBits 預設）
  SharedPrefix/              # Cyder WINEPREFIX
    drive_c/windows/mono/    # wine-mono（.NET）
    drive_c/windows/syswow64/tar.exe   # GnuWin bsdtar（大 zip 解壓）
    system.reg / user.reg
    .cyder-bootstrap-v1      # bootstrap 完成 marker
  Addons/
    libarchive-2.4.12/       # tar 安裝來源（LGPL）
```

首次啟動（或 marker 不存在）時，`cyder_launcher.sh` 會依序：

1. 從 app 內 `engine-payload` 安裝引擎至 `Engines/`（若尚未安裝）
2. 若 `SharedPrefix/system.reg` 不存在 → `wineboot -u` 建立 prefix
3. 安裝 **wine-mono**、**syswow64/tar.exe**（含 libarchive DLL）
4. 寫入 **Mac 高解析度** registry（RetinaMode + LogPixels=192）
5. 設定 `WINEDLLOVERRIDES=mshtml=`（略過 Gecko 提示）
6. 寫入 `.cyder-bootstrap-v1`；之後啟動跳過上述步驟

執行時環境：

- `WINEPREFIX` = `SharedPrefix`
- `cwd` = `.exe` 所在目錄
- `LANG` / `LC_ALL` = macOS `AppleLocale` → fallback `zh_TW.UTF-8`
- `WINEMSYNC=1`

遊戲檔**不會**被複製或移動，仍留在原路徑。

## BlueCG 注意事項

BlueCG（魔力寶貝）可透過 Cyder 直接開 `BlueLauncher.exe`；遊戲目錄（如 `BlueCrossgateNew/`）維持原位，Wine 環境來自 `SharedPrefix`。

- 大客戶端 zip（`BlueCG_client.zip`）需要 prefix 內的 `syswow64/tar.exe`；bootstrap 會自動安裝。
- **共用 prefix 風險**：不同遊戲的 registry、已安裝元件可能互相影響。若某遊戲在 Cyder 下異常，可改用 [CyderBits](cyderbits.md) 建立**獨立 bottle** 的 game `.app`。
- 開發測試路徑 `bash scripts/run-bluecg.sh`（獨立 `WINEPREFIX`）**不受 Cyder 影響**，仍建議用於建置驗證。

詳見 [bluecg.md](bluecg.md)。

## 疑難排解

| 現象 | 建議 |
|------|------|
| 中文輸入變 `??` | 確認系統語言為繁中；Cyder 會讀 `AppleLocale` |
| 畫面糊 / 視窗太小 | bootstrap 已啟用高解析度；可對 SharedPrefix 執行 `bash scripts/enable-mac-retina-hires.sh` |
| 大 zip 解壓失敗 / 找不到 tar | 確認 `SharedPrefix/drive_c/windows/syswow64/tar.exe` 存在；刪除 `.cyder-bootstrap-v1` 後重開 Cyder 觸發 reinstall，或執行 `--bootstrap-only` |
| 找不到 Wine | 重新開啟 Cyder.app 以安裝共用引擎到 `Engines/` |
| Gecko 安裝提示 | Cyder 預設已停用 mshtml；若仍出現，對 SharedPrefix 執行 `bash scripts/configure-mshtml.sh --disable` |
| 多遊戲衝突 / registry 混亂 | 改用 [CyderBits](cyderbits.md) 為該遊戲建立獨立 bottle 的 game `.app` |
| Dock 圖示 | Cyder 啟動 Wine 程序後即結束；Dock 上顯示的是 Wine / 遊戲視窗 |

## 相關文件

- [cyderbits.md](cyderbits.md) — 打包 `.exe` 為 game `.app`（CyderBits）
- [bluecg.md](bluecg.md) — BlueCG 開發與驗證
- [scripts.md](scripts.md) — 腳本參考
- [superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md](superpowers/specs/2026-07-05-cyder-cyderbits-split-design.md) — 產品分流設計
