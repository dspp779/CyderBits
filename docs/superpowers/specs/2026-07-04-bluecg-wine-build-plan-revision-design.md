# BlueCG Wine Build Plan Revision Design

> **日期**：2026-07-04  
> **狀態**：已核准並套用至 plan  
> **目標**：完善 `docs/superpowers/plans/2026-07-03-bluecg-wine-build.md`，對齊專案現況與執行風險

## 決策

| 項目 | 選擇 |
|------|------|
| Git | Task 0：`git init`，之後各 Task 照常 commit |
| 索引 | 保留 `sources/wine/`；其餘大目錄已由 `.cursorignore` 排除 |
| Homebrew | 專案內 `.brew-x86`；先 bootstrap 本體，再 `brew install` |
| 既有檔案 | 不覆寫 `.cursorignore` / `.vscode/` 的索引排除規則 |

## Task 結構

0. `git init` + 擴充 `.gitignore` + 初始 commit（僅 docs / 設定）
1. `env-x86_64.sh` + tests（確認既有 ignore，必要時微調 `.gitignore`）
2. `build-wine.sh`：bootstrap Homebrew → 依賴 → configure/make/install（**不改源碼**）
3. `sign-wine.sh`
4. `run-bluecg.sh`
5. `verify-bluecg.sh` + 失敗診斷

## macOS workarounds（僅文件記錄，不實作成 script）

先前原生 build 經驗，**不寫入建置腳本**。建置錯誤時再對照 plan 文件，決定套用 W1 / W2 / W3 的任意組合（一個、兩個或三個）。

| ID | 檔案 | 變更 |
|----|------|------|
| W1 | `dlls/win32u/vulkan.c` | `SONAME_LIBVULKAN` → `"libMoltenVK.dylib"` |
| W2 | `dlls/winemac.drv/cocoa_window.m` | `WineMetalLayer` → `CAMetalLayer` |
| W3 | `dlls/winemac.drv/event.c` | 刪除 `macdrv_client_surface_presented` |

規則：

1. 預設乾淨 build；先試正解，workaround 是最後手段
2. 可依錯誤選用任意子集；套用前記錄用了哪些 ID
3. 改源碼前手動備份或依賴 tarball 還原
4. 實驗結束後從 `crossover-sources-26.2.0.tar.gz` 還原被改過的檔案，再重編與重簽

## 初始 commit 範圍

- 納入：`docs/superpowers/`、`.gitignore`、`.cursorignore`、`.vscode/`
- 排除：`BlueCrossgateNew/`、`sources/`、`llvm-mingw-*/`、壓縮包、二進位、建置產物
