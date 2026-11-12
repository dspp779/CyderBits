# Cyder 測試版／正式發佈版流程

端到端說明：**引擎 artifact → pin → 編譯 Cyder.app → 簽署 →（正式）公證**。  
簽署與公證的憑證細節見 [`release-signing.zh-TW.md`](release-signing.zh-TW.md)。  
引擎專案：[cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine)；邊界見 [`cyder-wine-engine-project.md`](cyder-wine-engine-project.md)。本 repo 是應用層。

## Agent skills

正式發佈請優先載入這些 skills（勿略過 verify）：

| Skill | 路徑 | 用途 |
|-------|------|------|
| **cyder-release** | `.agents/skills/cyder-release/` | 編排：engine pack → import → `release-cyder.sh --channel release` → verify |
| **cyder-release-verify** | `.agents/skills/cyder-release-verify/` | 強制驗收（graphics 體積／非 symlink、zip vs baseline、spctl／stapler） |
| **cyder-dev-test** | `.agents/skills/cyder-dev-test/` | 日常開發：`tests/run.sh`、測試版建置、實機點選與遊戲驗證（見 [`development-testing.md`](development-testing.md)） |
| **engine-release-pack** | `cyder-wine-engine/.agents/skills/engine-release-pack/` | Developer ID 引擎 + 真實 graphics pack（禁 symlink 來源） |

`release-cyder.sh --channel release` 在 staple／寫出 `Cyder.app.zip` 與 `Cyder-<version>.zip` 後會**自動**跑 verify（可用 `RELEASE_SKIP_VERIFY=1` 緊急略過，正式出貨勿用）。失敗則停止、勿發佈 zip。

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
| 預設 App 版本 | `config/cyder-app-version.txt` 加 `-dev`（可用 `--version` 改） | `config/cyder-app-version.txt`（必須是乾淨 semver） |
| Gatekeeper | 可能需右鍵「打開」 | `spctl` 顯示 Notarized Developer ID |
| 可否當公開下載 | **否** | **是**（staple 後的 `Cyder-<version>.zip`；另寫 `Cyder.app.zip`） |

「分支版」與測試版同一通道：功能分支產物用 `test`，不要用正式憑證簽完卻略過公證就外傳。

半套狀態最危險：**Developer ID 已簽、未公證** — 使用者仍可能被 Gatekeeper 擋住，且看起來「像正式檔」。正式通道請跑完公證，或明確只用 `test`。

## 何時簽署、何時公證

| 目的 | 簽署 | 公證 | 指令 |
|------|------|------|------|
| 只看視窗、設定、提示文字 | adhoc | 否 | `release-cyder.sh --channel test` |
| 要在本機**實際啟動遊戲** | Developer ID | 否 | `release-cyder.sh --channel test --sign-identity "Developer ID Application"` |
| 任何會離開本機的檔案（內測、GitHub Release） | Developer ID | 是（含 staple） | `release-cyder.sh --channel release` |

- adhoc 測試版**無法啟動遊戲**：DXMT 更新只接受能驗證為 Cyder Developer ID 簽署的 App，啟動會停在圖形準備（`CYD-WIN-001`，記錄為 `{"status":"deferred","reason":"publisher_unverified"}`）。這是設計，不要為了測試放寬檢查。
- Developer ID 測試版同樣需要圖形目錄內有 Developer ID 簽署的 `dxmt-0.80.tar.zst`。
- 公證只做在最終候選版：公證後只要 App、engine pin 或圖形 payload 有任何變動，就必須整包重建、重新公證，並更新發佈說明內的 zip 大小與 SHA-256。只改文件（發佈說明、CHANGELOG）不影響 zip。
- 測試版請輸出到 `dist/` 以外（`--out-dir`），`dist/Cyder.app` 保留給最近一次正式建置。
- `xcode-select` 指向 Command Line Tools 時無法連結 Universal `CyderSwift` 的 Intel 部分；建置指令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（不需更改 `xcode-select`）。

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
                    release ──► 公證 + staple + dist/Cyder.app.zip + Cyder-<ver>.zip
```

## 引擎準備（兩個通道都建議做對）

在 **`cyder-wine-engine`**：

```bash
# 見該 repo docs/incremental-build-and-patches.md
# 正式引擎必須以 Developer ID 簽署
export SIGN_IDENTITY='Developer ID Application: …'
CYDER_ENGINE_VERSION_LABEL="$(head -n 1 config/engine-version.txt)" bash scripts/pack-engine-artifact.sh --zst
```

在 **本專案** 匯入並 pin（正式發佈前必做）：

```bash
bash scripts/import-engine-release.sh \
  --manifest /path/to/engine-….tar.zst.manifest.json \
  --apply
```

只驗證不寫入 pin：省略 `--apply`。

### MapleStory OEM25（已退役）

CX25 OEM 產品線與 `--cx 25` 建置已退役。現行路徑是正式 Cyder.app + CX26。本文保留為研究紀錄。

研究紀錄見 [OEM CX25 修補總覽](games/maplestory/oem-cx25-maplestory-patches.md)。

## 測試／分支通道

```bash
# 預設 adhoc、版本為 config/cyder-app-version.txt 加上 -dev、使用 pinned 或 create-cyder-app 預設引擎尋找邏輯
bash scripts/release-cyder.sh --channel test

