# Cyder Wine Engine 專案拆分

## 第一階段狀態

Wine 引擎的 source preparation、patch、建置、runtime 測試、strip、簽署與 artifact
封裝已整理為獨立的 sibling 專案 `cyder-wine-engine`。Cyder 專案暫時保留原有建置腳本
作為相容副本，正式 App 也仍內嵌明確 pin 住的 engine artifact；本階段不加入執行期間
自動下載或「latest」更新。

責任邊界如下：

| `cyder-wine-engine` | Cyder／CyderBits |
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

目前 Cyder 仍 pin `CX26.3.0-W11-Cyder006`。獨立專案的下一個 release target 是
`CX26.3.0-W11-Cyder007`；完成簽署、封裝與遊戲 smoke test 後，才透過 importer 更新。

## 保留相容副本

第一階段不立即刪除 Cyder repository 的 `patches/`、`scripts/build-wine.sh` 與相關測試，
原因是既有 0.8.3 發布與本機增量 source tree 仍依賴這些路徑。新專案完成首次 release
並由 Cyder 成功匯入後，再進行第二階段：

1. 將 Cyder 內的建置腳本改為明確的 forwarding wrapper，或完全移除。
2. 將引擎專屬測試移出 Cyder CI。
3. Cyder CI 僅驗證 pinned manifest、artifact 與 App integration。
4. 以 release tag／digest 取代跨 repository branch 依賴。
