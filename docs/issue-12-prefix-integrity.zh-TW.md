# Issue #12：PE 證據與 prefix 完整性補強（2026-11-02）

基準為 CyderBits main `1d8fdb3`（含 `f5eba09`），本次修改於隔離工作目錄；未更動原工作目錄、正式 runtime、prefix、遊戲或反作弊檔案。沒有執行 Wine、簽署、打包、發布、上傳樣本或變更防毒設定。

## P0-01：已有具體案例，產物身分仍未閉合

來源：[mapledan 2026-11-01 補充](https://github.com/dspp779/CyderBits/issues/12#issuecomment-6559333716)。這是回報者整理的 2026-08-25 紀錄，本次未在 Bitdefender 環境獨立重現。

| 回報架構 | 檔名 | 偵測名稱 |
|---|---|---|
| i386 | bcrypt.dll | Gen:Variant.Tedy.986656 |
| i386 | mspatcha.dll | Gen:Variant.Yogi.8485 |
| i386 | xinput9_1_0.dll | Gen:Variant.Yogi.8790 |
| i386 | control.exe | Gen:Heur.Honret.2 |
| x86_64 | ncrypt.dll | Gen:Variant.Yogi.41012 |
| x86_64 | msidb.exe | Gen:Variant.Yogi.45775 |
| x86_64 | rasapi32.dll | Gen:Variant.Yogi.46876 |
| x86_64 | wevtapi.dll | Gen:Variant.Yogi.38221 |

受影響為 Cyder 0.13.0／自建 CX26，同機 Cyder 0.10 OEM 引擎檔案未出現相同刪除。回報的 `bcrypt → crypt32 → wintrust` 載入鏈中斷與 `c0000135` 說明缺少依賴能導致反作弊啟動失敗；不是已確認的反作弊本身缺陷，也不是簽章因果證明。

另外，2026-08-09 OEM bottle 的 `winemapi.dll` 曾被刪除，偵測為 `Gen:Variant.Midie.186768`。不能把「OEM 引擎本身未被刪」擴大為「OEM bottle 所有檔案不受影響」。

P0-01 應從「沒有檔名／偵測名稱」更新為「案例部分可追溯」。仍缺被刪樣本 SHA-256、精確建置／archive digest、去識別化完整相對路徑、Bitdefender 產品／引擎／病毒碼版本、macOS 版本、隔離紀錄與各階段時間。Cyder011 封存大小／成員不符，不能把現有封存 hash 回填為被刪樣本 hash；回報架構與大小亦需由原紀錄再核對。

## 已核對的本機程式與檔案

- Wine source：`programs/wineboot/wineboot.c` 的 `update_wineprefix` 透過 `wine.inf` 與 SetupAPI 安裝；`dlls/setupapi/fakedll.c` 的 `read_file`／`install_fake_dll` 讀取 PE 並 `WriteFile` 寫入目的檔。一般 PE 路徑可形成相同內容的實體副本；亦有 fake／16-bit 特殊路徑，不能把所有 prefix 檔一律視為直接副本。
- Cyder 的 `cyder_bootstrap_prefix` 主要驗證 registry、kernel32 與基本狀態；`.cyder-bootstrap-v1` 記錄的是引擎版本，不是逐檔可信來源。版本 marker 不能證明 prefix DLL 未被刪或替換。
- 原 P0-02 的 runtime 清單與完整掃描正確驗證其宣告範圍，但不讀取 prefix 副本。啟動 quick 清單亦未涵蓋回報的多個 PE。因此「runtime 完整、prefix 缺失」可漏過。
- 本機唯讀比較：已安裝 runtime 標籤 `CX26.3.0-W11-Cyder012`，目前 shared prefix 為 win64。上述八個檔名加 crypt32、wintrust、winemapi，兩架構共 22 個 prefix 檔皆為實體檔，大小與 SHA-256 全部等同目前 runtime；引擎 repo 的開發 install 則是另一組內容。這直接支持必須使用發行清單，而不能用開發 install 作 prefix 基準。
- 例如目前 runtime／prefix 的 i386 bcrypt 為 114,688 bytes，SHA-256 `0e606354ff6e2bba32d6b98171aed4238b3e16daa091c9aa4fdd775fde2ba6c8`；x86_64 為 118,784 bytes，SHA-256 `45054b7ff82e7f1f697938dcfa00ad84e99620582c8341b819c5674adcc23a72`。這些是本機現在的觀察，**不是** mapledan 被刪檔案的身分證據。
- 本機這些檔案 PE certificate table 未見簽章資料。這只是結構觀察，不是 Authenticode 憑證鏈驗證；本次沒有宣稱重新驗證 OEM 的簽署者或覆蓋率。

## P0-02：最小修正與結果語義

沿用正式 App 發行者驗證、index／manifest digest、逐檔格式／架構／大小／SHA-256、deadline、取消與背景視窗。沒有新增 prefix 自製 checksum 作信任根，也沒有變更 manifest schema。

- runtime quick 額外選取上述 PE 與 ntdll／kernel32／kernelbase；即使既有已簽清單尚未更新 `critical` 欄位，也按固定名稱補入，仍以原可信清單的內容值驗證。
- CLI `check --bottle PATH` 可重複指定不同 prefix；不掃描未指定的 bottle。正式啟動 hook 傳入實際遊戲 prefix，背景視窗使用目前 `CyderPaths.sharedBottle`（含環境覆寫）；引擎安裝檢查不假設 prefix 已建立。
- prefix quick／full 都只檢查固定 14 個關鍵名稱在 engine manifest 中實際列出的普通 PE，不掃描全部 DLL 或遊戲資料夾。win64：x86_64→system32、i386→syswow64；win32：i386→system32。`system.reg` 的架構僅用於目錄映射，不作來源證明。
- 實體副本符合可信清單：`ok`（只證明內容等價）。缺少預期路徑：`missing`。不同內容的實體檔：`unknown / prefix_source_unverified`，可能是其他引擎版本／原生 DLL；版本 marker 不會把它升級為已知損壞。
- 符號連結只接受指向所選 engine 同一個清單項目的直接連結（絕對或相對路徑，支援選定 root 的 macOS 路徑別名），再用清單驗證實體目標。目標缺失為 `missing`，內容不符為 `content_mismatch`；其他來源、連結鏈、父目錄連結與特殊檔案保持 `unknown`，不跟隨任意連結讀取外部檔案。
- 架構不明、無可信清單、無法讀取、讀取中變更、逾時／取消均為 `unknown`。prefix 路徑在獨立 component 報告中顯示；UI 顯示來源不明的原因。診斷結果不自動認定防毒刪除，不阻擋啟動，不修復或執行 wineboot。

此修正仍不是實際 loader 追蹤：未覆蓋 DLL override、搜尋順序、其他安裝目錄、所有第三方／native DLL、記憶體或掃描後競態。清單沒有列出的名稱不會憑空產生內容基準；老版本只有部分關鍵檔時，報告的 checked／inventoryCount 只代表實際選取範圍。要將「不同的實體檔」判為確定被改，需要可信的逐 prefix 安裝來源紀錄；現有 marker 不足，因此本次保留 unknown。

## P3-01：值得受控驗證，尚不導入全面簽署

回報的 OEM i386／x86_64 覆蓋率約 98.0%／99.5%，Cyder011 約 0.1%／0.3%，使 PE 簽署成為合理的驗證方向。但並排 bcrypt 對照的內容與大小不同，內容、編譯器、來源信譽與憑證皆為混雜變項，不能推論「無簽章是唯一原因」。ad-hoc bundle 三組仍被刪，只能說該次 ad-hoc 封印沒有避免攔截；Developer ID 加公證未測，亦不能推論其結果。

決策：維持未簽 PE 可符合 manifest 的政策；本次不購買憑證、不重簽 DLL、不改遊戲／反作弊。若進行驗證，僅對有權簽署的自建 PE，以同一建置的未簽與 Authenticode 簽署產物配對，記錄簽署造成的 hash 差異、可重現來源、憑證鏈／時間戳，保留上游既有簽章。Apple codesign／公證不能取代 PE Authenticode；PE 簽章亦不能保證防毒或反作弊相容。

## 離線驗證與實機缺口

可直接執行，不下載、不啟動 Wine：

```sh
/usr/bin/ruby tests/test-cyder-prefix-integrity.rb
/usr/bin/ruby tests/test-cyder-component-integrity.rb
bash tests/test-cyder-component-hooks.sh
bash tests/test-cyder-component-diagnostics.sh
```

新增 fixture 涵蓋正常未簽實體副本、runtime 正常但 prefix 缺檔、32／64 位元映射、兩個 prefix、絕對／相對與斷裂連結、外部連結／父目錄連結／FIFO、其他來源副本、marker 不構成來源證明、清單／發行者拒絕、逾時／取消、讀取中替換與唯讀 snapshot。UI fixture 仍驗證背景執行、取消、重啟、deadline 與輸出上限，並檢查傳入 prefix。

尚須實機：防護保持開啟且無廣泛排除，取得精確同源樣本及 Bitdefender 版本／病毒碼／隔離紀錄，分別觀察下載、解壓、runtime 安裝、wineboot 複製、遊戲載入與重開；保留 engine 與 prefix 的前後 hash。對比未簽／受控簽署的同源 PE，另驗證遊戲與反作弊啟動、操作及退出，必要時依實際產品提交已授權的最小樣本予廠商。離線缺檔模擬不等於 Bitdefender 驗收；目前不能關閉 Issue 或宣稱已修復防毒誤報。

本次結果：元件核心 23 cases／120 assertions，prefix 新增 11 cases／38 assertions，全部通過。Hook（含含空白的 prefix 路徑與無 prefix 的安裝檢查）、AppKit 背景診斷（含 prefix 名稱／來源不明原因顯示）、scrolling launch 的 12 組解析／交接順序與 game launch settings 均通過；Ruby／shell 語法與 `git diff --check` 通過。AppKit 測試有系統 hiservices XPC 訊息，但完成全部斷言並以 0 退出。本次沒有重跑整個 App 整合、正式 App 簽署／公證或實際遊戲／Bitdefender 驗收；新增 quick 範圍的正式發行端到端預算仍待量測。

## 2026-11-02 追加：官方 OEM wineboot 的簽章保留實測

針對「引擎 PE 有 Authenticode，wineboot 複製後是否仍有簽章」做了真實 Wine 初始化測試。本節更新上方「本次沒有執行 Wine」的原階段範圍：追加測試只執行官方 OEM 的 wineboot，不執行遊戲；正式 runtime 與使用者 bottle 均未更動。

輸入：[官方 v0.10.0 OEM 發行包](https://github.com/dspp779/CyderBits/releases/tag/v0.10.0)，`Cyder-maplestory-oem25-0.10.0.zip` 中的 `engine-maplestory-oem25.0.1.38865-OEM25-dev.tar.xz`。封存 SHA-256 為 `31a479395b8d5fc95567240bb3e9387a3fa292776f0572b450926e74d7a744ac`，符合 App 內 `engine-artifact-sha256.txt`；這是封存一致性檢查，不另宣稱完成 App 發行者信任驗收。

環境為 macOS 27.2／arm64／Rosetta。引擎完整解壓至新臨時目錄，以包內 **native `wineloader` 執行包內 `wineboot -i`**，明確指定新的 win64 `WINEPREFIX`、包內 `WINESERVER`／`WINELOADER`／DLL 搜尋路徑與相依 library 目錄，使用包內 bottle conf 模板。未經 Perl frontend，因此這是封存內 native engine／wineboot 複製行為驗證，不是 Cyder App 的完整啟動驗收。禁止 Mono／Gecko 自動安裝；沒有連接遊戲或修改遊戲／反作弊檔案。wineboot 以 0 結束，僅對此新 prefix 執行 wineserver `-k`／`-w` 以完成清理／flush；含清理共 21.985 秒。

| 項目 | i386 → syswow64 | x86_64 → system32 |
|---|---:|---:|
| 引擎中辨識為 PE 的普通檔案 | 825 | 766 |
| PE certificate table 有資料 | 809（98.1%） | 762（99.5%） |
| 可在對應系統目錄直接以同名對應的 PE | 723 | 718 |
| 實體檔案／符號連結 | 723／0 | 718／0 |
| 與引擎原件 SHA-256 完全相同 | 723／723 | 718／718 |
| 上述副本具有 PE certificate table | 719 | 714 |
| 選取的關鍵 PE，原件／副本 Authenticode 離線驗證通過 | 11／11，各自皆通過 | 11／11，各自皆通過 |

這裡的 PE-only 分母與回報者自行盤點的 Windows 元件分母／樣本不同，不能當成逐項重現其 815／756 統計。來源 PE 有 102／48 個沒有出現在直接對應的 syswow64／system32 同名位置：元件可能安裝至其他目錄或不由此初始化路徑複製；**沒有把它們判成缺檔或防毒刪除**。

驗證選取 bcrypt、crypt32、wintrust、mspatcha、xinput9_1_0、control、ncrypt、msidb、rasapi32、wevtapi、winemapi，兩架構合計 22 個 PE。使用從官方 2.12 source 在臨時目錄編譯的 [osslsigncode](https://github.com/mtrojnar/osslsigncode)，原件與副本各自檢查檔案 Authenticode digest、密碼學簽章、憑證鏈及 timestamp；合計 44 次皆 exit 0。驗證器使用既有 OpenSSL CA bundle 及 `-ignore-crl` **離線不查撤銷狀態**，沒有忽略 timestamp 或憑證鏈，也沒有變更系統／防毒的任何驗證設定。這不能替代 Windows 信任政策、即時撤銷狀態或防毒驗收。

兩個 bcrypt 的 signer 均為 `Codeweavers, Inc`。i386 原件及 prefix 副本皆為 93,776 bytes，SHA-256 `7c611a709287d40b351127c7125010b7bbad572238b6591d66db921c7e992570`；x86_64 原件及副本皆為 106,064 bytes，SHA-256 `13168a1b02a7a6be9c0d8f48458e140d68dc36b62ccf86018cf6a6d6900795a5`。兩組的 certificate table hash 亦各自完全一致。這是此次官方 OEM 發行包樣本，不回填為 mapledan 當時被刪檔案的 hash。

**結論：前半段假設獲得直接支持——這條 wineboot 實體複製路徑保留原 PE 的 Authenticode，無須在 prefix 再簽一次。後半段「因此不會被 Bitdefender 刪除」尚未被驗證。** 本機未找到 Bitdefender App、launch daemon 或匹配程序，沒有安裝防毒、加排除或停用防護；不能把 DLL 留存當作 Bitdefender 通過。回報者已提出 OEM bottle 的 winemapi 刪除紀錄，但當時該檔案的 hash 與簽章仍不明，亦不能反向當成「已證實簽署檔仍被刪」的同源樣本。

P3-01 決策應更新為：**引擎端一次簽署即可涵蓋此處的等內容副本，值得優先設計同源受控簽署／未簽配對測試；是否降低 Bitdefender 攔截仍待真機對照。** 不需因此無差別重簽 prefix，更不能刪除 prefix 診斷：即使副本有有效簽章，檔案仍可能缺失、來源不同，或安裝路徑沒有建立預期副本。

曾另外嘗試 OEM native loader 的 `WINEARCH=win32`／`wow64`，兩者明確被該包拒絕，均 exit 1；上表只統計成功的 win64 prefix，其內同時具備兩架構系統元件，不將拒絕的嘗試計為成功。

[逐檔 SHA-256、certificate table hash、驗章結果與工具／輸入 digest](evidence/issue-12-oem-wineboot-2026-11-02.json)。未將 OEM 二進位、憑證私鑰或臨時建置工具加入 repo。測試 prefix 與原始驗章 log 保留在臨時測試目錄供核對；測試 wineserver 已退出。


## 2026-11-02 決策更新：不以憑證採購阻擋正式打包

依預算與現有證據，先不購買 Windows code-signing 憑證。引擎分支 `codex/issue-12-pe-release-signing` 已將新 Authenticode gate 改為明確選用：`CYDER_PE_SIGNING=off` 預設不要求憑證，Apple Developer ID／公證與既有完整性流程照常；只有 `required` 才啟用完整的 PE 簽署與失敗停止檢查。兩種模式都保留上游 PE 原簽章，strip 不會改寫已帶 certificate table 的 PE。未選用時不宣稱 Authenticode 憑證鏈或時間戳已驗證。

本分支的 runtime／prefix 診斷不變；合法未簽 PE 仍可符合 manifest，來源不明的不同副本仍為 unknown，缺檔不推定為防毒刪除。P0-01 優先補精確 hash、建置與隔離證據，P0-02 保留已補強診斷，P3-01 留待有必要時再做受控配對驗證；一般受控修復尚未完成。未購買憑證、未變更防毒設定、未更新正式 runtime。

## PR #20 review 修正（2026-11-02）

- **P2：合法大型 registry 被拒絕。** 原本重用 8 MiB manifest 上限讀整份 system.reg，會讓已安裝軟體的大型 prefix 直接 unknown。現在只讀最多 64 KiB 的 registry header、遇第一個 section 就停止判讀架構，並核對讀取前後身分；超出 header 預算、讀取中變更或架構不明仍為 unknown。新增 >8 MiB body 案例，正常與缺檔均能得到正確結果。
- **P2：選擇連結在檢查期間切換卻回報正常。** 引擎 root 別名可能在 snapshot 後改指向，原程式驗舊 canonical engine 的內容，卻將指向新目標的 prefix link 視為 ok。現在對接受的引擎別名於驗證前後核對其 canonical 目標，並核對指定 prefix 別名在整次檢查後是否仍選擇同一環境；改變時 unknown，理由為 engine_selection_changed／prefix_selection_changed，不跟隨外部檔案作內容比對。
- **P2：prefix 開始前逾時會丟失既有結果。** 原外層 tick 會使整份報告回到空 components；現在保留已完成的 runtime 報告，對未開始的 prefix 附 timeout unknown，已確認的缺檔仍使整體為 mismatch。
- 新增四個離線回歸均先重現再修正：大型 registry、引擎別名切換、prefix 別名切換、runtime 缺檔後預算耗盡。仍不消除檢查後再被更動的競態，也不代表實際 loader／防毒驗收。

Review 後驗證：prefix 15 cases／48 assertions、既有 component 23 cases／120 assertions，合計 38 cases／168 assertions 全部通過；hook 與 AppKit 背景／取消／重啟／deadline／輸出上限 fixtures 通過，差異格式檢查通過。沒有重跑遊戲或防毒實機測試。