# 指定本機 rc 引擎與版本字串
bash scripts/release-cyder.sh --channel test \
  --version <版本>-branch-foo \
  --engine-archive /path/to/engine-….tar.zst

# 測試通道若需暫時用 Developer ID 簽（仍不公證）:
bash scripts/release-cyder.sh --channel test \
  --sign-identity 'Developer ID Application: …'
```

測試通道**預設強制 adhoc**，不會繼承 shell 裡殘留的 `SIGN_IDENTITY`。

等價手做：

```bash
SIGN_IDENTITY=- CYDER_APP_VERSION=<版本>-dev \
  bash scripts/create-cyder-app.sh
```

產出：`dist/Cyder.app`。**不要**對測試版跑公證當正式檔發佈。

## 正式通道

事前：本機已有 Developer ID（keychain）與 `notarytool` profile `cyder-notary`。
憑證檔建議放在 gitignored 的 `auth/` 與 `.env`（鍵名見 `.env.example`）；細節見
[`release-signing.zh-TW.md`](release-signing.zh-TW.md)。

```bash
# 完整：建置 + Developer ID + 公證 + staple + Cyder.app.zip + Cyder-<version>.zip
bash scripts/release-cyder.sh --channel release --version <版本>

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
5. `ditto` → `notarytool submit --wait` → `stapler staple` → 再 `ditto` 出 `dist/Cyder.app.zip`，並複製為 `dist/Cyder-<version>.zip`
6. `spctl -a -vv`，再跑 `cyder-release-verify`（baseline 排除當次版本檔）

上傳 GitHub Release 的是 **staple 之後** 的 `Cyder-<version>.zip`（與 `Cyder.app.zip` 內容相同），不是送審用的 `Cyder-notarize.zip`。

### 發佈到 GitHub

打 tag、push 與建立 Release 都是對外動作，需使用者明確要求才進行：

1. 發佈說明、`CHANGELOG.md`、`docs/README.md` 已填入最終 zip 的大小與 SHA-256；由最終 zip 重新產生 `dist/SHA256SUMS.txt`。
2. 兩個 repo 合併到 `main` 並 push；在 Cyderbits `main` 打 `vX.Y.Z` tag（說明中的版本比較連結要有 tag 才有效）。
3. 先用 `gh release view vX.Y.Z` 檢查是否已有舊 Draft：舊 Draft 可能帶著過期的 zip 或指向舊 commit，須換成 `Cyder-<version>.zip` 與 `SHA256SUMS.txt`。
4. Release 內文使用繁中發佈說明，最上方加下載段落（沿用上一版格式），並連到英文版。
5. 發佈後從 GitHub 把 zip 下載回來執行 `shasum -a 256 -c`，並開啟英文說明與版本比較連結確認。

## 發佈前檢查清單

- [ ] `bash tests/run.sh` 全數通過
- [ ] Engine：不含 `lib/dxvk`、`lib/dxvk2`、`lib/dxmt`；圖形 payload 位於 App `Resources/graphics`
- [ ] 圖形目錄只有要出貨的檔案：`dxvk-1.10.3.tar.zst` 與 Developer ID 簽署的 `dxmt-0.80.tar.zst`；不含 `dxvk2-*`、舊的未簽署 DXMT 或 `cyder.N` 檔（App 會打包該目錄的所有封存檔）
- [ ] DXVK 2 在通過遊戲實測前不出貨（`create-cyder-app.sh` 與 verify 會拒絕）
- [ ] Engine：host Mach-O minos ≤ 10.15（版本化的 MoltenVK real 例外，上限 12.0）。0.14／Cyder013 是最後支援 macOS 10.15／11 的版本，其 MoltenVK 1.2.10 沿用 Cyder012 的 10.15 建置；之後的版本僅支援 macOS 12+
- [ ] `import-engine-release` 通過；`config/cyder-engine-version.txt` 與預期 label 一致  
- [ ] App 版本字串正確（正式勿帶 `-dev`／誤用未宣告的 rc 當 GA）  
- [ ] `codesign --verify --deep --strict`  
- [ ] （正式）`stapler validate` 與 `spctl` → Notarized Developer ID  
- [ ] 本機 smoke：以 Developer ID 簽署的同一份程式碼實際啟動至少一款遊戲，檢查 `last-launch.log` 沒有 `diagnostic event=error`；未做則在發佈說明的已知問題中寫明「未經遊戲實測」
- [ ] （正式）產出 `dist/Cyder-<version>.zip`（與 `Cyder.app.zip` 相同內容）  
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
| [`development-testing.md`](development-testing.md) | 測試套件、測試版建置、實機與遊戲驗證 |
| [`release-notes-guide.md`](release-notes-guide.md) | 發佈說明與 CHANGELOG 的撰寫格式 |
