# 新楓之谷滾輪相容設定：隔離、還原與驗收

## 目前介面：2026-10-29 簡化調整

依使用者指示，全域「滾輪相容預設」選單改為輸入分頁的「精準捲動」開關，
說明僅為「開啟可能會捲動過快。」。開啟對應 precise／Y，關閉對應 traditional／N。
新設定、缺少欄位、無效值及舊的全域 unmanaged 都使用關閉／N；已保存的 precise 保留開啟。
這取代初版「預設不自動套用」的產品選擇，但仍僅寫各已識別 EXE 的 AppDefaults，
不改 prefix-wide 登錄值。每遊戲的跟隨全域／不自動套用／傳統／精準選項維持，
其中不自動套用仍能在下次啟動時還原保存的原值。儲存偏好不立即變更執行中的遊戲。

偏好設定移除「打開遊戲庫」按鈕；「關閉所有 Wine 程序」改名為
「關閉所有 Windows 程序」並移到進階分頁，確認對話框及狀態文字亦使用新名稱。
其他位置的遊戲庫入口維持。

本次 9 組相關回歸通過：force-settings-ui、scrolling-launch、settings-swift、
settings-ui（實際 AppKit 與畫面檢視）、settings-model、settings-snapshot、
maplestory-scrolling（19 cases / 82 assertions）、settings、app-payload。
測試涵蓋新預設 N、舊全域 unmanaged 遷移、每遊戲還原選項、開關保存及按鈕所在分頁。

分拆提交前，另將 Git index 匯出成不含其他工作區修改的暫存副本：上述 9 組加上
request-journal、execution-identity、native-handoff，共 12 組全部通過，沒有 skip。
原生 handoff 在具備主機權限的環境使用實際 x86_64 子程序；受限環境的 identity 測試
確認拒絕效果並保留 prepared，而不會誤報為 revoked。

以下保留初版設計、測試與現場 A/B 的歷史紀錄；其中初版預設值以本節更新為準。

