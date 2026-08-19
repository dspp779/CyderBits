# Cyder 測試版／正式發佈版流程

端到端說明：**引擎 artifact → pin → 編譯 Cyder.app → 簽署 →（正式）公證**。  
簽署與公證的憑證細節見 [`release-signing.zh-TW.md`](release-signing.zh-TW.md)。  
引擎專案：[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)；邊界見 [`cyder-wine-engine-project.md`](cyder-wine-engine-project.md)。本 repo 是應用層。

一鍵腳本：

```bash
bash scripts/release-cyder.sh --channel test      # 本機／分支測試版
bash scripts/release-cyder.sh --channel release  # 正式發佈（含公證）
```

## 正式版 vs 測試／分支版

| | **測試／分支版** (`--channel test`) | **正式發佈版** (`--channel release`) |
|--|--|--|
| 用途 | 本機驗證、PR／功能分支、內測 | GitHub Release／對外下載 |
| Engine | 可用 `--engine-archive` 指向 rc／本機 pack；可不改 pin | **必須**有 pinned archive（`config/cyder-engine-archive.txt`）或顯式傳入已驗證的 release tarball |
| `SIGN_IDENTITY` | 預設 `-`（adhoc） | Developer ID + secure timestamp |
| 公證 | 不做 | `notarytool` → `stapler` → **再**壓發佈 zip |
| 預設 App 版本 | `0.11.1-dev`（可用 `--version` 改） | `0.11.1`（必須是乾淨 semver；來源為 `config/cyder-app-version.txt`） |
| Gatekeeper | 可能需右鍵「打開」 | `spctl` 顯示 Notarized Developer ID |
| 可否當公開下載 | **否** | **是**（staple 後的 `Cyder.app.zip`） |

「分支版」與測試版同一通道：功能分支產物用 `test`，不要用正式憑證簽完卻略過公證就外傳。

半套狀態最危險：**Developer ID 已簽、未公證** — 使用者仍可能被 Gatekeeper 擋住，且看起來「像正式檔」。正式通道請跑完公證，或明確只用 `test`。

## 端到端總覽

```text
cyder-wine-engine                 Cyder (本專案)
─────────────────                 ────────────────────────────
pack-engine-artifact.sh  ──►  import-engine-release.sh --apply
(minOS / DXVK / codesign)         (驗證 digest + 更新 pin)
                                         │
                                         ▼
                              release-cyder.sh --channel …
                                         │
                    test ──► dist/Cyder.app (adhoc)
                    release ──► 公證 + staple + dist/Cyder.app.zip
```

## 引擎準備（兩個通道都建議做對）

在 **`cyder-wine-engine`**：

```bash
# 見該 repo docs/incremental-build-and-patches.md
CYDER_ENGINE_VERSION_LABEL='CX26.3.0-W11-Cyder009-rc1' \
SIGN_IDENTITY='Developer ID Application: …' \   # 正式引擎建議 Developer ID
  bash scripts/pack-engine-artifact.sh --xz --force
```

在 **本專案** 匯入並 pin（正式發佈前必做）：

```bash
bash scripts/import-engine-release.sh \
  --manifest /path/to/engine-….tar.xz.manifest.json \
  --apply
```

只驗證不寫入 pin：省略 `--apply`。

### MapleStory OEM25（已退役）

CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

研究紀錄見 [OEM CX25 修補總覽](games/maplestory/oem-cx25-maplestory-patches.md)。

## 測試／分支通道

```bash
# 預設 adhoc、版本 0.11.1-dev、使用 pinned 或 create-cyder-app 預設引擎尋找邏輯
bash scripts/release-cyder.sh --channel test

# 指定本機 rc 引擎與版本字串
bash scripts/release-cyder.sh --channel test \
  --version 0.11.1-branch-foo \
  --engine-archive /path/to/engine-wine-x86_64-….tar.xz

# 測試通道若需暫時用 Developer ID 簽（仍不公證）:
bash scripts/release-cyder.sh --channel test \
  --sign-identity 'Developer ID Application: …'
```

測試通道**預設強制 adhoc**，不會繼承 shell 裡殘留的 `SIGN_IDENTITY`。

等價手做：

```bash
SIGN_IDENTITY=- CYDER_APP_VERSION=0.11.1-dev \
  bash scripts/create-cyder-app.sh
```

產出：`dist/Cyder.app`。**不要**對測試版跑公證當正式檔發佈。

## 正式通道

事前：本機已有 Developer ID（keychain）與 `notarytool` profile `cyder-notary`。
憑證檔建議放在 gitignored 的 `auth/` 與 `.env`（鍵名見 `.env.example`）；細節見
[`release-signing.zh-TW.md`](release-signing.zh-TW.md)。

```bash
# 完整：建置 + Developer ID + 公證 + staple + Cyder.app.zip
bash scripts/release-cyder.sh --channel release --version 0.11.1

# 已有簽好的 App，只做公證／staple／zip
bash scripts/release-cyder.sh --channel release --skip-build

# 只要簽章、稍後再公證
bash scripts/release-cyder.sh --channel release --skip-notarize
```

腳本會：

1. 確認 keychain 有 Developer ID（拒絕 `SIGN_IDENTITY=-`）
2. 確認 pinned engine 存在（或使用 `--engine-archive`）
3. 呼叫 `create-cyder-app.sh`
4. 確認版本字串、Universal native `CyderSwift`，再執行 `codesign --verify --deep --strict`
5. `ditto` → `notarytool submit --wait` → `stapler staple` → 再 `ditto` 出 `dist/Cyder.app.zip`
6. `spctl -a -vv`

上傳 GitHub Release 的是 **staple 之後** 的 `Cyder.app.zip`，不是送審用的 `Cyder-notarize.zip`。

## 發佈前檢查清單

- [ ] Engine：不含 `lib/dxvk`、`lib/dxvk2`、`lib/dxmt`；圖形 payload 位於 App `Resources/graphics`
- [ ] Engine：host Mach-O minos ≤ 10.15
- [ ] `import-engine-release` 通過；`config/cyder-engine-version.txt` 與預期 label 一致  
- [ ] App 版本字串正確（正式勿帶 `-dev`／誤用未宣告的 rc 當 GA）  
- [ ] `codesign --verify --deep --strict`  
- [ ] （正式）`stapler validate` 與 `spctl` → Notarized Developer ID  
- [ ] 本機 smoke：啟動 `.exe`、必要時看 `last-launch.log`
- [ ] Release notes：引擎 label、archive SHA-256、已知限制  

## MapleStory OEM25（已退役）

CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

研究紀錄見 [OEM CX25 修補總覽](games/maplestory/oem-cx25-maplestory-patches.md)。

## 相關文件

| 文件 | 內容 |
|------|------|
| [`release-signing.zh-TW.md`](release-signing.zh-TW.md) | Developer ID 匯入、notary profile、手做公證指令 |
| [`cyder-wine-engine-project.md`](cyder-wine-engine-project.md) | 引擎 pin／manifest 契約 |
| `cyder-wine-engine` `docs/incremental-build-and-patches.md` | 引擎 incremental／pack 閘門 |
| [`scripts.md`](scripts.md) | 腳本索引 |
