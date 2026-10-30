# DXMT 0.80 同版更新與閒置切換

DXMT 對使用者顯示上游版本 **0.80**。安裝識別 `installKey` 由封存 SHA-256、逐檔內容與簽章政策產生，包含 Team、時間戳與上游來源政策；同版內容或政策改變也會重新評估。版本 marker 不能單獨證明已更新。

既有正式封存的 `0.80-cyder.1` 名稱及 native signing identifier 保留作不可變的內部追溯資訊，不用它來比較更新先後，也不顯示成新的 DXMT 上游版本。本次重用已完成真實 Developer ID 簽署的封存，沒有重新簽署上游原件或重建 Wine。

## 套用流程

1. 驗證 App 發行者、受簽署資源保護的 manifest、來源 digest 及目前安裝內容。驗證不明或來源不可信就停止，不以 marker 推測安全。
2. 已符合 digest／政策、engine link 與 prefix DLL 的安裝直接返回，不改寫檔案；即使 Windows 程序正在使用也可以完成這種唯讀判斷。
3. 需要變更時，取得現有 execution owner 的全環境排他範圍，原生列舉同 UID 的程序並確認閒置。managed engine、Wine／wineserver 與 `.exe` 程序均保守視為使用中，包括外部 Wine；不讀取 argv 或環境變數。列舉失敗、截斷或無法確認則延後。
4. 在新 staging 目錄安全解壓、檢查逐檔 hash、native Team／時間戳與簽章政策。拒絕路徑穿越、symlink、重複項目與特殊檔案。
5. 在鎖內重新確認閒置及 selector 沒有變動，建立新的 digest 命名實體目錄，以原子 symlink 切換 `current-dxmt`。保留舊目錄，不覆寫可能仍被映射的 native 檔。不同 prefix 的啟動也受全環境範圍保護。
6. 僅更新需要變動的 prefix `winemetal.dll`；與受信任 manifest 相同的 DLL 保留 mtime。登錄值、遊戲檔案與設定不變。失敗嘗試還原原件；中斷或無法完整還原會保留交易證據並阻止後續盲目覆蓋。

使用中／不明時回傳 deferred（exit 75），下次準備或啟動時再試；沒有背景計時器自動切換。已進入變更流程的工作仍持有 execution owner，直到完成或還原。較新版本不自動降版。唯讀完整性診斷本身不會觸發更新、補簽或修復。

## 離線回歸

- `tests/test-cyder-graphics-update.rb`：17 cases／80 assertions，涵蓋初裝、同版 digest／政策變更、重複啟動不改寫、busy／unknown 不變更、舊版／同版已知損壞、新版不降版、兩個 prefix、prefix 修復、候選驗證失敗、切換前程序出現、失敗還原、交易中斷及安全解壓。
- `tests/test-cyder-component-integrity.rb`：23 cases／120 assertions，包含 digest／政策／signer 對 installKey 的綁定。
- 原生 graphics runtime、execution owner、native handoff、完整 App 整合與背景診斷測試通過；確認全環境 barrier 與 shared／exclusive prefix 範圍互斥，交接後不持鎖到遊戲退出。
- 既有 graphics 安裝、滾輪啟動、App payload、release wrapper 與 component hooks 回歸通過。三份打包／驗證 skill 通過官方驗證器。

## 本機測試包與驗收邊界

2026-10-30 已產生 `0.13.2-dev-dxmt-digest`，Developer ID、arm64 + x86_64，未公證、未發布。封存解壓後 App deep／strict 驗章、DXMT provenance／Team／時間戳驗章及唯讀快篩均通過。完整診斷在隔離 runtime 通過，DXMT 顯示 0.80。

真實主機當時仍有 Windows 程序，新 App 正確延後更新；未關閉或變更使用者程序。閒置遷移使用隔離 runtime 的注入式 idle fixture（保留真實發行者、內容與簽章驗證），確認舊目錄、相同 prefix DLL 與登錄值保留。其後使用真實原生 guard，在主機仍 busy 時確認健康安裝返回 no-op。這不等同實際主機閒置更新或遊戲載入驗收。

實機仍需確認：所有 Windows 程序退出後實際啟動／切換、DXMT 在支援的 macOS／硬體載入、D3D10／11 遊戲及防毒相容性、重複啟動與正常退出。新楓之谷捲動與 NGS 行為也需獨立實測，不能由登錄值或檔案驗證推定。

成品及 checksum 在 `dist/test-dxmt-digest-20261030`；交付副本為原專案 `dist/dxmt-digest-test-20261030`。本次沒有 commit、上傳或安裝到使用者既有 runtime。
