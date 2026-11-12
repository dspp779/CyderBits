# Cyder Wine Engine 專案拆分

公開 repo：[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)。  
本 repo（CyderBits）目前主要是**應用層**（啟動器、遊戲庫、設定、CompatDB、打包）；實際執行 Windows `.exe` 的核心在該引擎專案。

## 第一階段狀態

Wine 引擎的 source preparation、patch、建置、runtime 測試、strip、簽署與 artifact
封裝已整理為獨立專案 [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)。Cyder 專案暫時保留原有建置腳本
作為相容副本，正式 App 也仍內嵌明確 pin 住的 engine artifact；本階段不加入執行期間
自動下載或「latest」更新。

責任邊界如下：

| Wine 核心（[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)） | 應用層（CyderBits） |
|---|---|
| CrossOver source 與工具鏈準備 | App UI、遊戲庫與偏好設定 |
| Wine patch set 與套用順序 | Prefix 建立與生命週期 |
| Wine、MoltenVK、media runtime 建置 | Sync、圖形後端與 CompatDB policy |
| NTDLL 與 artifact 回歸測試 | Engine 安裝、選擇與啟動 |
| Engine strip、Developer ID 簽署與封裝 | Cyder.app 簽署、公證與發布 |
| Engine manifest 與不可變 release | 指定 release 的驗證與內嵌 |

## Manifest 契約

新引擎 archive 內含 `wine-x86_64/engine-manifest.json`，發布目錄另有
`<archive>.manifest.json` sidecar。Sidecar 記錄：

- schema 與 engine ID；
- CrossOver／Wine 基線；
- engine version；
- Windows／host architecture；
- 最低 Cyder 版本；
- ordered patch set；
- NTDLL SHA-256；
- archive 名稱與 SHA-256。

Cyder 的 [`scripts/import-engine-release.sh`](../scripts/import-engine-release.sh) 預設只驗證；
只有明確傳入 `--apply` 才會複製 artifact 並更新：

- `config/cyder-engine-version.txt`
- `config/cyder-engine-archive.txt`
- `config/cyder-engine-manifest.json`

驗證包含 sidecar schema、archive digest、archive 內的 `version`、embedded manifest，以及
實際解出的 `ntdll.dll` digest。任一項不一致即停止，不會部分更新 pin。

目前 pin 的引擎版本記錄在 `config/cyder-engine-version.txt`（Cyder 0.14.0 為
`CX26.3.0-W11-Cyder013`）；各版本對應的引擎見 [CHANGELOG](../CHANGELOG.md)。對外發布前
仍必須完成 Developer ID 簽章、公證與遊戲 smoke test
（見 [`release-pipeline.zh-TW.md`](release-pipeline.zh-TW.md)）。

## 保留相容副本

Cyder repository 仍保留 `patches/`、`scripts/build-wine.sh` 等建置腳本與相關測試的
相容副本，但它們不是正式流程：引擎一律在 cyder-wine-engine 建置與打包。本 checkout 的
`build/`、`install/`、`.brew-x86`、`tools/archives` 是指向引擎 checkout 的連結。
尚未進行的整理：

1. 將 Cyder 內的建置腳本改為明確的 forwarding wrapper，或完全移除。
2. 將引擎專屬測試移出 Cyder CI。
3. Cyder CI 僅驗證 pinned manifest、artifact 與 App integration。
4. 以 release tag／digest 取代跨 repository branch 依賴。

## 相關文件

- [引擎、圖形轉譯層與 Runtime 載入](cyder-graphics-runtime-pipeline.zh-TW.md) — engine tar 與 graphics payload 如何分開安裝、再在啟動時接線
- [DXVK 編譯備忘](build-dxvk.zh-TW.md)
