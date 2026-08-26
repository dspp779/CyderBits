# MoltenVK 雙版本 + wait-poll shim（引擎內建）

日期：2026-08-25  
狀態：draft（待實作計畫）  
相關：

- GitHub：[CyderBits#7](https://github.com/dspp779/CyderBits/issues/7)（Intel 內顯 + MoltenVK 1.4.0 世界層黑畫面）
- Ports 洩漏：`docs/maplestory-classic-dxvk-ports-leak.md`
- 歷史 shim 契約：`cyder-wine-engine/docs/moltenvk-timeline-wait-poll-app-overlay.md`
- 引擎整合：`cyder-wine-engine/docs/integration-with-cyder.md`
- minos 豁免先例：`cyder-wine-engine/scripts/pack-minos-scan.py`（DXMT）

## 問題

1. 上游／Cyder 現用 MoltenVK **1.4.0** 在部分舊 Intel GPU 上出現世界層全黑（UI 正常）；#7 以 CrossOver／oem **1.2.10** 可解。
2. 上游 **1.4.2** 含 Mac1／舊 Intel 相關修復，但官方最低系統升為 **macOS 12.0**（1.4.1 已升到 11.0），與 Cyder 產品 host 地板 **10.15** 衝突。
3. DXVK 長跑的 Mach Ports 洩漏修復目前編在單一 `libMoltenVK.dylib` 的 source patch 裡；單純升上游 **不會**自動修好 wait 洩漏。
4. Cyder011 規定 artifact **不得**含 `libMoltenVK.real.dylib` shim pair，改為單一 source-patched dylib——不利「保留接近上游／CX 的本體、wait 用可卸 workaround」的雙包策略。

## 目標

1. Engine tarball **同時**帶 MoltenVK **1.4.2** 與 **1.2.10** 兩顆本體（約 +6 MiB 磁碟／+1.6 MiB zstd）。
2. `libMoltenVK.dylib` 固定為 **wait-poll shim**；選版只改 `libMoltenVK.real.dylib` → versioned 實體（相對 symlink）。
3. 全域偏好僅 **`1.4.2` | `1.2.10`**（無 `auto`）；macOS **&lt; 12** 強制 1.2.10。
4. 上游修好 host `vkWaitSemaphores*` 後可移除 shim，改為 `libMoltenVK.dylib` 直接 symlink 到選中版本。

## 非目標

- 不 per-game／per-bottle 選版。
- 不把 MoltenVK 改成 `Resources/graphics` payload（仍留在引擎）。
- 不以 `CX_LIBVULKAN` 當產品主路徑（可作除錯備註）。
- 不保證 1.2.10 與 #7 使用者從 CrossOver.app 拷出的二進位 bit-identical；以可重現建置 + 實機驗收為準。

## 決策摘要

| 項目 | 決定 |
|------|------|
| 出貨位置 | 兩版皆在 **engine tarball**（方案 A） |
| 選版機制 | `libMoltenVK.real.dylib` **symlink**；shim 固定為 `libMoltenVK.dylib` |
| Ports 修復 | **兩版都走 wait-poll shim**（方案 A）；本體不編 timeline-wait |
| 偏好範圍 | **全域** |
| 偏好值 | 僅 `1.4.2` \| `1.2.10`（無 `auto`） |
| OS 地板 | 產品仍 10.15；1.4.2 dylib minos **12.0** 路徑豁免（比照 DXMT） |
| Cyder011「禁 `.real`」 | **本功能範圍內廢止**；改為必須出正確 shim pair |

---

## §1 目錄與 shim 契約

```text
lib/wine/x86_64-unix/
  libMoltenVK-1.4.2.dylib       # 實體；minos 12.0
  libMoltenVK-1.2.10.dylib      # 實體；minos ≤ 10.15
  libMoltenVK.real.dylib  → …   # OS／全域偏好選版（相對 symlink）
  libMoltenVK.dylib             # wait-poll shim → re-export .real
```

| 檔案 | 職責 |
|------|------|
| `libMoltenVK.dylib` | 既有 `tools/cyder-mvk-timeline-wait-poll/` shim；re-export `@loader_path/libMoltenVK.real.dylib`；marker `cyder-moltenvk-timeline-wait-poll` |
| `libMoltenVK.real.dylib` | Symlink 到 `libMoltenVK-1.4.2.dylib` 或 `libMoltenVK-1.2.10.dylib` |
| `libMoltenVK-1.4.2.dylib` | 上游 1.4.2 + **capability／present** patches（維持 DXVK feature-level／present 行為）；**不含** timeline-wait source patch |
| `libMoltenVK-1.2.10.dylib` | crossover-foss 1.2.10（或等價可重現來源）；**不含** timeline-wait |

Wine／`winevulkan` 仍只 `dlopen("libMoltenVK.dylib")`（與現況一致）。

**禁止：** `.real` 本身又是 shim（double-shim）；對已是 shim 的檔再備份成 `.real`。

**卸 shim（未來）：** 上游修復後，刪除 shim 與 `.real` 名稱約定，改 `libMoltenVK.dylib` → versioned 實體即可；選版邏輯可複用。

---

## §2 選版、設定、時序

### 解析（`cyder_resolve_moltenvk_variant`）

| 條件 | 結果 |
|------|------|
| macOS **&lt; 12** | 一律 **1.2.10**（設定若殘留 1.4.2 則執行時矯正；UI 鎖死） |
| macOS **≥ 12** | 完全依設定 **1.4.2** 或 **1.2.10** |

新安裝預設寫入：`≥12 → 1.4.2`；`&lt;12 → 1.2.10`。

### 套用（冪等）

1. 確認兩顆 versioned 實體與 shim 存在。  
2. 將 `libMoltenVK.real.dylib` 指到 `libMoltenVK-<resolved>.dylib`。  
3. 確認 `libMoltenVK.dylib` 為 wait-poll shim 且 re-export `.real`。  
4. 不為了改 symlink 而重簽整個引擎；缺簽／換實體時沿用既有 ad-hoc 流程。

### 設定

- `settings.json`：`moltenvkVariant`: `"1.4.2"` \| `"1.2.10"`；schemaVersion +1。  
- UI：偏好設定圖形／進階區二選一；&lt;12 時 1.4.2 灰掉並說明需 macOS 12+。  
- 選 1.2.10 可簡短註明用途（舊 Intel／相容）；ports 仍由 shim 處理，**不必**再警告 ports 回歸。

### 時序

1. 引擎安裝／升級／ensure 後套用一次。  
2. 每次啟動遊戲／Wine 前再套用一次。  
3. 設定存檔時立即改 symlink（建議）。  
4. Finder 開 EXE：讀設定套用；不重解壓引擎。

### 錯誤

- 缺實體或 shim 損壞 → 明確失敗（與現有「缺 MoltenVK」／DXVK 不可用回退一致）。  
- 偵測到 double-shim 或 `.real` 指向缺失 → 失敗並提示重裝引擎。

---

## §3 建置、pack／minos、測試

### 建置（`cyder-wine-engine`）

1. Pin 上游 MoltenVK **1.4.2**（SHA 驗證）；套用 capability + present（與現行 1.4.0 相同意圖）；**不**套 timeline-wait。  
2. 建 crossover-foss **1.2.10** real；**不**套 timeline-wait。  
3. 預編 wait-poll shim 進 unix lib 目錄。  
4. Pack 預設 `.real` → 1.4.2（發版機通常 ≥12；runtime ensure 依主機再改）。

### Pack／minos

- 產品地板仍 **10.15**。  
- **豁免：** 僅 `libMoltenVK-1.4.2.dylib`（相對引擎根、posix 路徑）允許 minos 至 **12.0**。  
- 1.2.10 與 shim：必須 ≤ 10.15。  
- Symlink 不參與 minos 掃描（既有行為）。  
- Pack **要求**雙實體 + shim + `.real`；拒絕缺一、double-shim、壞連結。  
- 廢止「artifact 不得含 `libMoltenVK.real.dylib`」的 Cyder011 契約；改為必須含正確 pair。

### 測試（契約）

| 測項 | 斷言 |
|------|------|
| Pack／fixture | 雙實體 + shim + `.real`；無 double-shim |
| minos scan | 1.4.2 豁免至 12；其餘 ≤ 10.15 |
| resolve | &lt;12 → 1.2.10；≥12 尊重設定 |
| apply 冪等 | 連跑穩定；切偏好後 `.real` 目標變 |
| shim marker | `strings` 見 `cyder-moltenvk-timeline-wait-poll` |
| settings | 只接受兩個字面值；無 `auto` |

### 手動驗收

- #7 類 Intel：≥12 設 1.2.10 → 世界層非黑；再試 1.4.2 是否已修。  
- Classic + DXVK 長跑：Ports 不因 wait 洩漏持續爬升。  
- &lt;12（若有）：UI／執行皆只能用 1.2.10。

### 擁有權

| Repo | 職責 |
|------|------|
| `cyder-wine-engine` | 雙版建置、shim 打包、minos 豁免、pack 驗證、引擎測試 |
| ogom（Cyder） | 設定 UI／schema、resolve／apply、ensure 與啟動掛點、app 側測試 |

---

## 成功標準

1. 新引擎包內同時存在 1.4.2／1.2.10 實體、shim、`.real`，且可通過更新後的 pack／minos 門檻。  
2. ≥12 預設 1.4.2；偏好可切到 1.2.10；&lt;12 無法啟用 1.4.2。  
3. 切版只改 `.real`，不需重裝引擎。  
4. DXVK 長跑 ports 行為與現行 patched 引擎等價（shim 生效）。  
5. 文件與測試契約不再要求「禁止 `.real`」。

## 風險與後續

| 風險 | 緩解 |
|------|------|
| 1.4.2 + capability／present rebase 失敗 | 實作計畫含 patch 移植步驟與回歸；必要時暫以較少 patch 的 1.4.2 驗 #7 |
| 1.2.10 自建 ≠ #7 二進位 | 以實機黑畫面驗收；來源鎖定 crossover-foss revision |
| 下載／磁碟略增 | 可接受（約 +1.6 MiB zstd） |
| 與 Cyder011 文件／測試衝突 | 本規格明確廢止禁 `.real`；實作時同步改 engine／ogom 契約測試 |