調查日期：2026-10-28。對應 [CyderBits Issue #9](https://github.com/dspp779/CyderBits/issues/9)。

## 證據與適用範圍

Issue 仍為 open、留言數為 0。mapledan 在 2026-09-07 回報 Cyder 0.10 OEM
中倉庫、商城、聊天、技能視窗的捲動問題，並表示全域 `UsePreciseScrolling=N`
改善其環境。這是單一回報者的實測，不能推定所有版本、裝置或遊戲均通過。

本次核對 GitHub main 為
[`450f4ab8c134d6b922d7cab9f8396c934ebd71ce`](https://github.com/dspp779/CyderBits/commit/450f4ab8c134d6b922d7cab9f8396c934ebd71ce)
（0.13.2）。`cyder-common.sh`、`cyder_settings.swift`、`cyder-edit-user-reg.sh`、
`cyder-apply-settings.sh` 沒有這個選項的既有處理；未找到 0.13.2 對該問題的遊戲實測。
本機 ogom HEAD 為 `d080fec15b70132fdc79dad08964c37aeea4b803`（0.14.0-rc.1），
包含 main 之後的修改。本實作加在本機應用層，保留原有未提交變更；未建置或發布新版。

## Wine 行為與隔離粒度

本機 CX26 原始碼：兄弟 engine repo 的
`build/cx26/sources/wine/dlls/winemac.drv/macdrv_main.c`，
`get_config_key()`、`setup_options()`、`macdrv_init()`。

- 預設 `use_precise_scrolling = true`。
- driver 初始化時先查詢目前程序 ImagePathName 的 EXE 檔名所對應的
  `HKCU\Software\Wine\AppDefaults\<exe>\Mac Driver`。
- 找不到特定值才回退至 `HKCU\Software\Wine\Mac Driver`；兩處均不存在時使用 Wine 預設。
- `UsePreciseScrolling` 有走上述 AppDefaults 路徑。不能從 RetinaMode 類推：RetinaMode
  刻意忽略 appkey，屬於共用顯示設定。
- 每個新的 MapleStory.exe 程序會自行讀取自己的 AppDefaults；不必依賴 launcher 的
  per-profile 環境繼承。因此 URI handler / GGM 啟動子程序也有可行的套用途徑，仍需實測。

`cocoa_app.m` 的 `handleScrollWheel:` 在精準路徑傳送縮放後的 delta，傳統路徑
則累積捲動量並產生 120 的倍數，可一次超過 120；一秒間隔或方向切換會重設累積量。
目前該函式未見 `momentumPhase` 過濾，不能把「N」描述成保證停用所有慣性事件。
遊戲如何解讀事件與實際手感仍要在遊戲內觀察。

AppDefaults 是 **同一 prefix 中依 EXE 檔名區分**，不是依完整路徑或 profile ID 區分。
一般 Game.exe、GGMWebStart.exe、Maplestory_Classic.exe 不會命中本設定；同 prefix
內另一個同名 MapleStory.exe（包含大小寫不同）會共用。需要對兩個同名遊戲使用不同值時，
應先用 Cyder 的獨立 per-game bottle（`cyder_create_profile_prefix` / profile UI），
再對各自解析出的 prefix 操作。本工具不自動建立、複製或搬遷遊戲。

## 現有 Cyder 路徑與整合決策

`cyder_settings.swift` 保存 `perProfile` 與舊版 `perExecutable`。前者依路徑產生
profile ID，不能據此聲稱 HKCU 登錄設定也有程序隔離。
`cyder_load_game_settings` 載入遊戲覆寫；`cyder_prepare_game_launch_settings` 在啟動前
合併設定。`cyder_apply_user_settings` 在 prefix 已執行時通常延後 registry 更新。
閒置時走 `cyder-edit-user-reg.sh` 直接編輯 user.reg；強制完整套用才走
`cyder-apply-settings.sh` 的 Wine reg client 與 `.cyder-settings-applied.tsv` 差異紀錄。
顯示、字型等 HKCU 設定仍有共用性，不能將本次方案泛化成它們也已隔離。

CompatDB CDB v1 有參數、DLL、環境、graphics backend 等動作，沒有任意 registry 或
Mac Driver scrolling 動作。現有 env 動作不會讓 macdrv 自動讀取新的環境選項。
因此本次不修改 CompatDB 格式、不擴大引擎介面，也不新增自動套用 N 的全域或遊戲預設。

提供兩層設定，settings schema 14；舊版設定缺欄位時安全遷移：

| 層級 | 選項 | 初始值 |
|---|---|---|
| 偏好設定 → 輸入 → 滾輪相容預設 | 不自動套用／傳統捲動／精準捲動 | 不自動套用 |
| 遊戲庫 → 遊戲選項 → 一般 → 滾輪相容 | 跟隨全域設定／不自動套用／傳統捲動／精準捲動 | 跟隨全域設定 |

全域是 **Cyder 啟動時的預設偏好**，不是寫入 `HKCU\Software\Wine\Mac Driver`。
有效選項為遊戲覆寫優先，再取全域。這讓一般遊戲可以跟隨全域精準捲動、MapleStory
獨立選傳統捲動；也可對單一遊戲選不自動套用以排除全域偏好。
UI 顯示同 prefix 同名 EXE 共用設定及重新啟動才生效的提示。

偏好 UI 只保存設定，不呼叫 Wine、不立即改動正在執行的 prefix。已識別的 EXE 在下次
啟動前，由 `cyder-scrolling.rb` 備份、套用 N / Y 並讀回確認；失敗時阻止該次最終啟動。
切回不自動套用（包含刪除遊戲覆寫後跟隨已停用的全域）時，在該 EXE 下次啟動前還原
首次保存的原值。從未受 Cyder 管理的值維持原狀，不會為了停用而刪除使用者自己的設定。
預設且沒有歷史備份的 prefix，不啟動 Ruby / Wine registry client。

更新在選定 sync 模式與 session 準備完成後、最終遊戲 handoff 之前進行，避免 registry
client 以不同的 sync 設定先啟動 wineserver。正常字型／顯示設定的套用順序維持不變。
程序已讀取的 driver 設定不會即時切換；此工具不強制結束遊戲或 wineserver。

自動套用僅針對 Cyder 已識別的 EXE，不推測 `.lnk`、批次檔、MSI、登錄匯入的實際遊戲，
也不會把全域偏好傳給啟動器之後產生的其他 EXE。這些目標維持已有 registry 值；需要時
可直接對實際 EXE 啟用設定。已寫入的 MapleStory.exe AppDefaults 仍會供由 GGM / URI
啟動的新 MapleStory 程序讀取，但尚未受管理的子程序不會自動取得 UI 中的新偏好。
本次未新增 CompatDB action 或 Wine patch。

通用工具隨 app 打包；原 `cyder-maplestory-scrolling.rb` 保留為相容入口。
不同 EXE 的備份各自獨立，MapleStory 沿用先前備份位置。備份路徑不代表完整路徑隔離，
同 prefix 同名 EXE 仍共享登錄值和備份；需要不同設定時必須使用獨立 bottle。

## 操作

先完全退出 MapleStory，再選定它實際使用的 Wine engine 與 prefix。共享 bottle 與
獨立 bottle 不可混用；用與 Cyder 啟動該遊戲相同的 engine。以下 prefix、engine 為
使用者指定的實際絕對路徑，不應盲目照抄回報者的 OEM 路徑。

```sh
export WINEPREFIX="/absolute/path/to/the/game/bottle"
export WINE_INSTALL="/absolute/path/to/the/matching/engine"
/usr/bin/ruby scripts/cyder-maplestory-scrolling.rb status
/usr/bin/ruby scripts/cyder-maplestory-scrolling.rb traditional
# 完全關閉後重新啟動 MapleStory，在遊戲內比較滾輪操作。
# 若要明確要求精準模式：
/usr/bin/ruby scripts/cyder-maplestory-scrolling.rb precise
# 若要回到首次操作前的狀態：
/usr/bin/ruby scripts/cyder-maplestory-scrolling.rb restore
```

在已打包 app 中，檔案位於 `Cyder.app/Contents/Resources/ogom-scripts/`，以完整路徑執行。
新值只影響後續初始化 driver 的程序；不會強制結束遊戲或 wineserver。
即使程序仍在執行時操作，也應在完整退出並重新啟動遊戲後才驗收。

首次變更會把**該 EXE 原本的值或不存在狀態**保存至
`<prefix>/.cyder-maplestory-scrolling/original.json`（MapleStory），
其他 EXE 為 `<prefix>/.cyder-scrolling/<檔名雜湊>/original.json`，先保存再寫 registry。
還原僅處理 UsePreciseScrolling，原先不存在則刪除該 value 以重新繼承；不刪整個 key。
原值為不支援的非 REG_SZ 類型時會拒絕變更。重複套用不覆蓋基準；完成還原才清除備份。
失敗或寫入後讀回不符時保留備份以便重試。工具以檔案鎖避免自身同時更新，
不提供與外部 regedit 的交易隔離；操作期間勿同時手動編輯同一 value。

原有全域 N **不會自動刪除或改成 Y**：工具無法知道它是手動 workaround 還是使用者刻意
設定。`precise` 只對 MapleStory 明確覆寫 Y；`restore` 會重新繼承原有全域 N。
若要撤回舊的全域 workaround，須由使用者確認原始偏好後另行處理，不能假裝能重建未知原值。

## 離線回歸與實機驗收

執行 `bash tests/test-cyder-maplestory-scrolling.sh` 與
`bash tests/test-cyder-scrolling-launch.sh`。測試使用 registry double 與
Wine 命令執行器替身，不啟動真實 Wine、不碰使用者 bottle、不測滑鼠硬體：

- 自願啟用、N / Y / restore、原值不存在與已存在、原先全域 N、大小寫與同名 EXE 限制。
- 跨工具實例設定持久化、重複啟動模型、同 prefix 一般遊戲與 launcher 不受影響。
- 不同 prefix 的備份獨立、還原只改單一 value、其他 driver 設定與 user.reg 不被離線覆寫。
- 匯出失敗、寫入失敗、還原失敗、讀回不符、不支援類型、損壞備份、重複操作鎖。
- 路徑含空白與 Unicode，使用 winepath 解析實際 drive mapping；無效轉換不呼叫 reg。
- app payload 包含操作工具。

仍需真實 CX26 engine / MapleStory 驗收，以下尚未執行，不能以 registry 成功取代：

1. 在可還原的測試 bottle 比較原設定、N、Y、restore 四種狀態；確認實際 macdrv
   讀取 AppDefaults，包含由 GGM / URI 啟動的子程序，以及共享 wineserver 已存在的情境。
2. 倉庫、商城、聊天、技能視窗分別測上下滾動、短距離微調、快速反向、放手後停止與慣性；
   記錄滑鼠 / Magic Mouse / 觸控板、macOS、Cyder、engine、遊戲版本與影片。
3. 與一般 Windows 遊戲在同 prefix 同時執行及交替啟動，確認後者的原捲動行為不變。
4. 重啟 Cyder、重啟遊戲、切換 Y 並重啟、restore 並重啟；驗證既有程序不被當成已更新。
5. 兩個路徑中同名 EXE 改用獨立 bottle，確認可以各自選 N / Y；不要在共享 prefix
   中宣稱已達到完整路徑隔離。Classic 版本不在目前回報實測範圍內。

### UI 整合後實際測試結果

- `test-cyder-maplestory-scrolling.sh`：Ruby 19 cases / 82 assertions 通過，另含 shell
  app payload 與 display editor 保留 AppDefaults 檢查；包含 MapleStory / 一般遊戲在同 prefix
  中各自選擇、同名 EXE 大小寫共用、無管理紀錄時不碰使用者值、還原原值與失敗重試。
- `test-cyder-scrolling-launch.sh`：通過；12 組全域與個別設定的優先順序、原生設定快照
  權威性、環境注入過濾、同步模式、最終啟動前套用／還原、失敗阻止啟動、非 EXE guard。
- `test-cyder-settings-swift.sh`：通過；舊 schema 13 遷移、無效值、所有選項的儲存重讀、
  全域／每遊戲解析、metadata、設定 patch 合併及快照保存。
- `test-cyder-settings-ui.sh`：通過；實際 AppKit 全域／每遊戲選單、Apply、重新開啟、四種每遊戲
  選項保存、遊戲執行中保存偏好而不立即套用 registry。已檢視全域及每遊戲的 UI render，
  確認選單與同名 EXE 提示可見。
- `test-cyder-app-payload.sh`、`test-cyder-settings-model.sh`、`test-cyder-settings.sh`、
  `test-cyder-fast-user-reg.sh`、`test-cyder-settings-snapshot.sh`：通過。
- `test-cyder-force-settings-ui.sh`：已修正過期斷言並通過。涵蓋 async revision fence、
  背景 GPTK 掃描／維護、背景載入的 capability 與新滾輪 UI；不再要求 UI 讀取時改寫
  GPTK symlink，也不把 EXE 專用滾輪更新誤稱為全域顯示設定的套用。
- `test-cyder-execution-identity.sh`：通過。受限執行環境讀不到同使用者程序／boot identity 時，
  回報 `processIdentityUnavailable`、保留 prepared 票證、不產生子程序；真正 revoked 的
  票證仍拒絕執行。原先合併 guard 將 identity 無法讀取錯報為 revoked 的問題已修正。
- `test-cyder-execution-owner.sh`：主機環境通過；含票證撤銷、防重播、跨程序鎖、當機、
  boot boundary、同名／替換 prefix、全域維護與故障時保留不確定狀態。
- `test-cyder-native-handoff.sh`：使用者同意授權後安裝 Rosetta 2，主機環境完整通過。
  包含實際 x86_64 子程序、一次性交接、同 prefix 多個 root、共用 runtime 全域鎖、
  spawn 前後當機復原、拒絕遲到 wrapper、防重播、失敗 spawn 不發布 PID、十次立即退出。
  仍保留 host identity 與 x86_64 前置檢查，不跳過、不以其他架構替代。
- `test-cyder-game-launch-settings.sh`：Rosetta 安裝後重跑通過，先前 Bad CPU type 限制已解除。
- `test-release-cyder.sh` 與 `test-cyder-rosetta.sh`：通過。
- 本次共 16 組相關測試通過，沒有測試 skip。原生權限測試在主機環境執行；受限環境的
  identity 回歸則確認無法辨識身分時保留 prepared、拒絕產生效果，並正確區分真正 revoked。
- 未在使用者真實 prefix 套用滾輪設定、未啟動 MapleStory、未測實際裝置滾輪。

## 2026-10-28 測試版建置

`dist/scrolling-test-20261028/`，版本 `0.13.2-scroll-test.20261028`，test 通道 adhoc，未公證。
保留既有正式 App 與 zip。原生 UI 兩個 slice 與 minOS 11.0、deep/strict 簽章、包內腳本
與來源一致、Cyder012 engine SHA-256、DXVK／DXMT 真實封存皆通過驗證。

首次建置發現目前 Command Line Tools 的 macOS Swift compatibility archives 只有 arm64，
無法連結 x86_64 UI；其失敗記錄留於 validation。從 Swift 官方 6.4.0 安裝包取得完整
靜態 archives，驗證 Developer ID Installer: Swift Open Source 簽章及 Apple 公證信任，
只在 x86_64 link 明確加入這些 `.a`。保留原 Apple 編譯器、SDK、標準函式庫及 target，
未使用 shell UI fallback，亦未引入暫存目錄的動態依賴。原始碼未因此增加 toolchain override。

Swift 官方套件 URL、雜湊、各靜態函式庫雜湊及本機建置 wrapper，記於
`validation/build-provenance.json`；Swift 授權文字隨測試 ZIP 附帶。此為目前工作樹的
應用層測試包，未提交或公開發佈。實機對照與回復步驟見同目錄 TESTING.zh-TW.md。

交付 ZIP：`Cyder-0.13.2-scroll-test.20261028.zip`，86,595,264 bytes。
SHA-256：`ad0c3e129c7f7e808cf7c8be4ce778d1430097b9efdce6f2d8f154e7ccc89870`。
ZIP 解壓後全部 App 檔案／symlink 與原 bundle 一致，arm64／x86_64 及 deep/strict
簽章再次通過；操作說明、Swift license 與 validation 記錄已附帶。未安裝測試 App 或啟動遊戲。

## 2026-10-29 實際啟動卡住的診斷與修正

使用者從 Beanfun 啟動測試版後，UI 停在「正在啟動程式」。唯讀檢查顯示：

- 只有 CyderSwift 存活，沒有 Wine、wineserver 或 MapleStory；UI 主執行緒正常處於 AppKit run loop。
- 最近 session 停在 app-start；沒有這次的 last-launch.log 或新執行票證。
- 前次 engine／graphics install、bootstrap 成功；此次 request journal 仍為空。
- 現場 settings.json 不存在，正常會先產生預設快照。

根因是前次 schema 14 整合漏改 `CyderAcceptedSettings.isValid()`，仍只接受 1...13。
即使 settings.json 不存在，`{}` 經 `CyderSettingsStore.acceptedSnapshot` 正規化後也輸出 14，
因此 journal.submit 在保存前拒絕。cold-start 拒絕回呼只處理 open-reply，沒有清除 setup panel，
所以 UI 持續顯示啟動中；問題尚未進入 Wine，不是遊戲或滾輪登錄寫入造成的 hang。

修正接受範圍為 1...14、維持拒絕未知版本 15；所有本機 EXE／URI 送件拒絕路徑會收掉
進度、清除 ingress 狀態並顯示錯誤。另移除拒絕非 EXE Apple Event 的原始字串日誌，
避免 LaunchServices 把登入參數當文件候選時將參數內容寫入診斷；原始現場記錄未刪改。

新增跨模組測試：缺設定檔／schema 14 個別傳統捲動偏好 → 實際 model 正規化 →
journal durable acceptance → authorizeDispatch；驗證設定快照與動態參數完整保留，
測試不啟動 Wine／遊戲，不使用真實登入票證。這補上前次只分別測 model 與 shell、
未驗證兩者之間 journal schema gate 的缺口。

未結束現有使用者程序、未重新送出 Beanfun 要求、未修改實際 bottle。

修正後九組相關回歸通過：request journal、model＋journal 跨模組、滾輪 registry、
滾輪 launch、拒絕提示靜態檢查、快照 shell reader、AppKit、實際 instance coordinator、
完整原生 x86_64 handoff。修正包 `dist/scrolling-test-20261029-fix/`，
版本 `0.13.2-scroll-test.20261029.1`，沿用 Cyder012、相同官方 Swift 相容性靜態函式庫。
ZIP 解壓後完整內容、雙架構、strict/deep 簽章通過。ZIP 大小 86,580,754 bytes；
SHA-256 `2fa93e9d5b0e18a858282220da234da45f3b15537be9074bbdabf6dfb614456e`。
尚未替使用者啟動遊戲；使用修正版前需退出舊 Cyder，確認 Beanfun 啟動器指向新 app，
並重新取得登入資訊，避免沿用已等待多時的舊票證。

## 2026-10-29 使用者現場滾輪 A/B 紀錄

以下是打包後的新實測，時間為 Asia/Taipei；前文「尚未啟動／實測」描述的是各階段當時狀態。

| 項目 | 傳統捲動 | 精準捲動 |
|---|---|---|
| 啟動前準備 | 15:28:16 完成 | 15:33:07 開始準備，後續讀回確認完成才通知啟動 |
| Cyder 全域偏好 | traditional，revision 9 | precise，revision 10 |
| 每遊戲覆寫 | 無 | 無 |
| MapleStory.exe AppDefaults 讀回 | `UsePreciseScrolling="N"` | `UsePreciseScrolling="Y"` |
| 啟動 session | `598771D1-4E86-4C89-9894-6CA9AE0C435A` | `F6D9BF6F-02B7-4097-845B-BB4DFD342BCD` |
| Wine launch 返回成功 | 15:29:10，status 0 | 15:34:35，status 0 |
| 使用者回報 | 已完成測試 | 已完成測試，與傳統捲動感覺差不多 |

準備兩輪時都先確認沒有舊遊戲程序，再使用測試包內的同一個 Ruby helper，
經 Wine registry export/import 實際讀回 N／Y；沒有只改 UI 而未核對 registry。
由於啟動時會重套偏好，精準輪亦將 Cyder 啟動偏好同步為 precise，避免被先前
traditional 偏好覆蓋。原始設定另備份至本機測試目錄。

精準輪測試後再次唯讀核對：

- `settings.json` 維持 precise／revision 10，每遊戲覆寫皆空。
- shared prefix 的 `Software\\Wine\\AppDefaults\\MapleStory.exe\\Mac Driver`
  維持 `UsePreciseScrolling="Y"`；未發現 prefix-wide 的同名值。
- `.cyder-maplestory-scrolling/original.json` 仍為 `{"version":1,"original":null}`，
  首次原值不存在的還原基準未被覆蓋。
- 最新啟動 log 為上述精準輪，wineserver PID 22167 有 start／atexit；
  檢查時已無 MapleStory、BlackCipher、DwarfAxe、wineserver 或 CyderSwift。
- log 有 environment-state 探測 status 10，後續 wine-launch 為 status 0；
  15:35:07 的 observation timeout 不能直接當成遊戲啟動或退出失敗。

**結論層級：** N／Y 的實際寫入與讀回、持久值及新啟動順序已確認；使用者實測
兩種模式手感相近。現有啟動 helper 將成功訊息導向 `/dev/null`，沒有 macdrv 初始化值
或遊戲每筆 wheel event 的 trace，因此不聲稱已逐程序追蹤到其讀值／事件量。
這次不據此判定原 Issue #9 已修復、無法重現，或所有裝置／四個問題視窗都驗收通過。
使用者尚未提供輸入裝置型號及逐視窗測試矩陣，兩者保留為未知，不推測使用了一般滑鼠。

### 為何兩種模式可能感覺相同

本版 Wine 依 CGEvent 的 continuous 標記與捲動量處理，不以 Magic 品牌作為條件。
MacBook 內建觸控板、Magic Trackpad／Mouse，以及能產生同類細碎連續事件的其他
裝置／驅動路徑，都可能比較容易看出差異；第三方硬體是否屬此路徑仍取決於實際事件。
一般有刻度滾輪也會經過設定分支，但 precise 對非 continuous 小幅輸入補至至少
120，traditional 則整理為 120 的倍數，常見操作可能產生相近結果。
遊戲自己的量化／限速亦可能讓手感相近，目前沒有事件追蹤來判定本輪是哪一種。
N 不是「停用所有慣性」，也不是固定降低速度。

參考：[Wine 新增此選項的原始說明](https://www.winehq.org/pipermail/wine-patches/2014-May/132551.html)、
[Apple continuous scroll event 欄位](https://developer.apple.com/documentation/coregraphics/cgeventfield/scrollwheeleventiscontinuous)。

本機準備及檢查證據保存在 `dist/maplestory-scroll-live-check-20261029/`：
`traditional-prelaunch.json`、`precise-prelaunch.json`、`posttest-verification.json` 與去除
登入參數的啟動 log。此次保留 precise 設定，沒有自行切回 unmanaged 或還原。

後續依使用者要求關閉已保存的精準捲動：settings revision 11 為 traditional，
新楓之谷 AppDefaults 已由 Wine 寫入並讀回 N，實際啟動偏好解析亦為 traditional，
沒有每遊戲覆寫，原始還原基準保留。此次未啟動遊戲；證據為同測試目錄的
`disabled-precise-verification.json`。
