# Portable BlueCG.app packaging

> **日期**：2026-07-04  
> **狀態**：已實作腳本  

## 目標

產生可雙擊的 `BlueCG.app`，內含：

- 可搬移 Wine runtime（依賴 dylib 已內嵌，不需 `.brew-x86`）
- 遊戲 prefix（`BlueCrossgateNew`）
- 啟動 stub

## 腳本

| 腳本 | 作用 |
|------|------|
| `scripts/bundle-wine-dylibs.sh` | 從 `.brew-x86` 收集 dylib，複製到 `lib/wine/x86_64-unix/`，`install_name_tool` 改為 `@loader_path/` |
| `scripts/link-wine-runtime-libs.sh` | 同上（相容舊名稱） |
| `scripts/create-bluecg-app.sh` | 組裝 `dist/BlueCG.app` |

## 使用

```bash
cd /Users/jjc/ogom

# 開發：prefix 用 symlink，較快
bash scripts/create-bluecg-app.sh --link-prefix

# 發佈：完整複製 prefix（體積大）
bash scripts/create-bluecg-app.sh --output "$HOME/Desktop"

open dist/BlueCG.app
```

另一台 Mac：

1. 拷貝整個 `BlueCG.app`（路徑可不同；runtime 已 relocatable）
2. `xattr -cr BlueCG.app`
3. 必要時重新 ad-hoc 簽章（腳本結束時會印指令）
4. 需 Apple Silicon + Rosetta 2（或 Intel）

## App 結構

```text
BlueCG.app/Contents/
  MacOS/BlueCG              # 啟動器
  Info.plist
  Resources/
    wine/                   # install/wine-x86_64 副本（含內嵌 dylib）
    prefix/                 # BlueCrossgateNew
    entitlements.plist
```

## 限制

- 仍為 ad-hoc 簽章；給別人用可能需 Developer ID + 公證
- 尚未做成「任意 EXE → .app」精靈；目前固定 BlueCG / BlueLauncher
- 建立 app 時仍需本機 `.brew-x86` 作為 dylib **來源**；產出的 app **不再依賴** `.brew-x86`
