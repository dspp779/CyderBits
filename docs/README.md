# 文件索引

> 專案根目錄：[README.md](../README.md)（English · **CyderBits**）· [README.zh-TW.md](../README.zh-TW.md)（繁中）

**CyderBits** — DirectDraw / GDI 舊遊戲 on Mac；**Cyder** — 一鍵啟動 `.exe`；**CyderBits.app** — 包裝 `.exe` 為 game `.app`。

## 使用指南

| 文件 | 對象 | 內容 |
|------|------|------|
| [cyder.md](cyder.md) | 一般使用者 | Cyder 啟動器：開 `.exe`、SharedPrefix、bootstrap |
| [cyderbits.md](cyderbits.md) | 一般使用者 | CyderBits 打包器：建立 game `.app`、選項與疑難排解 |
| [bluecg.md](bluecg.md) | 開發 / 驗證 | BlueCG 自建 Wine、執行、高解析度與已知問題 |
| [scripts.md](scripts.md) | 開發者 | `scripts/` 腳本一覽與依賴關係 |

## 設計與計畫（superpowers）

歷史決策與細部規格，實作時以程式碼為準；若與腳本行為不一致，請更新對應文件。

| 文件 | 主題 |
|------|------|
| [superpowers/specs/2026-07-03-bluecg-wine-build-design.md](superpowers/specs/2026-07-03-bluecg-wine-build-design.md) | BlueCG 自建 Wine 總設計 |
| [superpowers/plans/2026-07-03-bluecg-wine-build.md](superpowers/plans/2026-07-03-bluecg-wine-build.md) | 實作計畫與任務 |
| [superpowers/specs/2026-07-04-bluecg-wine-build-plan-revision-design.md](superpowers/specs/2026-07-04-bluecg-wine-build-plan-revision-design.md) | 計畫修訂 |
| [superpowers/specs/2026-07-04-mac-retina-hires-design.md](superpowers/specs/2026-07-04-mac-retina-hires-design.md) | Mac Retina 高解析度 registry |
| [superpowers/specs/2026-07-04-portable-app-packaging-design.md](superpowers/specs/2026-07-04-portable-app-packaging-design.md) | 可攜 Wine / app 打包 |
| [superpowers/specs/2026-07-04-cyder-mvp-design.md](superpowers/specs/2026-07-04-cyder-mvp-design.md) | Cyder MVP 決策摘要 |

## 其他

- [../patches/README.md](../patches/README.md) — 選用 Wine 原始碼 patch
