# Graphics 簽章政策與正式打包

本功能接續 [DXMT 來源調查](dxmt-winemetal-signing-audit.zh-TW.md)，實作 Issue #12 的診斷分類與 DXMT 正式發佈政策。原有其他未提交工作不由此功能取代。

## 現有版本的精確診斷例外

Cyder runtime 的 Ruby 診斷器只為以下組合允許 `upstream-unsigned`：DXMT package `0.80`、`x86_64-unix/winemetal.so`、Mach-O x86_64，以及已從官方 archive 核對的完整 SHA-256 `3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca`。清單也綁定官方 v0.80 URL 與原始 archive digest。清單本身仍須由正式 App 的發行者與資源簽章建立信任；安裝目錄 marker 不提供信任。

這個例外只表示「已確認的上游未簽原件，符合本次精確政策」，UI 會明示，而不稱作損壞。其他路徑、版本、架構、hash、來源或不明未簽檔不能套用；內容變更仍優先回報 `content_mismatch`。新正式 App 建置不接受這個 legacy 例外替代已簽 package。

結果分開記錄內容與簽章：`content=match` 可與 `signature=unsigned` 同時存在；一般未簽 Mach-O 為 `signature_unsigned`，損壞為 `signature_invalid`，簽署者／必要時間戳不符為 `signature_policy_mismatch`，無法驗證為 `unknown`。PE 仍不要求 Mach-O 簽章或 Authenticode。

## 正式 DXMT package

實際簽署／graphics pack 的 canonical 實作位於 **cyder-wine-engine**。CyderBits 的 `scripts/graphics-signing.py` 是相同版本的建置時消費端驗證器，不安裝到 App 作為使用者端修復工具。更新 schema／規則時應同步兩份工具並跑兩邊測試。

目前只支援已稽核的 DXMT upstream **v0.80**。工具記錄官方 archive SHA-256，並固定其中全部 11 個上游檔案的 digest；正式打包須逐一符合。只允許額外的 Cyder `LICENSE`／`version` 資料。未知版本、額外 PE／Mach-O、被改動的 DLL 或已自行補簽的輸入都停止，等待明確來源／簽署政策審核；不覆寫其他上游／Apple 簽章。

操作次序：

1. 從原始已驗證 DXMT 樹複製 staging，保持來源／install tree 不變。
2. 只在 staging 對已稽核、原本未簽的 `winemetal.so` 使用 Cyder Developer ID Application 與安全時間戳。無 adhoc fallback，不複製 Wine loader entitlement 到 library。
3. 驗證 Apple Developer ID 憑證種類、Team `3U9565WWM2`、時間戳，以及綁定元件／revision 的 `local.cyder.dxmt.<package-version>.winemetal` signing identifier，記錄原始／最終 digest、來源與 package revision 至 `cyder-graphics-provenance.json`。
4. 建立 archive，再在隔離目錄安全解壓並驗證整份檔案集合、內容與簽章。拒絕越界、連結、重複與超出大小預算的 member；驗證流程不呼叫簽署。
5. 驗證成功才以不覆寫方式發布 archive，再原子更新 checksum／version sidecar。若中斷導致 sidecar 不一致，消費端應失敗，重跑同一有效 package 可重建 sidecar；不可將不一致當作成功。
6. Cyder App 建置再次驗證實際 archive，產生對應**最終簽署後內容**的逐檔 manifest。簽署後 package 的 runtime 診斷要求預期 Team 與時間戳。正式 release 驗收也重驗 native payload；略過公證檢查不會略過此項。

新內容必須用 `0.80-cyder.N` package revision（N 為正整數），保留 provenance 裡的 upstream v0.80。即使 `--force`，既有正式 DXMT archive 也只可驗證後重用，不能覆寫或重新簽成不同位元組。快取來源／內容不同或驗章失敗時停止並使用新 revision。此政策目前針對 DXMT；不宣稱整個 Wine runtime 的版本不可變政策已全部完成。

範例（在引擎 repo，**只有使用者要求產生正式包時才實際執行**）：

