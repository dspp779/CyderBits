# 0.14.0-rc.1 打包與發佈準備紀錄

2026-10-03。已產生 Developer ID 簽章的本機候選版；**尚未公證，也尚未公開發佈**。

## 產物與來源

- 本機目錄：`dist/prerelease-0.14.0-rc.1/`，保留既有 `dist/Cyder.app`、`dist/Cyder-0.13.2.zip` 及正式安裝。
- App：`Cyder.app`，內部版本 `0.14.0`；預定發佈標籤 `v0.14.0-rc.1`。
- ZIP：`Cyder-0.14.0-rc.1-unnotarized.zip`，86,965,181 bytes，僅本機候選用途，不作公開下載。
- ZIP SHA-256：`479b548ef9c101998bb7470433fd3b921307ca1abd59df6519e58000ca70fd26`。
- App 產品來源：`a73e477e907d2937178614b0595cba8ee2f71cdb`。建置後修正發佈檢查並提交 `2192087b`；此修改不改變包內產品程式。
- 明確以 `--version 0.14.0` 覆寫建置版本；repo 預設版本檔仍為 `0.13.2`。
- 發佈說明：[v0.14.0-rc.1.md](v0.14.0-rc.1.md)。其他未提交研究文件、`.local` 與既有研究規劃未納入套件或本次提交。

## 建置及檢查

在 macOS 27.0.1（26A434）以正式 release builder、預設 `-O`、Developer ID 簽章建置 arm64 + x86_64。只對建置子程序指定系統 `/usr/bin/python3`，避免啟動目前不能執行的 x86 Homebrew Python。未重建或替換 Wine engine／graphics。

| 檢查 | 結果 |
|---|---|
| 引擎匯入驗證：封存、內嵌版本、NTDLL SHA-256 | 通過，仍為 Cyder012 |
| App 與解壓後 App strict/deep 簽章 | 通過 |
| 實際 App 的 arm64、x86_64 slice | 各自通過 |
| 正式 release wrapper 的版本／架構／簽章檢查 | 修正後通過；使用 `--skip-build --skip-notarize` |
| graphics 體積、非 symlink stub、必要檔案、engine label | 通過 |
| ZIP 體積與 0.13.2 基準比較 | 通過 |
| 解壓後 28 個附帶腳本、engine SHA-256 | 與來源／pin 一致 |
| DXVK 1.10.3、DXMT 0.80 封存 | 與正式 0.13.2 ZIP 中內容逐位元雜湊一致 |
| 套件憑證檔名檢查 | 無 `.p12`／`.p8`／`.key`／`.env`／SSH 私鑰檔名；不是完整秘密掃描證明 |
| 七項打包回歸 | 通過，見下方 |
| Apple 公證、stapler、Gatekeeper | 尚未執行；不列為通過 |
| 當前真實 Wine／NGS | 未驗證，系統 x86 執行失敗 |

`cyder-release-verify` 本次使用 `--skip-notarization-checks`；通過只涵蓋封裝檢查，不能當成完整發佈驗收。

七項回歸為 `test-release-cyder`、`test-release-cyder-contract`、`test-cyder-release-verify`、`test-import-engine-release`、`test-cyder-pack-no-gptk`、`test-cyder-pack-dxmt-gate`、`test-cyder-pack-graphics-payloads`。測試替身僅證明打包政策，不證明真實 Wine 相容性。

## 本次發現及修正

1. 原發佈檢查對 `lipo` 一次傳入兩個架構，在當前系統回報「requires exactly one input file」，即使實際 App 已含兩個 slice。改為逐一驗證，沒有略過任一架構。新增真實 Mach-O 回歸：雙架構通過、兩種單架構均拒絕、版本不符及 shell fallback 均拒絕。
2. DXMT 打包測試建立既有 `.tar.xz` fixture，卻依賴現已改為 zstd 的預設格式，意外走入完整 engine pack。明確傳入 `--xz`，恢復原先「引擎封存已存在仍需處理 graphics」的測試情境。
3. `build.log` 保留首次架構檢查失敗；`signed-app-verify.log` 是修正後成功結果。原始失敗測試記錄亦保留。Swift 編譯有既有的 weak capture／Sendable 警告，未將這次建置描述為零警告。

## 待完成的發佈步驟

自動核准審查拒絕送交 Apple 公證，理由是完整候選 App 會上傳給 Apple，而使用者「準備 pre-release」尚未明確授權該具體 payload 傳送。已提出授權確認；拒絕後沒有改用其他方法上傳。

取得明確傳送授權後，對上述已簽 App 執行 release wrapper 的 `--skip-build --version 0.14.0`，完成公證、staple 與完整 verify。另以 `dist/Cyder-0.13.2.zip` 明確執行 baseline 驗證，並對最後可下載 ZIP 重新計算雜湊；**不可沿用未公證 ZIP 或其雜湊**。

GitHub 目標為 draft + pre-release，標籤 `v0.14.0-rc.1`、不設 latest。尚未建立遠端 tag、GitHub draft 或上傳附件；沒有 push、merge 或公開發佈。後續上傳原始碼及公開發佈須遵循使用者授權，並選擇已完整公證驗收的最終附件。

原始建置、測試、payload verify、round-trip manifest、來源雜湊及本機 release-plan 均留在上述 gitignored 產物目錄。
