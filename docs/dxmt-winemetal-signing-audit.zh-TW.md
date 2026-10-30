# DXMT 0.80 winemetal.so 簽章來源調查

日期：2026-10-30。對應 Issue #12。此輪只下載官方來源至臨時目錄、讀取／比較檔案及檢視腳本；沒有建置、重新打包、codesign 簽署、修復、改動 runtime 或變更診斷政策。

## 結論

**上游官方發行檔原本就沒有簽章；Cyder 保留了相同位元組，沒有剝除簽章。獨立 graphics payload 的打包與驗證流程也沒有另外涵蓋這項原生元件的簽署。**

這兩件事同時成立，不能簡化成「Cyder 把簽章弄丟了」，也不能因為上游未簽署就認定 Cyder 正式發行不必制定自己的政策。現有程式沒有在 graphics pack 階段承諾或強制全部 Mach-O 已簽署；可確認的是覆蓋缺口，無法僅憑此證明某次發布曾執行簽署卻漏掉一個檔案。上游作者不簽署的具體動機尚無直接證據。

## 可重現證據

使用 `fetch-dxmt.sh` 固定的官方來源，重新下載而非只相信本機 version marker：

- [官方 DXMT v0.80 release](https://github.com/3Shain/dxmt/releases/tag/v0.80)
- [原始 builtin archive](https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz)
- 原始 archive SHA-256：`8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`，與 Cyder pin 相符。
- tar member：`v0.80/x86_64-unix/winemetal.so`。只讀取這個普通檔案，不執行上游二進位或安裝腳本。

| 階段 | 大小 | winemetal.so SHA-256 | LC_CODE_SIGNATURE |
|---|---:|---|---|
| 新下載的官方 archive | 31,805,040 bytes | `3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca` | 無 |
| Cyder 測試包內 dxmt-0.80.tar.zst 的解壓副本 | 同上 | 同上 | 無 |
| 本機已安裝 graphics/dxmt/0.80 | 同上 | 同上 | 無 |

對照的 Cyder graphics archive SHA-256：`5ff06f968609fbc9566b7cdbec7eb845b05bdb44bb1b0cfa5a0412e998a60723`。此證據只涵蓋這份 archive 與所列本機版本，不推論所有歷史附件都一樣。

Mach-O header 為 x86_64；解析所有 load commands 確認不存在 `LC_CODE_SIGNATURE`（0x1d）。系統 `codesign -dv` 與 `codesign --verify --strict` 皆回覆 `code object is not signed at all`。因此是「沒有嵌入簽章」，不是已存在的 CMS 失效、錯誤 Team ID 或有效簽章被沙箱誤判。SHA-256 全檔相符亦排除這三份檔案之間發生簽章移除或補簽。

## 流程追查

CyderBits 程式基準：`d4b710c9a4eecbd90101df9b445a5b592dcbe5ec`，加上本次尚未提交的 P0-02 診斷。引擎 repo HEAD 為 `86796814441200b27ed9d11ab39f293ab66cb7db`；該工作目錄已有其他未提交修改，本輪沒有改動。下列為工作目錄可觀察的流程，不用它冒充歷史發布時的完整執行紀錄。

1. [fetch-dxmt.sh](../scripts/fetch-dxmt.sh) 第 8–10 行固定 URL／checksum；第 224–256 行複製 payload、整理位置及寫入 license／來源資訊，沒有 codesign，也沒有移除 Mach-O signature 的步驟。
2. [pack-graphics-payloads.sh](../scripts/pack-graphics-payloads.sh) 第 70–100 行複製 DXMT 後直接 tar/zstd、產生 archive checksum；沒有簽署或逐 Mach-O signature gate。只有 DXVK 路徑另有 PE builtin 標記。
3. [pack-engine-artifact.sh](../scripts/pack-engine-artifact.sh) 第 112–119 行先建立獨立 graphics archive；第 136–143 行的 Wine staging 排除 `lib/dxmt`；第 159 行才簽署該 Wine staging。因此 Wine 的簽署與 archive 解壓驗章沒有覆蓋先前獨立封存的 DXMT。引擎 repo 對應腳本亦保留這個順序與排除路徑。
4. [create-cyder-app.sh](../scripts/create-cyder-app.sh) 複製已封存的 graphics archive，再依 `file` 格式簽署 App 內實體 Mach-O。`.tar.zst` 此時是資源檔，這段流程不解壓其內容來簽署 `winemetal.so`。App resource seal 可以綁定 archive 位元組，不能替 archive 內的原生 library 產生自己的 code signature。
5. [cyder-ensure-graphics.sh](../scripts/cyder-ensure-graphics.sh) 安裝時驗 archive checksum、解壓、建立 current／engine 連結及部署 PE DLL，沒有 DXMT 原生元件的補簽。原有 Wine 入口簽章快篩也不是這個獨立 payload 的完整驗證。

P0-02 目前為所有 Mach-O 指定 `verify`，因此此檔案會得到 `signature_invalid` 並附 `signature_not_present`。這是保守政策下的不符合，**不能描述為內容損壞或防毒刪除**。先前完整性文件中的觀察已由本調查補足來源證據；本輪尚未把這個政策改成例外。

## 政策評估與建議

| 選項 | 適用性與代價 | 建議 |
|---|---|---|
| 保留上游未簽原件，建立精確例外 | 可保留逐位元組來源比對；須由可信 manifest 明確綁定上游版本／archive digest／相對路徑／檔案 digest，並另顯示「上游原件未簽署」。不能讓此檔取得 macOS 簽署者身分，也不保證載入／Gatekeeper／防毒行為 | 適合作為既有版本的明確、受限過渡政策；不可一律允許所有未簽 Mach-O |
| 正式發行時，對這個未簽原生元件建立 Cyder 簽署衍生產物 | 在受控 staging、壓縮前以 Developer ID 與安全時間戳簽署；分別保留原始與最終 digest、簽署者與加工來源。需測試 library 載入、架構／minOS、封存往返及安裝後驗章 | **未來 Cyder 正式重散布的優先方向**；屬 P1-02 發佈政策工作，不是使用者端自動修復 |
| 安裝或每次啟動時自動 adhoc 補簽 | 改變已發布的檔案 digest，不能建立可信發行者身分；增加可變內容與防毒調查歧義 | 不建議作為正式版修正 |

建議採用的實作次序（此次僅評估）：

1. 先讓診斷資料模型分開表達「內容符合／不符」、「未簽／簽章無效／無法驗證」與「政策允許／不允許」。既有來源已證實的未簽原件不應被籠統稱為損壞；未知、修改過、其他路徑或版本不得套用相同例外。
2. 在 **cyder-wine-engine 的 graphics 發佈 staging** 定義元件政策：這個原本未簽、由 Cyder 重新散布的 Mach-O 可建立 Cyder Developer ID 衍生包；已由上游／Apple 有效簽署的其他元件另按允許的發行者保留與驗證，避免批次覆寫。
3. 順序為：驗上游 pin → 保存原始 hash／狀態 → 受控加工與簽署 → 驗最終 Team／時間戳／內容 → 封存 → 解壓往返再驗 → 產生最終 manifest → App 封裝。App manifest 必須對應**簽署後**位元組。不要讓發行者身分或必要時間戳缺失時默默退回 adhoc。
4. 變更簽章會改變內容，應給 graphics **新的 Cyder package revision／digest**，保留 DXMT upstream v0.80 身分。不要就地覆寫同名 `dxmt-0.80.tar.zst`、沿用成功 marker 或讓既有檔案快取掩蓋新舊差異。
5. 不直接把 Wine loader 的整套寬鬆 entitlement 套到 library；先記錄實際需求。Library Validation 預設限制 Apple／同 Team library，但 Wine 目前的例外與載入需求須個別驗證，不能因此直接移除例外。

Apple 建議逐層由內而外簽署：[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)。Library Validation 的預設來源限制與停用例外說明見 [Apple entitlement 文件](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.disable-library-validation)。這些是 macOS 信任政策，不是 PE Authenticode，也不能當作 Bitdefender 誤報已解決。

## 後續驗收條件

- 來源／診斷 fixtures：精確上游未簽、未知未簽、原先已簽而簽章無效、錯誤 Team、缺必要時間戳、內容改變、信任服務不可用分別得到正確結果；PE 不套用 Mach-O 規則。
- 發佈 fixtures：簽署先於封存／manifest；封存及安裝後內容和簽章一致；正式缺憑證／驗章失敗直接停止；重複打包不誤用舊 archive；同版本新 package revision 不混用。
- 實機：正式 Developer ID 包在支援 macOS／Wine 組合的 DXMT 載入、代表遊戲、正常退出與重啟；另測防護開啟的 Bitdefender 環境。不要以 hash 相同或 codesign 通過取代這些結果。

本輪不新增上述政策、例外或測試功能；既有未提交的 P0-02 實作及其他修改均保留。


後續依此評估完成程式與技能更新，詳見 [Graphics 簽章政策與正式打包](graphics-signing-policy.zh-TW.md)。本調查的三份原始位元組證據保持有效，未對已安裝檔案補簽。
