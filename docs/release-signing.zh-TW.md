# Cyder 發佈版建置、簽章與公證指南

這份指南說明如何在自己的 Mac 上完成 **正式發佈通道** 的 Developer ID 簽章與
Apple 公證(notarization),讓使用者下載後不會再看到 Gatekeeper 的「無法驗證開發者」警告。

**測試版 vs 正式版的差異、引擎 pin、以及一鍵腳本** 見總流程：
[`release-pipeline.zh-TW.md`](release-pipeline.zh-TW.md)
（`bash scripts/release-cyder.sh --channel test|release`）。

發佈需要兩個條件,缺一不可:

1. **Developer ID 簽章** — 證明「是誰簽的」
2. **Apple 公證** — Apple 的自動惡意軟體掃描,通過後發出票據(ticket)

## 事前準備

- macOS 13 以上,並安裝 Xcode Command Line Tools:`xcode-select --install`
- 本 repo 的 clone
- 引擎 tarball(見下方「取得引擎檔案」)
- 簽章／公證材料（見下一節；**勿提交進 git**）

### 本機憑證擺放（建議）

本專案約定把敏感檔放在 **gitignored** 的路徑（見 `.gitignore` 的 `auth/`、`.env`）：

| 路徑 | 內容 |
|------|------|
| `auth/cert.p12`（或團隊提供的 `.p12`） | Developer ID 憑證＋私鑰 |
| `auth/AuthKey_XXXXXXXX.p8` | App Store Connect API 金鑰 |
| `.env` | 密碼與 Key／Issuer ID（僅本機） |

`.env` 建議鍵名（範例見 `.env.example`）：

```bash
CYDER_P12_PASSWORD=…          # 匯入 .p12 用
CYDER_Key_ID=…                # App Store Connect Key ID
CYDER_Issuer_ID=…             # App Store Connect Issuer ID
```

向團隊索取時仍須走密碼管理器等安全管道；clone 後把檔案放到上述位置即可。
`scripts/release-cyder.sh --channel release` 預設使用 keychain 內的
Developer ID 與 notary profile `cyder-notary`（見下方一次性設定）。

## 一次性設定(只需做一次)

### 1. 匯入簽章憑證

若 keychain 尚無 Developer ID（`security find-identity -v -p codesigning` 看不到），從本機檔匯入：

```bash
set -a && source .env && set +a
security import auth/cert.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$CYDER_P12_PASSWORD" -T /usr/bin/codesign
```

（若檔名不是 `cert.p12`，改成實際路徑。）

確認匯入成功:

```bash
security find-identity -v -p codesigning
```

輸出必須包含這一行(建置腳本預設使用這個身分):

```
Developer ID Application: <developer_id_application>
```

> 第一次執行 codesign 時,macOS 可能跳出鑰匙圈存取的詢問視窗 —
> 輸入登入密碼後選「**永遠允許**」,之後就不會再問。

### 2. 儲存公證憑證

若尚未建立 `cyder-notary` profile：

```bash
set -a && source .env && set +a
xcrun notarytool store-credentials cyder-notary \
  --key auth/AuthKey_*.p8 \
  --key-id "$CYDER_Key_ID" \
  --issuer "$CYDER_Issuer_ID"
```

（`--key` 請改成實際的 `auth/AuthKey_….p8` 路徑；shell glob 僅在單一符合時可用。）

之後所有公證指令都用 `--keychain-profile cyder-notary`,不需要 Apple ID 密碼。
可用 `xcrun notarytool history --keychain-profile cyder-notary` 確認 profile 可用。

### 3. 取得引擎檔案

建置腳本會依 `config/cyder-engine-archive.txt` 尋找已打包好的引擎 tarball（目前為
`dist/artifacts/engine-releases/engine-wine-x86_64-CX26-3-0-W11-Cyder007.tar.xz`）。
`dist/` 不在版本控制內,所以 clone 後不會有這個檔案 — 向 團隊成員 拿到 tarball 後放到上述路徑,
或建置時用 `--engine-archive /path/to/engine.tar.xz` 指定。

## 每次發佈流程

建議用一鍵腳本（會做建置、簽署、公證、staple、發佈 zip）：

```bash
bash scripts/release-cyder.sh --channel release --version 0.9.0
```

或手做下列步驟。

### 1. 建置並簽章 Cyder.app

```bash
bash scripts/create-cyder-app.sh
```

腳本預設就會用 Developer ID 簽章(含 hardened runtime 與安全時間戳,簽章時需要網路)。
若只想做本機測試用的未簽章版本:`SIGN_IDENTITY=- bash scripts/create-cyder-app.sh`。
（測試／正式通道差異見 [`release-pipeline.zh-TW.md`](release-pipeline.zh-TW.md)。）

若需要重新打包引擎(而不是用現成 tarball),打包時也要帶上簽章身分,
讓 tarball 內的所有 Mach-O 都有 Developer ID 簽章:

```bash
SIGN_IDENTITY="Developer ID Application: <developer_id_application>" \
  bash scripts/pack-engine-artifact.sh
```

### 2. 驗證簽章

```bash
codesign --verify --deep --strict --verbose=2 dist/Cyder.app
```

### 3. 送交 Apple 公證

```bash
ditto -c -k --keepParent dist/Cyder.app dist/Cyder-notarize.zip
xcrun notarytool submit dist/Cyder-notarize.zip \
  --keychain-profile cyder-notary --wait
```

`--wait` 會等 Apple 掃描完成(通常 2–5 分鐘,大檔案第一次可能到 15 分鐘),
結果必須是 `status: Accepted`。

若結果是 `Invalid`,查逐檔原因:

```bash
xcrun notarytool log <submission-id> --keychain-profile cyder-notary
```

最常見的原因是某個 Mach-O 沒簽到,或簽章缺少時間戳。

### 4. 裝訂公證票據(staple)

```bash
xcrun stapler staple dist/Cyder.app
xcrun stapler validate dist/Cyder.app
```

裝訂後即使使用者離線,Gatekeeper 也能驗證通過。

### 5. 重新壓縮成發佈檔

```bash
ditto -c -k --keepParent dist/Cyder.app dist/Cyder.app.zip
```

兩個重點:

- **一定要在 staple 之後重新壓縮** — 送公證的那個 zip 裡沒有票據,不能直接拿去發佈。
- **一定要用 `ditto`,不要用 `zip -r`** — `ditto` 才會保留簽章需要的延伸屬性。

這個 `Cyder.app.zip` 就是上傳到 GitHub Release 的檔案。

### 6. 最終檢查

```bash
spctl -a -vv dist/Cyder.app
```

預期輸出包含 `accepted` 與 `source=Notarized Developer ID` —
看到這行,代表使用者下載解壓後可以直接打開,不會被 Gatekeeper 擋下。

## MapleStory OEM flavor 公證

OEM 版 (`Cyder-maplestory-oem25.app`) 與正式版使用相同的 Developer ID 簽章與 `cyder-notary` 設定，但建置腳本不同：

```bash
bash scripts/create-cyder-maplestory-oem-app.sh
```

產出為 `dist/Cyder-maplestory-oem25.app`（預設版本字串 `0.8.2-maplestory-oem25`）。公證步驟與正式版相同，僅替換 App 名稱：

```bash
codesign --verify --deep --strict --verbose=2 dist/Cyder-maplestory-oem25.app

ditto -c -k --keepParent dist/Cyder-maplestory-oem25.app dist/Cyder-maplestory-oem25-notarize.zip
xcrun notarytool submit dist/Cyder-maplestory-oem25-notarize.zip \
  --keychain-profile cyder-notary --wait

xcrun stapler staple dist/Cyder-maplestory-oem25.app
xcrun stapler validate dist/Cyder-maplestory-oem25.app

ditto -c -k --keepParent dist/Cyder-maplestory-oem25.app dist/Cyder-maplestory-oem25-0.8.2.zip
```

**0.8.0 起 engine 內建 DXVK，但不含 Apple GPTK** — 公證前請確認打包後的 engine 沒有 `lib64/apple_gptk` 或評估 DMG 內容被打進 App；GPTK 僅能由使用者本機 CrossOver 或偏好設定從官方評估卷安裝。兩套 App（正式版與 OEM）皆需各自送公證並 staple 後再壓 zip 發佈。

OEM 最終檢查：

```bash
spctl -a -vv dist/Cyder-maplestory-oem25.app
```

## 疑難排解

| 狀況 | 處理方式 |
|---|---|
| `codesign` 卡住不動 | 鑰匙圈跳窗被背景程序擋住 — 打開「鑰匙圈存取」解鎖 login keychain,重跑並點「永遠允許」 |
| `timestamp service is not available` | 簽章時連不上 Apple 時間戳伺服器 — 確認網路後重試 |
| `notarytool` 回報 `Invalid` | 用上面的 `notarytool log` 指令看逐檔原因 |
| `spctl` 顯示 `rejected` | 通常是漏了 staple,或 zip 是在 staple 之前壓的 — 重做步驟 4、5 |
| 建置時 `Missing pinned Cyder engine` | 引擎 tarball 不在 `config/cyder-engine-archive.txt` 指定的路徑 — 見「取得引擎檔案」 |

## 安全注意事項

- `.p12` 等同於整個團隊的簽章身分 — 持有者簽出來的軟體都掛名
  「<developer_id_application>」。請存放在密碼管理器,絕對不要提交進 repo。
- 若裝置遺失或懷疑外洩,立刻通知 團隊成員 到 Apple Developer 網站撤銷憑證
  (已公證發佈的舊版本不受影響,票據仍然有效)。
- `.p8` API 金鑰可隨時在 App Store Connect 撤銷重發。