```bash
export OGOM="$PWD"
export SIGN_IDENTITY='Developer ID Application: …'
export CYDER_GRAPHICS_PACKAGE_REVISION=cyder.1 # changed content must use an unused N
bash scripts/pack-graphics-payloads.sh --engine "$WINE_INSTALL" \
  --channel release --revision "$CYDER_GRAPHICS_PACKAGE_REVISION"
```

對 Developer ID 的 engine pack，`pack-engine-artifact.sh` 會傳遞 release 模式並要求 revision。預設的 test graphics pack 保留原有行為，不冒充正式簽署包。

把 engine manifest 匯入 CyderBits 後，另設定 `CYDER_GRAPHICS_ARTIFACTS_DIR` 指向引擎 repo 的 `dist/artifacts/graphics`。匯入 engine 不等於匯入獨立 graphics。`release-cyder.sh` 傳遞通道；直接以 Developer ID 呼叫 `create-cyder-app.sh` 也會啟用正式 graphics gate。

## 回歸與驗收邊界

```bash
python3 tests/test-graphics-signing.py
/usr/bin/ruby tests/test-cyder-component-integrity.rb # CyderBits
bash tests/test-cyder-component-diagnostics.sh       # CyderBits
bash tests/test-cyder-release-verify.sh              # CyderBits
bash tests/test-graphics-release-pack.sh              # engine repo
bash tests/test-pack-graphics-payloads.sh             # engine repo
bash tests/test-pack-engine-dxmt-gate.sh              # engine repo
```

簽署 fixtures 明確使用隔離的假簽署器／信任回覆；驗證參數、staging 隔離、來源 pin、hash、順序、錯誤 Team／時間戳、篡改、封存往返、重複打包、不可覆寫快取與失敗不降級，不使用私鑰。這不能取代真正 Developer ID 簽署後的封存往返、公證／Gatekeeper、Intel／Apple Silicon DXMT 載入、遊戲退出與防毒環境驗收。

本次沒有實際產生新的 Developer ID package、沒有公證／發布、沒有變更使用者已安裝的元件。所有 runtime 診斷保持唯讀；其結果不會觸發補簽、下載、修復或更動 registry。

### 本次驗證紀錄（2026-10-30）

- Ruby 元件／來源／政策／正式建置 gate：22 cases、114 assertions 通過。
- Python 簽署／provenance／安全解壓：8 cases 通過（CyderBits 與 engine 兩端）。
- 引擎端既有 graphics pack、engine graphics gate，以及新增 release staging／快取不可覆寫／test namespace 保護：通過。
- Cyder release wrapper／contract、元件 hook、graphics 安裝、App payload、滾輪啟動回歸：通過。
- AppKit 背景、取消、重啟、deadline、輸出限制及「上游原件未簽署」顯示：通過；x86_64 / macOS 11 typecheck 通過。
- `engine-release-pack`、`cyder-release`、`cyder-release-verify` 三份技能通過官方 `quick_validate.py`。
- 重新讀取官方已固定 SHA-256 的 archive，全部 11 個上游成員 digest 與生產政策表相符。實際 legacy DXMT 副本得到內容相符、unsigned、精確政策 allowed，沒有變更位元組。

以上未執行真實 Developer ID 新簽署；相關正向簽署測試使用 fixture，正式證書／公證／遊戲／防毒仍依前述條件實機驗收。

後續已真正產生 Developer ID DXMT 與 Cyder 本機測試包，完成 native／App／ZIP 往返驗章與隔離診斷；結果見 [2026-10-30 實際建置紀錄](build-records/dxmt-developer-id-test-20261030.md)。沒有公證或發布，遊戲與防毒實機驗收仍待使用者執行。

再後續的 [DXMT 0.80 同版更新政策](dxmt-digest-update.zh-TW.md) 已將顯示版號與內部封存識別分離：顯示維持 0.80，更新以 digest／簽章政策判斷，使用中或驗證不明時延後。該文記錄新測試版與離線驗收範圍；先前紀錄的 suffix 是內部封存追溯資訊。
